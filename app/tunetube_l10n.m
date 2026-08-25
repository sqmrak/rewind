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
              @"A compact YouTube Music client for legacy iOS.\n\n"
              "Search songs, artists and albums, keep favourites and playlists, and play audio in the background. TuneTube is built for devices that modern music apps left behind.\n\n"
              "Built for iOS 5-10 on armv7 and arm64.", @"about_body",
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
              @"Quick picks", @"quick_picks",
              @"Recommended", @"recommendations",
              @"See all", @"see_all",
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
              @"Play next", @"menu_play_next",
              @"Add to playlist", @"menu_add_playlist",
              @"Share", @"menu_share",
              @"Start mix", @"menu_mix",
              @"Add to queue", @"menu_queue",
              @"Remove from library", @"menu_remove_library",
              @"Download", @"menu_download",
              @"Remove from playlist", @"menu_remove_playlist",
              @"Open album", @"menu_album",
              @"Go to artist", @"menu_artist",
              @"Clear queue", @"menu_clear_queue",
              @"Playback speed", @"menu_speed",
              @"Sleep timer", @"menu_sleep",
              @"Added as next track", @"menu_play_next_added",
              @"Added to queue", @"menu_queued",
              @"Mix is on", @"menu_mix_enabled",
              @"Queue cleared", @"menu_queue_cleared",
              @"Track is not in a playlist", @"menu_no_playlists",
              @"Download started", @"menu_download_started",
              @"Download finished", @"menu_download_done",
              @"Download failed", @"menu_download_failed",
              @"Copied to clipboard", @"menu_share_copied",
              @"Sleep timer disabled", @"menu_sleep_off",
              @"Off", @"menu_off",
              @"15 minutes", @"menu_15",
              @"30 minutes", @"menu_30",
              @"60 minutes", @"menu_60",
              nil];
    }
    if (!ru) {
        ru = [[NSDictionary alloc] initWithObjectsAndKeys:
              @"Настройки", @"settings",
              @"Готово", @"done",
              @"О приложении", @"about",
              @"О TuneTube", @"about_tunetube",
              @"Компактный клиент YouTube Music для старых iOS.\n\n"
              "Ищите треки, артистов и альбомы, сохраняйте любимое и плейлисты, слушайте музыку в фоне. TuneTube создан для устройств, которые остались за бортом современных музыкальных приложений.\n\n"
              "Собран для iOS 5–10 на armv7 и arm64.", @"about_body",
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
              @"Быстрый выбор", @"quick_picks",
              @"Рекомендуем", @"recommendations",
              @"Смотреть всё", @"see_all",
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
              @"Включить следующим", @"menu_play_next",
              @"Добавить в плейлист", @"menu_add_playlist",
              @"Поделиться", @"menu_share",
              @"Включить микс", @"menu_mix",
              @"Добавить в очередь", @"menu_queue",
              @"Удалить из библиотеки", @"menu_remove_library",
              @"Скачать", @"menu_download",
              @"Удалить из плейлиста", @"menu_remove_playlist",
              @"Открыть альбом", @"menu_album",
              @"Перейти к исполнителю", @"menu_artist",
              @"Очистить очередь", @"menu_clear_queue",
              @"Скорость воспроизведения", @"menu_speed",
              @"Автовыключение", @"menu_sleep",
              @"Добавлено следующим треком", @"menu_play_next_added",
              @"Добавлено в очередь", @"menu_queued",
              @"Микс включен", @"menu_mix_enabled",
              @"Очередь очищена", @"menu_queue_cleared",
              @"Трек не добавлен в плейлисты", @"menu_no_playlists",
              @"Загрузка началась", @"menu_download_started",
              @"Загрузка завершена", @"menu_download_done",
              @"Не удалось скачать трек", @"menu_download_failed",
              @"Скопировано в буфер обмена", @"menu_share_copied",
              @"Автовыключение отключено", @"menu_sleep_off",
              @"Выкл.", @"menu_off",
              @"15 минут", @"menu_15",
              @"30 минут", @"menu_30",
              @"60 минут", @"menu_60",
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
