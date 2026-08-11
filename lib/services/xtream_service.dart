import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/channel.dart';

class XtreamService {
  XtreamService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<List<Channel>> load({required String server, required String username, required String password}) async {
    final base = server.trim().replaceAll(RegExp(r'/+$'), '');
    final root = Uri.tryParse(base);
    if (root == null || !root.hasScheme || !{'http', 'https'}.contains(root.scheme)) {
      throw const FormatException('Informe um servidor http:// ou https:// válido.');
    }
    if (username.trim().isEmpty || password.isEmpty) throw const FormatException('Informe usuário e senha.');
    final uri = Uri.parse('$base/player_api.php').replace(queryParameters: {'username': username.trim(), 'password': password, 'action': 'get_live_streams'});
    final response = await _client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw Exception('Servidor respondeu HTTP ${response.statusCode}.');
    final decoded = jsonDecode(response.body);
    if (decoded is! List) throw const FormatException('Resposta Xtream inválida.');
    return decoded.whereType<Map>().map((raw) {
      final map = raw.cast<dynamic, dynamic>();
      final streamId = '${map['stream_id'] ?? ''}';
      return Channel(name: '${map['name'] ?? 'Canal'}', url: '$base/live/${Uri.encodeComponent(username.trim())}/${Uri.encodeComponent(password)}/$streamId.ts', logoUrl: map['stream_icon']?.toString(), group: map['category_name']?.toString(), tvgId: map['epg_channel_id']?.toString());
    }).where((c) => c.url.isNotEmpty).toList();
  }
  void dispose() => _client.close();
}
