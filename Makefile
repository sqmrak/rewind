# keep the build usable on jailbroken legacy ios devices
# keep the base slice small because old devices have less memory

THEOS   ?= $(error set THEOS=/path/to/theos)
TC      ?= $(if $(REWIND_TC),$(REWIND_TC),$(THEOS)/toolchain/linux/iphone/bin)
SDK     ?= $(if $(REWIND_SDK_V7),$(REWIND_SDK_V7),$(error set SDK=/path/to/iphoneos.sdk))
LDID    ?= $(TC)/ldid

TRIPLE  ?= arm-apple-darwin11
CC      = $(TC)/clang -target $(TRIPLE) -B $(TC)
ARCH    ?= -arch armv7 -miphoneos-version-min=5.0
CFLAGS  = -fno-objc-arc -fblocks -Wall -Wextra -O2 $(ARCH) -isysroot $(SDK) -Icore -Iapp
AVFAUDIO_LDFLAG :=
ifneq ($(filter-out test clean,$(if $(MAKECMDGOALS),$(MAKECMDGOALS),all)),)
ifneq ($(wildcard $(SDK)/System/Library/Frameworks/AVFAudio.framework),)
AVFAUDIO_LDFLAG := -weak_framework AVFAudio
endif
endif
LDFLAGS = $(ARCH) -isysroot $(SDK) \
           -framework UIKit -framework Foundation \
           -framework CFNetwork -weak_framework AVFoundation $(AVFAUDIO_LDFLAG) \
           -framework CoreGraphics -framework QuartzCore -framework CoreMedia -framework ImageIO \
           -framework MediaPlayer

CORE_SRC := core/rewind_model.c core/rewind_qr.c core/rewind_fmp4.c core/rewind_ump.c core/rewind_audio.c core/rewind_sabr.c core/rewind_playback.c core/rewind_layout.c
APP_SRC  := app/app_main.m app/main_vc.m app/settings_vc.m app/about_vc.m app/player_vc.m app/library_vc.m app/artist_vc.m app/playlist_vc.m app/rewind_api.m app/rewind_player.m app/rewind_image_cache.m app/rewind_theme.m app/rewind_l10n.m app/rewind_account.m app/account_vc.m app/account_panel_vc.m app/rewind_ui.m app/rewind_download.m app/rewind_stream.m app/rewind_chrome.m app/rewind_http.m app/video_vc.m app/native_shell.m app/vinyl_view.m
ICON_SRC := app/icons/RewindIcon.png app/icons/RewindIcon@2x.png app/icons/RewindIcon-72.png app/icons/RewindIcon-72@2x.png app/icons/RewindIcon-60@2x.png app/icons/RewindIcon-60@3x.png app/icons/RewindIcon-83.5@2x.png app/icons/RewindIcon-76.png app/icons/RewindIcon-76@2x.png app/icons/icon-settings.png app/icons/sqmrak.jpg app/icons/rewind-fall.png app/icons/player-previous.png app/icons/player-previous@2x.png app/icons/player-next.png app/icons/player-next@2x.png app/icons/player-play.png app/icons/player-play@2x.png app/icons/player-pause.png app/icons/player-pause@2x.png app/icons/player-repeat.png app/icons/player-repeat@2x.png app/icons/player-repeat-on.png app/icons/player-repeat-on@2x.png app/icons/player-star-off.png app/icons/player-star-off@2x.png app/icons/player-star-on.png app/icons/player-star-on@2x.png app/icons/player-play-light.png app/icons/player-play-light@2x.png app/icons/player-pause-light.png app/icons/player-pause-light@2x.png app/icons/player-close.png app/icons/player-close@2x.png
ICON_SRC += app/icons/menu-download.png app/icons/menu-library-remove.png app/icons/menu-playlist-remove.png app/icons/menu-queue-add.png app/icons/menu-queue-clear.png app/icons/menu-mix.png app/icons/menu-play-next.png app/icons/menu-playlist-add.png app/icons/menu-share.png app/icons/menu-album.png app/icons/menu-artist.png app/icons/menu-speed.png app/icons/menu-sleep.png app/icons/menu-arrow-down.png app/icons/menu-more.png
ICON_SRC += $(wildcard app/icons/ic-*.png)
FONT_SRC := app/fonts/Roboto-Regular.ttf app/fonts/Roboto-Medium.ttf app/fonts/Roboto-Bold.ttf
LICENSE_SRC := app/fonts/LICENSE-Roboto.txt art/LICENSE-MaterialSymbols.txt
LAUNCH_SRC := app/icons/Default.png app/icons/Default@2x.png app/icons/Default-568h@2x.png app/icons/Default-667h@2x.png app/icons/Default-736h@3x.png app/icons/Default-812h@3x.png app/icons/Default-896h@2x.png app/icons/Default-896h@3x.png app/icons/Default-844h@3x.png app/icons/Default-926h@3x.png app/icons/Default-Portrait.png app/icons/Default-Portrait@2x.png
APP      := build/Rewind.app
BIN      ?= $(APP)/Rewind

.PHONY: all clean test fat deb ipa

all: $(BIN)

$(BIN): $(CORE_SRC) $(APP_SRC) $(ICON_SRC) $(FONT_SRC) $(LICENSE_SRC) $(LAUNCH_SRC) core/rewind_model.h core/rewind_qr.h core/rewind_fmp4.h core/rewind_ump.h core/rewind_audio.h core/rewind_sabr.h core/rewind_playback.h core/rewind_layout.h app/video_vc.h app/native_shell.h app/vinyl_view.h app/rewind_http.h app/rewind_stream.h app/rewind_chrome.h app/rewind_account.h app/account_vc.h app/account_panel_vc.h app/main_vc.h app/rewind_api.h app/rewind_player.h app/settings_vc.h app/about_vc.h app/player_vc.h app/library_vc.h app/artist_vc.h app/playlist_vc.h app/rewind_config.h app/rewind_download.h app/rewind_image_cache.h app/rewind_theme.h app/rewind_l10n.h app/rewind_ui.h Info.plist
	@mkdir -p $(APP)
	$(CC) $(CFLAGS) $(CORE_SRC) $(APP_SRC) -o $(BIN) $(LDFLAGS)
	$(LDID) -S $(BIN)
	cp Info.plist $(APP)/
	cp $(ICON_SRC) $(APP)/
	cp $(FONT_SRC) $(APP)/
	cp $(LICENSE_SRC) $(APP)/
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
