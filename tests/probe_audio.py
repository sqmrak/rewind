#!/usr/bin/env python3
"""explicit network probe for the player API, CDN ranges and legacy M4A output"""

import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "app/rewind_api.m").read_text()


def constant(name):
    match = re.search(r"(?:const\s+)?" + re.escape(name) + r'\s*=\s*@"([^"]+)"', SOURCE)
    if not match:
        raise RuntimeError("missing API constant " + name)
    return match.group(1)


def fetch(url, user_agent, capacity, body=None, headers=None):
    if urllib.parse.urlparse(url).scheme != "https":
        raise RuntimeError("insecure media URL")
    values = {"User-Agent": user_agent, "Accept-Encoding": "identity"}
    values.update(headers or {})
    request = urllib.request.Request(url, data=body, headers=values)
    with urllib.request.urlopen(request, timeout=15) as response:
        data = response.read(capacity + 1)
        if len(data) > capacity:
            raise RuntimeError("response exceeds size limit")
        if urllib.parse.urlparse(response.url).scheme != "https":
            raise RuntimeError("insecure redirect")
        return response.status, response.headers, data, response.url


def player(video, name):
    title = {"IOS": "IOS", "ANDROID": "Android", "ANDROID_VR": "AndroidVR"}[name]
    version = constant("Rewind" + title + "ClientVersion")
    number = {"IOS": "5", "ANDROID": "3", "ANDROID_VR": "28"}[name]
    prefix = {"IOS": "com.google.ios.youtube/", "ANDROID": "com.google.android.youtube/",
              "ANDROID_VR": "com.google.android.apps.youtube.vr.oculus/"}[name]
    ua = re.search(r'@"(' + re.escape(prefix) + r'[^"\n]+)"', SOURCE).group(1).replace("%@", version)
    client = {"clientName": name, "clientVersion": version, "hl": "en", "gl": "US", "userAgent": ua}
    if name == "IOS":
        client.update(deviceMake="Apple", deviceModel="iPhone16,2", osName="iPhone", osVersion="18.3.2.22D82")
    elif name == "ANDROID":
        client.update(androidSdkVersion=30, osName="Android", osVersion="11")
    else:
        client.update(deviceMake="Oculus", deviceModel="Quest 3", androidSdkVersion=32, osName="Android", osVersion="12L")
    body = json.dumps({"context": {"client": client}, "videoId": video,
                       "contentCheckOk": True, "racyCheckOk": True}).encode()
    status, _, data, _ = fetch(constant("RewindPlayerEndpoint") + "/player?key=" + constant("RewindDefaultAPIKey"),
                               ua, 4 * 1024 * 1024, body, {"Content-Type": "application/json",
                               "X-YouTube-Client-Name": number, "X-YouTube-Client-Version": version,
                               "Origin": "https://www.youtube.com"})
    if status != 200:
        raise RuntimeError("player HTTP " + str(status))
    root = json.loads(data)
    if root.get("playabilityStatus", {}).get("status") != "OK":
        raise RuntimeError(str(root.get("playabilityStatus")))
    return root, ua


def public_player(core, video, server):
    ua = constant("RewindPublicAudioUserAgent")
    status, _, data, _ = fetch(server.rstrip("/") + "/api/v1/videos/" + video + "?local=false",
                               ua, 4 * 1024 * 1024, headers={"Accept": "application/json"})
    root = json.loads(data)
    if status != 200 or not isinstance(root, dict) or root.get("videoId") != video:
        raise RuntimeError("public server returned no matching video")
    streaming = {}
    for source, target in (("adaptiveFormats", "adaptiveFormats"), ("formatStreams", "formats")):
        streaming[target] = []
        for value in root.get(source, []):
            if not isinstance(value, dict):
                continue
            media = urllib.parse.urlsplit(value.get("url", ""))
            if media.scheme != "https" or media.username or media.password or media.fragment or not media.hostname:
                continue
            if media.hostname != urllib.parse.urlsplit(server).hostname and not media.hostname.endswith(".googlevideo.com"):
                continue
            mapped = {"url": value["url"], "mimeType": value.get("type", ""),
                      "itag": value.get("itag"), "bitrate": value.get("bitrate", 0)}
            if "clen" in value:
                mapped["contentLength"] = value["clen"]
            start, end = ctypes.c_uint64(), ctypes.c_uint64()
            if core.rewind_audio_index_range(str(value.get("index", "")).encode(), ctypes.byref(start), ctypes.byref(end)):
                mapped["indexRange"] = {"start": start.value, "end": end.value}
            streaming[target].append(mapped)
    return {"streamingData": streaming}, ua


def byte_range(core, url, ua, start, end):
    status, headers, data, _ = fetch(url, ua, end - start + 1, headers={"Range": f"bytes={start}-{end}"})
    total = ctypes.c_uint64()
    content_range = headers.get("Content-Range", "").encode()
    if status != 206 or not core.rewind_audio_content_range(content_range, start, end, len(data), ctypes.byref(total)):
        raise RuntimeError("wrong byte range")
    return data, total.value


def hls(core, url, ua):
    for _ in range(3):
        status, _, data, resolved = fetch(url, ua, 512 * 1024)
        first, last = ctypes.create_string_buffer(8192), ctypes.create_string_buffer(8192)
        kind = core.rewind_audio_hls(data, len(data), first, len(first), last, len(last))
        if status != 200 or not kind:
            raise RuntimeError("invalid AAC playlist")
        if kind == 1:
            url = urllib.parse.urljoin(resolved, first.value.decode())
            continue
        for relative in (first.value, last.value):
            status, _, segment, _ = fetch(urllib.parse.urljoin(resolved, relative.decode()), ua, 2 * 1024 * 1024)
            if status != 200 or not core.rewind_audio_segment(segment, len(segment)):
                raise RuntimeError("invalid HLS audio segment")
        return
    raise RuntimeError("too many HLS levels")


