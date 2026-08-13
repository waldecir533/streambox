import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/channel.dart';

class XtreamService {
  XtreamService({http.Client? client, String? userAgent})
      : _client = client ?? http.Client(),
        // User-Agent de player IPTV comum: painéis Xtream frequentemente
        // bloqueiam UAs desconhecidos (404/403) e liberam players conhecidos
        // como VLC/3.0.20 LibVLC/3.0.20 ou IPTV Smarters.
        _userAgent = userAgent ?? 'VLC/3.0.20 LibVLC/3.0.20';
  final http.Client _client;
  final String _userAgent;

  Map<String, String> get _defaultHeaders => {'User-Agent': _userAgent};

  Future<List<Channel>> load({
    required String server,
    required String username,
    required String password,
  }) async {
    final base = server.trim().replaceAll(RegExp(r'/+$'), '');
    final root = Uri.tryParse(base);
    if (root == null ||
        !root.hasScheme ||
        !{'http', 'https'}.contains(root.scheme)) {
      throw const FormatException(
          'Informe um servidor http:// ou https:// válido.');
    }
    if (username.trim().isEmpty || password.isEmpty) {
      throw const FormatException('Informe usuário e senha.');
    }
    final uri = Uri.parse('$base/player_api.php').replace(
      queryParameters: {
        'username': username.trim(),
        'password': password,
        'action': 'get_live_streams',
      },
    );
    final response =
        await _client.get(uri, headers: _defaultHeaders).timeout(
              const Duration(seconds: 20),
            );
    if (response.statusCode != 200) {
      throw Exception('Servidor respondeu HTTP ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);

    // Servidores Xtream retornam dois formatos:
    // 1. Objeto: {"live_streams": [{...}, ...]} (padrão Xtream Codes)
    // 2. Lista direta: [{"stream_id": ..., ...}, ...]
    List<Map> items;
    if (decoded is List) {
      items = decoded.whereType<Map>().toList();
    } else if (decoded is Map) {
      final raw = decoded['live_streams'] ?? decoded;
      items = raw is List ? raw.whereType<Map>().toList() : <Map>[];
    } else {
      items = <Map>[];
    }
    if (items.isEmpty) {
      throw const FormatException(
          'A resposta do servidor não continha canais válidos.');
    }

    final encodedUser = Uri.encodeComponent(username.trim());
    final encodedPass = Uri.encodeComponent(password);
    final headers = <String, String>{'User-Agent': _userAgent};
    return items.map((raw) {
      final map = raw.cast<dynamic, dynamic>();
      final streamId = '${map['stream_id'] ?? ''}';
      return Channel(
        name: '${map['name'] ?? 'Canal'}',
        url:
            '$base/live/$encodedUser/$encodedPass/$streamId.ts',
        logoUrl: map['stream_icon']?.toString(),
        group: map['category_name']?.toString(),
        tvgId: map['epg_channel_id']?.toString(),
        headers: headers,
      );
    }).where((c) => c.url.isNotEmpty).toList();
  }

  void dispose() => _client.close();
}
