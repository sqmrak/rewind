#!/usr/bin/env python3
"""integration probe, needs the public youtube service: drives the production sabr planner
(core/rewind_sabr.c through ctypes) with parallel workers and prints the time to a complete track.
usage: sabr_live_probe.py LIBRARY VIDEO_ID [WORKERS]"""
import base64, ctypes, json, sys, threading, time, urllib.request

KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
VERSION = "21.26.4"
UA = "com.google.ios.youtube/%s (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)" % VERSION

class Request(ctypes.Structure):
    _fields_ = [("segment", ctypes.c_int64), ("claimed_segments", ctypes.c_int64), ("claimed_ms", ctypes.c_int64)]

lib = ctypes.CDLL(sys.argv[1])
lib.rewind_sabr_create.restype = ctypes.c_void_p
lib.rewind_sabr_create.argtypes = [ctypes.c_int32]
lib.rewind_sabr_feed.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
lib.rewind_sabr_next_request.argtypes = [ctypes.c_void_p, ctypes.POINTER(Request)]
lib.rewind_sabr_request_done.argtypes = [ctypes.c_void_p, ctypes.POINTER(Request)]
lib.rewind_sabr_have_count.restype = ctypes.c_size_t
lib.rewind_sabr_have_count.argtypes = [ctypes.c_void_p]
lib.rewind_sabr_expected.restype = ctypes.c_size_t
lib.rewind_sabr_expected.argtypes = [ctypes.c_void_p]

def varint(n):
    out = b""
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])

def field_varint(f, v): return varint(f << 3) + varint(v)
def field_bytes(f, b): return varint(f << 3 | 2) + varint(len(b)) + b

def request_body(itag, modified, config, request):
    client = (field_bytes(1, b"en_US") + field_varint(16, 5) + field_bytes(17, VERSION.encode()) +
              field_bytes(18, b"iPhone") + field_bytes(19, b"18.3.2.22D82"))
    fmt = field_varint(1, itag) + (field_varint(2, modified) if modified else b"")
    abr = field_varint(28, request.claimed_ms) + field_varint(34, 1) + field_varint(40, 1)
    body = field_bytes(1, abr)
    if request.segment:
        buffered = (field_bytes(1, fmt) + field_varint(2, 0) + field_varint(3, request.claimed_ms) +
                    field_varint(4, 1 if request.claimed_segments else 0) + field_varint(5, request.claimed_segments))
        body += field_bytes(2, fmt) + field_bytes(3, buffered)
    return body + field_bytes(16, fmt) + field_bytes(19, field_bytes(1, client)) + field_bytes(5, config)

def find(node, key):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key: return v
            found = find(v, key)
            if found: return found
    elif isinstance(node, list):
        for v in node:
            found = find(v, key)
            if found: return found

def main():
    video = sys.argv[2]
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    context = {"client": {"clientName": "IOS", "clientVersion": VERSION, "hl": "en", "gl": "US", "deviceMake": "Apple",
                          "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82", "userAgent": UA}}
    started = time.time()
    player = urllib.request.Request(
        "https://www.youtube.com/youtubei/v1/player?key=" + KEY,
        json.dumps({"context": context, "videoId": video, "contentCheckOk": True, "racyCheckOk": True}).encode(),
        {"Content-Type": "application/json", "Origin": "https://www.youtube.com",
         "X-YouTube-Client-Name": "5", "X-YouTube-Client-Version": VERSION, "User-Agent": UA})
    root = json.load(urllib.request.urlopen(player, timeout=15))
    streaming = root["streamingData"]
    url = streaming["serverAbrStreamingUrl"]
    config = base64.urlsafe_b64decode(find(root, "videoPlaybackUstreamerConfig") + "==")
    formats = [f for f in streaming["adaptiveFormats"] if f["mimeType"].startswith("audio/mp4") and "mp4a." in f["mimeType"]]
    best = max(formats, key=lambda f: f["bitrate"])
    itag, modified = best["itag"], int(best["lastModified"])
    print("player %.2fs itag %d" % (time.time() - started, itag))
    stream = lib.rewind_sabr_create(itag)
    lock = threading.Lock()
    state = {"url": url, "failed": None, "requests": 0}

    def worker():
        while True:
            with lock:
                request = Request()
                plan = lib.rewind_sabr_next_request(stream, ctypes.byref(request))
                current = state["url"]
                if plan == 0: state["requests"] += 1
            if plan == 1:
                time.sleep(0.02)
                continue
            if plan != 0 or state["failed"]:
                return
            try:
                http = urllib.request.Request(current, request_body(itag, modified, config, request),
                                              {"Content-Type": "application/x-protobuf", "User-Agent": UA})
                data = urllib.request.urlopen(http, timeout=20).read()
                redirect = ctypes.create_string_buffer(8192)
                with lock:
                    status = lib.rewind_sabr_feed(stream, data, len(data), redirect, 8192)
                    if redirect.value: state["url"] = redirect.value.decode()
                    lib.rewind_sabr_request_done(stream, ctypes.byref(request))
                    if status in (3, 4, 5, 6): state["failed"] = status
            except Exception as error:
                with lock:
                    lib.rewind_sabr_request_done(stream, ctypes.byref(request))
                print("request error", error)

    threads = [threading.Thread(target=worker) for _ in range(workers)]
    begin = time.time()
    for t in threads: t.start()
    for t in threads: t.join()
    have, expected = lib.rewind_sabr_have_count(stream), lib.rewind_sabr_expected(stream)
    print("segments %d/%d requests %d failed %s in %.2fs (total with player %.2fs)" %
          (have, expected, state["requests"], state["failed"], time.time() - begin, time.time() - started))
    return 0 if expected and have == expected and not state["failed"] else 1

sys.exit(main())
