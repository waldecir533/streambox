import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/services/playlist_service.dart';
import 'package:streambox/services/m3u_parser.dart';
import 'package:streambox/services/xtream_service.dart';

/// Cliente falso que responde 302 → 200 (redirect com destino exigindo
/// User-Agent) e também simula resposta Transfer-Encoding: chunked.
http.Client _redirectClient(List<String> touchedUrls) {
  var step = 0;
  return MockClient((request) async {
    touchedUrls.add('${request.method} ${request.url}');
    step++;
    if (step == 1) {
      return http.Response('', 302,
          headers: {'location': 'http://origin.test/lista-final.m3u'});
    }
    final hasUa = (request.headers['User-Agent'] ?? '').isNotEmpty;
    if (!hasUa) {
      return http.Response('acesso negado', 403);
    }
    // Resposta com codificação chunked, como vários provedores retornam.
    final body = '#EXTM3U\r\n#EXTINF:-1 group-title="Abertos",TV Globo\r\nhttp://tv.test/globo.ts\r\n';
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'application/vnd.apple.mpegurl'},
    );
  });
}

void main() {
  group('Bug 1 — redirects mantêm headers', () {
    test('segue 302 repassando User-Agent no destino', () async {
      final touched = <String>[];
      final service = PlaylistService(client: _redirectClient(touched));
      final result =
          await service.importFromUrl('http://origin.test/lista.m3u');
      expect(result.sourceType, SourceType.playlist);
      expect(result.channels.length, 1);
      expect(result.channels.first.name, 'TV Globo');
      // A primeira requisição (302) e o destino final receberam o UA.
      expect(touched.first, contains('http://origin.test/lista.m3u'));
      expect(touched.last, contains('/lista-final.m3u'));
    });

    test('classifica corpo vazio/HTML com mensagem clara', () async {
      final service = PlaylistService(client: MockClient((request) async {
        return http.Response('<html>bloqueado</html>', 200,
            headers: {'content-type': 'text/html; charset=utf-8'});
      }));
      final result =
          await service.importFromUrl('http://origin.test/bloqueio.m3u');
      expect(result.channels, isEmpty);
      expect(result.message, isNotEmpty);
    });
  });

  group('Bug 2 — Xtream Codes', () {
    test('aceita resposta no formato {live_streams: [...]}', () async {
      final service = XtreamService(client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'live_streams': [
              {
                'stream_id': 42,
                'name': 'Canal Nacional',
                'stream_icon': 'http://tv.test/logo.png',
                'category_name': 'Abertos',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }));
      final channels = await service.load(
        server: 'http://xtream.test:8080/',
        username: 'usuario teste',
        password: 'senha/ok',
      );
      expect(channels.length, 1);
      // Formato esperado: http://servidor:porta/live/usuario/senha/streamID.ts
      // com usuário e senha codificados (espaço → %20, barra → %2F).
      expect(channels.first.url,
          'http://xtream.test:8080/live/usuario%20teste/senha%2Fok/42.ts');
      // O canal carrega headers para o player reproduzir o stream.
      expect(channels.first.headers['User-Agent'], isNotEmpty);
    });

    test('envia User-Agent na chamada de login', () async {
      String? receivedUa;
      final service = XtreamService(client: MockClient((request) async {
        receivedUa = request.headers['User-Agent'];
        return http.Response(jsonEncode({'live_streams': []}), 200,
            headers: {'content-type': 'application/json'});
      }));
      try {
        await service.load(
          server: 'http://xtream.test:8080',
          username: 'u',
          password: 'p',
        );
      } on FormatException {
        // Esperado: nenhum canal na resposta.
      }
      expect(receivedUa, isNotNull);
      expect(receivedUa, contains('StreamBox'));
    });

    test('resposta em lista direta também é aceita', () async {
      final service = XtreamService(client: MockClient((request) async {
        return http.Response(
          jsonEncode([
            {'stream_id': 7, 'name': 'Lista Direta'},
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }));
      final channels = await service.load(
        server: 'http://xtream.test:8080/',
        username: 'u',
        password: 'p',
      );
      expect(channels.length, 1);
      expect(channels.first.headers['User-Agent'], isNotEmpty);
    });
  });
}
