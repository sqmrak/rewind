# rewind

a youtube music client for jailbroken ios 5 to 16, one deb. formerly tunetube.

> [!NOTE]
> not affiliated with google or youtube.

## devices

- ios 5-6: armv7
- ios 7-10: armv7, arm64
- ios 11-16: arm64

## features

- home shelves, quick picks, search, moods and genres
- library, history, playlists and offline downloads
- queue, timed lyrics, related tracks and playback controls
- google device sign-in, liked music and account playlists
- material design 3 and skeuomorphic themes
- russian and english

## account

- tap the profile button, scan the qr code or enter the code at `google.com/device`
- the bundled login reads the selected profile, liked music and playlists
- creating youtube playlists needs your own oauth setup in settings
- signed-out playlists stay local

## install

```bash
scp rewind_*.deb root@<device-ip>:/var/mobile/
ssh root@<device-ip> dpkg -i /var/mobile/rewind_*.deb
```

remove: `dpkg -r com.sqmrak.rewind`.

the deb replaces tunetube and migrates its saved library and settings.
ipa installs cannot read the old app's sandbox.

## paths

- rootful app: `/Applications/Rewind.app`
- rootless app: `/var/jb/Applications/Rewind.app`
- account: `~/Library/Rewind/account.plist`, mode 0600
- downloads: `~/Documents/RewindDownloads`
- debug log: `~/Library/Rewind/debug.log`

## build

```bash
make -C tests test
make deb
```

needs `THEOS REWIND_SDK_V7 REWIND_SDK_V64`, outputs `rewind_<version>.deb`.
`REWIND_TC`, `REWIND_LIPO` and `REWIND_LDID` override the toolchain tools.
`make fat` builds the app, `make ipa` builds an ipa.

offline download checks: [tests/download_probe.md](tests/download_probe.md).

## license

[gpl v2](LICENSE). roboto and material symbols: apache 2.0 (`app/fonts/`, `art/`).
