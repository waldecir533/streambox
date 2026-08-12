import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import 'channels_store.dart';

class PreferencesService {
  static const _favoritesKey = 'favorite_channel_ids';
  static const _historyKey = 'history_channel_ids';
  static const _playlistKey = 'playlist_url';
  static const _epgKey = 'epg_url';
  static const _channelsKey = 'cached_channels';

  final ChannelsStore _channelsStore = ChannelsStore();

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  ChannelsStore get channelsStore => _channelsStore;
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
  /// Carrega os canais já persistidos em arquivo (NDJSON), decodificando
  /// em Isolate separado com tolerância a linhas corrompidas — nunca carrega
  /// uma cópia JSON gigante na memória do aplicativo.
  Future<List<Channel>> cachedChannels() => _channelsStore.loadAll();

  /// Salva os canais em arquivo (NDJSON), gravando em lotes pequenos para
  /// listas grandes. Antes da gravação, o conteúdo anterior é removido.
  Future<int> saveChannels(List<Channel> channels) async {
    await _channelsStore.clear();
    await _channelsStore.append(channels);
    return channels.length;
  }

  Future<int> channelsCount() => _channelsStore.count();

  Future<void> clearAccess() async { final p = await _prefs; await p.remove(_playlistKey); await p.remove(_epgKey); await p.remove(_channelsKey); await _channelsStore.clear(); }
}
