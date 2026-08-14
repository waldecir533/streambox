import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import 'channels_store.dart';
import 'playlist_service.dart';

class PreferencesService {
  static const _favoritesKey = 'favorite_channel_ids';
  static const _historyKey = 'history_channel_ids';
  static const _playlistKey = 'playlist_url';
  static const _epgKey = 'epg_url';
  static const _channelsKey = 'cached_channels';
  static const _playerEngineKey = 'player_engine_preference';
  static const _castingEnabledKey = 'casting_enabled';
  static const _fullscreenLandscapeKey = 'fullscreen_landscape';
  static const _xtreamServerKey = 'xtream_server';
  static const _xtreamUserKey = 'xtream_username';
  static const _xtreamPassKey = 'xtream_password';

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
  /// listas grandes. A substituição é **transacional**: os canais novos são
  /// gravados em um arquivo temporário e só no final o arquivo atual é
  /// substituído de forma atômica — a lista anterior permanece intacta se
  /// algo falhar no meio.
  Future<int> saveChannels(List<Channel> channels) =>
      _channelsStore.saveAll(channels);

  Future<int> channelsCount() => _channelsStore.count();

  Future<void> clearAccess() async { final p = await _prefs; await p.remove(_playlistKey); await p.remove(_epgKey); await p.remove(_channelsKey); await _channelsStore.clear(); }

  // ---- Preferências de Configurações (valores pequenos) ----

  /// Motor preferido do player: 'automatic', 'media3' ou 'libvlc'.
  Future<String> playerEnginePreference() async =>
      (await _prefs).getString(_playerEngineKey) ?? 'automatic';
  Future<void> savePlayerEnginePreference(String value) async =>
      (await _prefs).setString(_playerEngineKey, value);

  /// Transmissão para TV (DLNA/Cast) habilitada pelo usuário. O serviço de
  /// transmissão NÃO inicia automaticamente: só quando solicitado.
  Future<bool> castingEnabled() async =>
      (await _prefs).getBool(_castingEnabledKey) ?? false;
  Future<void> saveCastingEnabled(bool value) async =>
      (await _prefs).setBool(_castingEnabledKey, value);

  /// Tela cheia em modo paisagem.
  Future<bool> fullscreenLandscape() async =>
      (await _prefs).getBool(_fullscreenLandscapeKey) ?? true;
  Future<void> saveFullscreenLandscape(bool value) async =>
      (await _prefs).setBool(_fullscreenLandscapeKey, value);

  // ---- Acesso Xtream (credenciais nunca aparecem em log) ----

  Future<String?> xtreamServer() async => (await _prefs).getString(_xtreamServerKey);
  Future<String?> xtreamUser() async => (await _prefs).getString(_xtreamUserKey);
  Future<String?> xtreamPassword() async => (await _prefs).getString(_xtreamPassKey);
  Future<void> saveXtreamAccess({required String server, required String username, required String password}) async {
    final p = await _prefs;
    await p.setString(_xtreamServerKey, server);
    await p.setString(_xtreamUserKey, username);
    await p.setString(_xtreamPassKey, password);
  }
  Future<void> clearXtreamAccess() async {
    final p = await _prefs;
    await p.remove(_xtreamServerKey);
    await p.remove(_xtreamUserKey);
    await p.remove(_xtreamPassKey);
    await p.remove(_channelsKey);
    await _channelsStore.clear();
  }

  /// Atualiza a lista M3U salva com a importação robusta da Fase 1 (gravação
  /// transacional em lotes; a lista anterior permanece intacta se falhar).
  Future<PlaylistRefreshResult> refreshPlaylistFromUrl(String url) async {
    final playlist = PlaylistService();
    try {
      final result = await playlist.importFromUrl(url);
      if (!result.isSuccess) {
        return PlaylistRefreshResult(success: false, count: 0,
            message: result.message ?? 'Conteúdo não reconhecido como lista.');
      }
      await saveChannels(result.channels);
      await savePlaylist(url);
      return PlaylistRefreshResult(success: true, count: result.channels.length);
    } finally {
      playlist.cancelToken?.cancel();
      playlist.dispose();
    }
  }
}

/// Resultado de uma atualização de playlist (atualização, não importação nova).
class PlaylistRefreshResult {
  const PlaylistRefreshResult({required this.success, required this.count, this.message});
  final bool success;
  final int count;
  final String? message;
}
