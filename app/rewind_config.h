#ifndef REWIND_CONFIG_H
#define REWIND_CONFIG_H

#define REWIND_VERSION @"v1.0.0-stable"
#define REWIND_API_KEY_DEFAULTS_KEY @"RewindAPIKey"
#define REWIND_AUDIO_SERVER_DEFAULTS_KEY @"RewindAudioServerURL"
#define REWIND_AUDIO_SERVER_URL @"https://invidious.f5.si"
/* retained key for stored settings; web PO tokens cannot authorize native IOS requests */
#define REWIND_POT_PROVIDER_DEFAULTS_KEY @"RewindPOTProviderURL"
#define REWIND_LIBRARY_DEFAULTS_KEY @"RewindFavorites"
#define REWIND_HISTORY_DEFAULTS_KEY @"RewindRecentTracks"
#define REWIND_PLAYLISTS_DEFAULTS_KEY @"RewindPlaylists"
#define REWIND_BACKGROUND_AUDIO_DEFAULTS_KEY @"RewindBackgroundAudio"
#define REWIND_BACKGROUND_AUDIO_DID_CHANGE_NOTIFICATION @"RewindBackgroundAudioDidChangeNotification"
#define REWIND_KEEP_SCREEN_AWAKE_DEFAULTS_KEY @"RewindKeepScreenAwake"
#define REWIND_KEEP_SCREEN_AWAKE_DID_CHANGE_NOTIFICATION @"RewindKeepScreenAwakeDidChangeNotification"

#endif /* REWIND_CONFIG_H */
