#import "tunetube_l10n.h"
#import "tunetube_config.h"

static NSDictionary *TuneTableForCode(NSString *code) {
    static NSDictionary *en;
    static NSDictionary *ru;
    if (!en) {
        en = [[NSDictionary alloc] initWithObjectsAndKeys:
              // common
              @"Settings", @"settings",
              @"Done", @"done",
              @"About", @"about",
              @"About TuneTube", @"about_tunetube",
              @"YouTube Music client for iOS 5-10\n\n"
              "TuneTube searches YouTube Music and plays audio anonymously.\n\n"
              "Built for armv7 and arm64.", @"about_body",
              @"Cancel", @"cancel",
              @"Save", @"save",
              @"Create", @"create",
              @"Add", @"add",
              @"Back", @"back",
              @"Library", @"library",
              @"Search", @"search",
              @"Artist", @"artist",
              @"Playlists", @"playlists",
              @"Playlist", @"playlist",
              @"Music", @"music",
              // settings
              @"PLAYBACK", @"section_playback",
              @"SEARCH", @"section_search",
              @"TUNETUBE", @"section_tunetube",
              @"LANGUAGE", @"section_language",
              @"Background audio", @"background_audio",
              @"YouTube Music API key", @"api_key",
              @"Custom", @"custom",
              @"Built-in", @"built_in",
              @"Reset API key", @"reset_api_key",
              @"Use built-in key", @"use_builtin_key",
              @"Already default", @"already_default",
              @"Language", @"language",
              @"English", @"english",
              @"Russian", @"russian",
              @"Leave empty to use the built-in key.", @"api_key_hint",
              @"Youtube Music for the legacy communitty :D", @"footer_tagline",
              // main
              @"LEGACY YOUTUBE MUSIC", @"tagline",
              @"Search songs, artists and albums", @"search_placeholder",
              @"QUICK PICKS", @"quick_picks",
              @"SEARCH RESULTS", @"search_results",
              @"Nothing playing", @"nothing_playing",
              @"Pick a song to start", @"pick_song",
              @"Choose a track from search", @"choose_track",
              @"Unknown artist", @"unknown_artist",
              @"Loading %@", @"loading_title",
              @"Searching…", @"searching",
              @"couldn't connect to youtube", @"err_connect",
              @"youtube request timed out", @"err_timeout",
              @"youtube search failed", @"err_search",
              @"couldn't load this song", @"err_load_song",
              @"Playing now", @"playing_now",
              @"Paused", @"paused",
              @"Recently played", @"recently_played",
              @"Removed from Library", @"removed_library",
              @"Added to Library", @"added_library",
              @"Add to playlist", @"add_to_playlist",
              @"New playlist", @"new_playlist",
              @"name", @"name_placeholder",
              @"%lu songs", @"songs_count",
              // library
              @"Nothing here", @"nothing_here",
              @"Saved tracks will appear here.\nFind music and tap ♥ to add it.", @"library_empty_desc",
              @"Find music", @"find_music",
              @"Empty library", @"empty_library",
              @"Play something first", @"play_something_first",
              @"Favorites", @"favorites",
              @"Recent", @"recent",
              // artist
              @"loading tracks...", @"loading_tracks",
              @"no tracks", @"no_tracks",
              @"tracks", @"tracks",
              @"saved track", @"saved_track",
              @"couldn't load tracks", @"couldnt_load_tracks",
              @"%lu tracks", @"tracks_count",
              // player
              @"Artist profile", @"artist_profile",
              nil];
    }
    if (!ru) {
        ru = [[NSDictionary alloc] initWithObjectsAndKeys:
              @"Настройки", @"settings",
              @"Готово", @"done",
              @"О приложении", @"about",
              @"О TuneTube", @"about_tunetube",
              @"Клиент YouTube Music для iOS 5–10\n\n"
              "TuneTube ищет в YouTube Music и играет аудио анонимно.\n\n"
              "Собран под armv7 и arm64.", @"about_body",
              @"Отмена", @"cancel",
              @"Сохранить", @"save",
              @"Создать", @"create",
              @"Добавить", @"add",
              @"Назад", @"back",
              @"Библиотека", @"library",
              @"Поиск", @"search",
              @"Артист", @"artist",
              @"Плейлисты", @"playlists",
              @"Плейлист", @"playlist",
              @"Музыка", @"music",
              @"ВОСПРОИЗВЕДЕНИЕ", @"section_playback",
              @"ПОИСК", @"section_search",
              @"TUNETUBE", @"section_tunetube",
              @"ЯЗЫК", @"section_language",
              @"Фоновое аудио", @"background_audio",
              @"API-ключ YouTube Music", @"api_key",
              @"Свой", @"custom",
              @"Встроенный", @"built_in",
              @"Сбросить API-ключ", @"reset_api_key",
              @"Встроенный ключ", @"use_builtin_key",
              @"Уже по умолчанию", @"already_default",
              @"Язык", @"language",
              @"English", @"english",
              @"Русский", @"russian",
              @"Оставьте пустым для встроенного ключа.", @"api_key_hint",
              @"Youtube Music for the legacy communitty :D", @"footer_tagline",
              @"LEGACY YOUTUBE MUSIC", @"tagline",
              @"Песни, артисты и альбомы", @"search_placeholder",
              @"БЫСТРЫЙ ВЫБОР", @"quick_picks",
              @"РЕЗУЛЬТАТЫ ПОИСКА", @"search_results",
              @"Ничего не играет", @"nothing_playing",
              @"Выберите песню", @"pick_song",
              @"Выберите трек из поиска", @"choose_track",
              @"Неизвестный артист", @"unknown_artist",
              @"Загрузка %@", @"loading_title",
              @"Поиск…", @"searching",
              @"нет связи с youtube", @"err_connect",
              @"таймаут youtube", @"err_timeout",
              @"ошибка поиска youtube", @"err_search",
              @"не удалось загрузить песню", @"err_load_song",
              @"Играет", @"playing_now",
              @"Пауза", @"paused",
              @"Недавно играло", @"recently_played",
              @"Удалено из библиотеки", @"removed_library",
              @"Добавлено в библиотеку", @"added_library",
              @"В плейлист", @"add_to_playlist",
              @"Новый плейлист", @"new_playlist",
              @"название", @"name_placeholder",
              @"%lu песен", @"songs_count",
              @"Здесь пусто", @"nothing_here",
              @"Сохранённые треки появятся здесь.\nНайдите музыку и нажмите ♥.", @"library_empty_desc",
              @"Найти музыку", @"find_music",
              @"Библиотека пуста", @"empty_library",
              @"Сначала включите трек", @"play_something_first",
              @"Избранное", @"favorites",
              @"Недавние", @"recent",
              @"загрузка треков...", @"loading_tracks",
              @"нет треков", @"no_tracks",
              @"треки", @"tracks",
              @"сохранённый трек", @"saved_track",
              @"не удалось загрузить", @"couldnt_load_tracks",
              @"%lu треков", @"tracks_count",
              @"Профиль артиста", @"artist_profile",
              nil];
    }
    if ([code isEqualToString:@"ru"]) return ru;
    return en;
}

NSString *TuneLanguageCode(void) {
    NSString *code = [[NSUserDefaults standardUserDefaults]
                      objectForKey:TUNETUBE_LANGUAGE_DEFAULTS_KEY];
    if ([code isEqualToString:@"ru"] || [code isEqualToString:@"en"]) return code;
    return @"en";
}

void TuneSetLanguageCode(NSString *code) {
    if (![code isEqualToString:@"ru"] && ![code isEqualToString:@"en"])
        code = @"en";
    [[NSUserDefaults standardUserDefaults] setObject:code
                                              forKey:TUNETUBE_LANGUAGE_DEFAULTS_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter]
     postNotificationName:TUNETUBE_LANGUAGE_DID_CHANGE_NOTIFICATION object:nil];
}

BOOL TuneLanguageIsRussian(void) {
    return [TuneLanguageCode() isEqualToString:@"ru"];
}

NSString *TuneL(NSString *key) {
    if (!key.length) return @"";
    NSString *value = [TuneTableForCode(TuneLanguageCode()) objectForKey:key];
    if (value.length) return value;
    value = [TuneTableForCode(@"en") objectForKey:key];
    return value.length ? value : key;
}
