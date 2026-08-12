import 'dart:async';

import 'package:http/http.dart' as http;

import '../models/channel.dart';
import 'm3u_parser.dart';

class PlaylistService {
  PlaylistService({
    http.Client? client,
    this.timeout = const Duration(seconds: 45),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;
  final M3uParser _parser = const M3uParser();

  /// Token de cancelamento da operação em andamento (por exemplo, quando a
  /// tela é fechada antes do fim do download/análise).
  CancelToken? cancelToken;

  /// Carrega e analisa a playlist a partir de uma URL. O download respeita
  /// redirecionamentos (http -> https, 301/302) automaticamente e a análise
  /// ocorre em um Isolate separado, com progresso opcional.
  Future<List<Channel>> loadFromUrl(
    String rawUrl, {
    void Function(double progress)? onProgress,
  }) async {
    cancelToken?.cancel();
    cancelToken = CancelToken();

    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Informe uma URL http:// ou https:// válida.');
    }

    final http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } on TimeoutException {
      throw TimeoutException(
        'A conexão com o servidor da lista demorou mais que o esperado.',
        Duration(seconds: 45),
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('A playlist respondeu HTTP ${response.statusCode}.');
    }

    final body = response.body;
    if (body.trim().isEmpty) {
      throw const FormatException('A lista retornou vazia do servidor.');
    }

    // Análise em Isolate separado (não trava a interface com listas grandes)
    // e com timeout próprio, independente do download.
    final channels = await _parser.parseAsync(
      body,
      timeout: const Duration(minutes: 2),
      cancelToken: cancelToken,
      onProgress: onProgress,
    );

    if (channels.isEmpty) {
      throw const FormatException('Nenhum canal válido foi encontrado na playlist.');
    }

    return channels;
  }

  void dispose() {
    cancelToken?.cancel();
    _client.close();
  }
}
