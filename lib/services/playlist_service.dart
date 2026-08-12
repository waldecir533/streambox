import 'package:http/http.dart' as http;

import '../models/channel.dart';
import 'm3u_parser.dart';

class PlaylistService {
  PlaylistService({http.Client? client, this.timeout = const Duration(seconds: 20)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;
  final M3uParser _parser = const M3uParser();

  Future<List<Channel>> loadFromUrl(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Informe uma URL http:// ou https:// válida.');
    }

    final response = await _client.get(uri).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('A playlist respondeu HTTP ${response.statusCode}.');
    }

    final channels = _parser.parse(response.body);
    if (channels.isEmpty) {
      throw const FormatException('Nenhum canal válido foi encontrado na playlist.');
    }

    return channels;
  }

  void dispose() => _client.close();
}
