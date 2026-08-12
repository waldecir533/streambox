import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../models/channel.dart';
import 'stream_proxy_service.dart';

class TvStreamException implements Exception {
  const TvStreamException(this.message);
  final String message;
}

class TvStreamResolver {
  TvStreamResolver({
    http.Client? client,
    StreamProxyService? localProxy,
    String backendUrl = const String.fromEnvironment('STREAMBOX_PROXY_URL'),
    String backendToken = const String.fromEnvironment('STREAMBOX_PROXY_TOKEN'),
  })  : _client = client ?? http.Client(),
        _localProxy = localProxy ?? StreamProxyService(),
        _backendUrl = backendUrl,
        _backendToken = backendToken;

  final http.Client _client;
  final StreamProxyService _localProxy;
  final String _backendUrl;
  final String _backendToken;

  bool get hasAuthenticatedBackend =>
      _backendUrl.startsWith('https://') && _backendToken.isNotEmpty;

  Future<Uri> resolve(Channel channel) async {
    if (!_requiresProxy(channel)) return Uri.parse(channel.url);
    if (hasAuthenticatedBackend) {
      developer.log('Preparando URL opaca no proxy backend', name: 'StreamBox.Proxy');
      return _resolveWithBackend(channel);
    }
    developer.log('Usando proxy local com token opaco', name: 'StreamBox.Proxy');
    return _localProxy.urlFor(channel);
  }

  bool _requiresProxy(Channel channel) {
    if (channel.headers.isNotEmpty) return true;
    final uri = Uri.parse(channel.url);
    final keys = uri.queryParameters.keys.map((key) => key.toLowerCase());
    return keys.any((key) =>
        key.contains('token') || key.contains('signature') || key.contains('expires'));
  }

  Future<Uri> _resolveWithBackend(Channel channel) async {
    try {
      final response = await _client
          .post(
            Uri.parse(_backendUrl),
            headers: {
              HttpHeaders.authorizationHeader: 'Bearer $_backendToken',
              HttpHeaders.contentTypeHeader: 'application/json',
            },
            body: jsonEncode({
              'url': channel.url,
              'headers': channel.headers,
              'ttlSeconds': 600,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const TvStreamException('O serviço seguro de transmissão não respondeu.');
      }
      final decoded = jsonDecode(response.body);
      final url = decoded is Map ? decoded['url']?.toString() : null;
      final uri = url == null ? null : Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https') {
        throw const TvStreamException('O serviço seguro retornou uma URL inválida.');
      }
      return uri;
    } catch (error) {
      if (error is TvStreamException) rethrow;
      throw const TvStreamException('Não foi possível preparar este canal para a TV.');
    }
  }

  Future<void> dispose() async {
    await _localProxy.dispose();
    _client.close();
  }
}
