# download probe

Build the unsigned probe from the repository root:

```bash
export THEOS=/path/to/theos
export REWIND_SDK_V7=/path/to/armv7/iPhoneOS.sdk
export REWIND_DOWNLOAD_PROBE_OUTPUT=/tmp/RewindDownloadProbe
bash tests/build_download_probe.sh
```

`REWIND_TC` overrides the toolchain directory. `REWIND_DOWNLOAD_PROBE_CC`
selects another native clang executable. The armv7 slice targets iOS 5.
For arm64, set `REWIND_DOWNLOAD_PROBE_ARCH=arm64` and `REWIND_SDK_V64`;
that slice targets iOS 7. The script only builds, it does not sign or install.

Generate two small AAC fixtures in a new directory:

```bash
export REWIND_FIXTURES="$(mktemp -d)"
ffmpeg -nostdin -v error -f lavfi -i 'sine=frequency=440:duration=2' -c:a aac -b:a 64k "$REWIND_FIXTURES/plain.m4a"
ffmpeg -nostdin -v error -i "$REWIND_FIXTURES/plain.m4a" -c:a copy -movflags +frag_keyframe+empty_moov+default_base_moof+global_sidx -frag_duration 500000 "$REWIND_FIXTURES/fragmented.m4a"
```

Sign the probe:

```bash
"${REWIND_TC:-$THEOS/toolchain/linux/iphone/bin}/ldid" -S "$REWIND_DOWNLOAD_PROBE_OUTPUT"
```

Copy it to a new device pathname, then rename it into place. Overwriting an executable in place can leave stale code-signature state
on iOS 5 and kill it in dyld before main. Copy the two fixtures alongside it.
Run as mobile with absolute paths:

```bash
export REWIND_DEVICE_DIR=/tmp/rewind-download-test
su mobile -c "$REWIND_DEVICE_DIR/RewindDownloadProbe $REWIND_DEVICE_DIR/plain.m4a $REWIND_DEVICE_DIR/fragmented.m4a"
```

The probe prints both fixture paths and its unique staging directory. It uses
that directory instead of the real offline library and removes it on completion.
It copies fixtures without deleting them. It performs no network requests,
account operations, audible playback, or UI changes.

Exit zero requires local AAC copying, fragmented-to-plain M4A conversion,
PCM decoding, metadata round trips, main-thread completion and change
notifications, duplicate rejection, the two-task limit, and reservation reuse.
It also checks invalid identifiers (including an embedded null), invalid
metadata, metadata symlinks, malformed and truncated MP4, oversized files,
HTTP rejection, missing payloads, and temporary cleanup.

The probe passed as mobile on an iPhone 4S running iOS 5.1.1, with builds from
both clang 11 and clang 22. Directory syncing and PCM reader completion passed.
Both fixtures remained present, and the staging directory was removed.
Armv7 and arm64 builds were inspected with `lipo -info` and `otool`: deployment
targets were iOS 5 and iOS 7, with AVFAudio weak-linked only for arm64.
A host conversion of the fragmented fixture preserved all 88 AAC packet hashes
and decoded with ffmpeg. The rebuilt file trims the final packet to its declared
duration; its PCM matches the original decoded prefix.

`RewindDownloadTrack(track, api, completion)` resolves audio, validates and
commits it, then calls completion on main. Successful completion also posts
`RewindDownloadsDidChangeNotification` on main, with `videoID` in `userInfo`,
before the callback. Visible controllers can reload `RewindDownloadedTracks()`
when notified. An already committed track also posts the notification.

Downloads live in `Documents/RewindDownloads`, with one M4A and a bounded binary
plist per video id. Metadata is published after the payload is synced.
`RewindDownloadedTracks()` returns committed `RewindTrack` objects;
`RewindDownloadedURLForTrack(videoID)` returns their local file URL.
Neither helper reads the audio payload. The player must preserve those files.
Only a resolver source key ending in `:sabr`, with its matching scratch path,
transfers temporary-file ownership. Unindexed `Documents/Rewind-<id>.audio`
files remain untouched.

With `--offline-player`, the probe also checks real player clock advancement, pause,
seek, plain and converted AAC, switching tracks, retained files, and rereading stored
metadata with a new player. These checks passed on iPhone 4S, iOS 5.1.1, without
network resolution or account requests. Full process relaunch, arm64 device execution,
and HTTPS download transport still need device coverage.
