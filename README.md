# tunetube

a youtube music client for iOS 5-10.

The project is not affiliated with Google or YouTube.

## requirements

- Theos toolchain with `clang` and `ldid`
- iPhoneOS SDK that can build the armv7 slice
- iPhoneOS SDK that can build the arm64 slice

Set the toolchain and sdk paths before building:

```bash
export THEOS=/path/to/theos
export TUNETUBE_SDK_V7=/path/to/iPhoneOS6.1.sdk
export TUNETUBE_SDK_V64=/path/to/iPhoneOS16.5.sdk
```

## build

Run the model tests and build a IPA:

```bash
make -C tests test
make ipa
```
or for deb package

```bash
make deb
```

## layout

- `app/` - Objective-C UI, player, API client, and image cache
- `core/` - small C layer
- `tests/` - some tests
- `build_*.sh` and `Makefile` - packaging and build scripts

## license

[GPL-2.0-only](LICENSE)