def check_video(core, video, full, directory, server):
    names = (["INVIDIOUS"] if server else []) + ["IOS", "ANDROID", "ANDROID_VR"]
    for name in names:
        try:
            root, ua = public_player(core, video, server) if name == "INVIDIOUS" else player(video, name)
        except (RuntimeError, ValueError, urllib.error.URLError) as error:
            print(video, name, "player rejected:", str(error), flush=True)
            continue
        streaming = root.get("streamingData", {})
        formats = [f for f in streaming.get("adaptiveFormats", [])
                   if f.get("mimeType", "").startswith("audio/mp4") and f.get("url")]
        formats.sort(key=lambda f: int(f.get("bitrate", 0)), reverse=True)
        progressive = [f for f in streaming.get("formats", [])
                       if f.get("mimeType", "").startswith("video/mp4") and "mp4a." in f.get("mimeType", "") and f.get("url")]
        progressive.sort(key=lambda f: int(f.get("bitrate", 0)))
        for format_info in formats[:3] + progressive[:1]:
            try:
                url = format_info["url"]
                head, total = byte_range(core, url, ua, 0, 1023)
                if not core.rewind_audio_mp4(head, len(head)) or total > 512 * 1024 * 1024:
                    raise RuntimeError("invalid MP4")
                _, tail_total = byte_range(core, url, ua, total - 1024, total - 1)
                if total != tail_total:
                    raise RuntimeError("file changed between ranges")
                print(video, name, "itag", format_info["itag"], "head and tail passed, bytes", total, flush=True)
                if full:
                    if total > 16 * 1024 * 1024:
                        raise RuntimeError("full fixture exceeds 16 MiB")
                    source = directory / (video + ".fragmented.m4a")
                    plain = directory / (video + ".m4a")
                    with source.open("wb") as output:
                        for start in range(0, total, 512 * 1024):
                            data, size = byte_range(core, url, ua, start, min(total - 1, start + 512 * 1024 - 1))
                            if size != total:
                                raise RuntimeError("file changed during download")
                            output.write(data)
                    if format_info["mimeType"].startswith("audio/mp4"):
                        subprocess.run([str(ROOT / "tests/test_fmp4"), str(source), str(plain)], check=True)
                    else:
                        plain = source
                    subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(plain), "-map", "0:a", "-f", "null", "-"], check=True)
                    print(video, name, "full audio decoded", flush=True)
                return
            except (RuntimeError, urllib.error.URLError, subprocess.CalledProcessError) as error:
                print(video, name, "itag", format_info["itag"], "rejected:", str(error), flush=True)
        if streaming.get("hlsManifestUrl"):
            try:
                hls(core, streaming["hlsManifestUrl"], ua)
                print(video, name, "AAC HLS first and last segments passed", flush=True)
                if not full:
                    return
            except (RuntimeError, urllib.error.URLError, subprocess.CalledProcessError) as error:
                print(video, name, "HLS rejected:", str(error), flush=True)
    raise RuntimeError(video + " has no validated " + ("complete " if full else "") + "audio source")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("videos", nargs="*", default=["dQw4w9WgXcQ", "K4DyBUG242c", "yJg-Y5byMMw"])
    parser.add_argument("--full", action="store_true", help="download audio, rebuild fragmented AAC and decode it with ffmpeg")
    backend = parser.add_mutually_exclusive_group()
    backend.add_argument("--server", help="use this HTTPS Invidious origin")
    backend.add_argument("--direct", action="store_true", help="skip the public server")
    args = parser.parse_args()
    config = (ROOT / "app/rewind_config.h").read_text()
    server = None if args.direct else (args.server or re.search(r'REWIND_AUDIO_SERVER_URL\s+@"([^"]+)"', config).group(1))
    if server:
        origin = urllib.parse.urlsplit(server)
        if origin.scheme != "https" or not origin.hostname or origin.username or origin.password or origin.query or origin.fragment or origin.path not in ("", "/"):
            parser.error("server must be an HTTPS origin")
    with tempfile.TemporaryDirectory(prefix="rewind-audio-probe-") as temporary:
        directory = Path(temporary)
        library = directory / "audio.so"
        subprocess.run([os.environ.get("CC", "cc"), "-shared", "-fPIC", "-std=c99", "-I" + str(ROOT / "core"),
                        str(ROOT / "core/rewind_audio.c"), "-o", str(library)], check=True)
        core = ctypes.CDLL(str(library))
        core.rewind_audio_content_range.argtypes = [ctypes.c_char_p, ctypes.c_uint64, ctypes.c_uint64,
                                                    ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint64)]
        core.rewind_audio_index_range.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64)]
        core.rewind_audio_mp4.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        core.rewind_audio_segment.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        core.rewind_audio_hls.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p,
                                        ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
        failed = False
        for video in args.videos:
            if not re.fullmatch(r"[A-Za-z0-9_-]{11}", video):
                parser.error("invalid video id")
            try:
                check_video(core, video, args.full, directory, server)
            except (RuntimeError, urllib.error.URLError, ValueError) as error:
                print("FAIL", error, flush=True)
                failed = True
        if failed:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
