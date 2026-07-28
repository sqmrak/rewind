# keep the build usable on jailbroken legacy ios devices
# keep the base slice small because old devices have less memory

THEOS   ?= $(error set THEOS=/path/to/theos)
TC      ?= $(if $(TUNETUBE_TC),$(TUNETUBE_TC),$(THEOS)/toolchain/linux/iphone/bin)
SDK     ?= $(if $(TUNETUBE_SDK_V7),$(TUNETUBE_SDK_V7),$(error set SDK=/path/to/iphoneos.sdk))
LDID    ?= $(TC)/ldid

TRIPLE  ?= arm-apple-darwin11
CC      := $(TC)/clang -target $(TRIPLE) -B $(TC)
ARCH    ?= -arch armv7 -miphoneos-version-min=5.0
CFLAGS  := -fno-objc-arc -fblocks -Wall -Wextra -O2 $(ARCH) -isysroot $(SDK) -Icore -Iapp
AVFAUDIO_LDFLAG :=
ifneq ($(wildcard $(SDK)/System/Library/Frameworks/AVFAudio.framework),)
AVFAUDIO_LDFLAG := -weak_framework AVFAudio
endif
LDFLAGS := $(ARCH) -isysroot $(SDK) \
           -framework UIKit -framework Foundation \
           -framework CFNetwork -weak_framework AVFoundation $(AVFAUDIO_LDFLAG) \
           -framework CoreGraphics -framework QuartzCore -framework CoreMedia \
           -framework MediaPlayer

CORE_SRC := core/tunetube_model.c
APP_SRC  := app/app_main.m app/main_vc.m app/settings_vc.m app/about_vc.m app/player_vc.m app/library_vc.m app/artist_vc.m app/playlist_vc.m app/play_button.m app/tunetube_api.m app/tunetube_player.m app/tunetube_image_cache.m app/tunetube_theme.m app/tunetube_l10n.m
ICON_SRC := app/icons/TuneTubeIcon.png app/icons/TuneTubeIcon@2x.png app/icons/TuneTubeIcon-72.png app/icons/TuneTubeIcon-72@2x.png app/icons/icon-settings.png app/icons/sqmrak.jpg app/icons/player-previous.png app/icons/player-previous@2x.png app/icons/player-next.png app/icons/player-next@2x.png app/icons/player-play.png app/icons/player-play@2x.png app/icons/player-pause.png app/icons/player-pause@2x.png app/icons/player-repeat.png app/icons/player-repeat@2x.png app/icons/player-repeat-on.png app/icons/player-repeat-on@2x.png app/icons/player-star-off.png app/icons/player-star-off@2x.png app/icons/player-star-on.png app/icons/player-star-on@2x.png app/icons/player-play-light.png app/icons/player-play-light@2x.png app/icons/player-pause-light.png app/icons/player-pause-light@2x.png app/icons/player-close.png app/icons/player-close@2x.png
ICON_SRC += app/icons/menu-download.png app/icons/menu-library-remove.png app/icons/menu-queue-add.png app/icons/menu-mix.png app/icons/menu-play-next.png app/icons/menu-playlist-add.png app/icons/menu-share.png app/icons/menu-arrow-down.png app/icons/menu-more.png
LAUNCH_SRC := app/icons/Default.png app/icons/Default@2x.png app/icons/Default-568h@2x.png app/icons/Default-Portrait.png app/icons/Default-Portrait@2x.png
APP      := build/TuneTube.app
BIN      ?= $(APP)/TuneTube

.PHONY: all clean test fat deb ipa

all: $(BIN)

$(BIN): $(CORE_SRC) $(APP_SRC) $(ICON_SRC) $(LAUNCH_SRC) core/tunetube_model.h app/main_vc.h app/tunetube_api.h app/tunetube_player.h app/settings_vc.h app/about_vc.h app/player_vc.h app/library_vc.h app/artist_vc.h app/playlist_vc.h app/play_button.h app/tunetube_config.h app/tunetube_image_cache.h app/tunetube_theme.h app/tunetube_l10n.h Info.plist
	@mkdir -p $(APP)
	$(CC) $(CFLAGS) $(CORE_SRC) $(APP_SRC) -o $(BIN) $(LDFLAGS)
	$(LDID) -S $(BIN)
	cp Info.plist $(APP)/
	cp $(ICON_SRC) $(APP)/
	cp $(LAUNCH_SRC) $(APP)/
	@echo "built $(BIN)"
	@$(TC)/otool -L $(BIN) | tail -n +2

test:
	$(MAKE) -C tests test

fat:
	bash build_fat.sh

deb:
	bash build_deb.sh

ipa:
	bash build_ipa.sh

clean:
	rm -rf build
