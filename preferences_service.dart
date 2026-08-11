import 'package:shared_preferences/shared_preferences.dart';

class PreferencesService {
  static const _favoritesKey = 'favorite_channel_ids';
  static const _historyKey = 'history_channel_ids';
  static const _playlistKey = 'playlist_url';
  static const _epgKey = 'epg_url';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();
  Future<Set<String>> favorites() async => (await _prefs).getStringList(_favoritesKey)?.toSet() ?? {};
  Future<List<String>> history() async => (await _prefs).getStringList(_historyKey) ?? [];
  Future<void> setFavorite(String id, bool value) async {
    final prefs = await _prefs;
    final ids = prefs.getStringList(_favoritesKey)?.toSet() ?? {};
    value ? ids.add(id) : ids.remove(id);
    await prefs.setStringList(_favoritesKey, ids.toList());
  }
  Future<void> addHistory(String id) async {
    final prefs = await _prefs;
    final ids = prefs.getStringList(_historyKey) ?? [];
    ids.remove(id); ids.insert(0, id);
    await prefs.setStringList(_historyKey, ids.take(50).toList());
  }
  Future<String?> playlistUrl() async => (await _prefs).getString(_playlistKey);
  Future<String?> epgUrl() async => (await _prefs).getString(_epgKey);
  Future<void> savePlaylist(String value) async => (await _prefs).setString(_playlistKey, value);
  Future<void> saveEpg(String value) async => (await _prefs).setString(_epgKey, value);
  Future<void> clearAccess() async { final p = await _prefs; await p.remove(_playlistKey); await p.remove(_epgKey); }
}
