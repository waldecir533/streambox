// Tarefa 2: reproduzir a falha "Falha de rede ao baixar a lista" com as
// causas prováveis e validar o log temporário de status HTTP + 500 chars.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/services/playlist_service.dart';

Future<HttpServer> _serveServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(server.forEach((request) async {
    final path = request.uri.path;
    final ua = request.headers.value(HttpHeaders.userAgentHeader);
    try {
      if (path == '/ok.m3u') {
        request.response
          ..headers.contentType = ContentType.text
          ..write('#EXTM3U\n#EXTINF:-1 tvg-name="Teste 1",Canal Teste\n'
              'http://127.0.0.1:${server.port}/stream\n');
      } else if (path == '/block.m3u') {
        if (ua == null || !ua.startsWith('StreamBox')) {
          request.response.statusCode = HttpStatus.forbidden;
          request.response.write('<html><body>Forbidden</body></html>');
        } else {
          request.response
            ..headers.contentType = ContentType.text
            ..write('#EXTM3U\n#EXTINF:-1 tvg-name="Ok com UA",Canal\nhttp://x\n');
        }
      } else if (path == '/html.m3u') {
        request.response
          ..headers.contentType = ContentType.html
          ..write('<!DOCTYPE html><html><head><title>Access Denied</title>'
              '</head><body><h1>Access Denied</h1></body></html>');
        await request.response.close();
        return;
      }
      await request.response.close();
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }));
  return server;
}

void main() {
  test('URL .onion recebe mensagem específica em vez de falha de rede',
      () async {
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'https://hightechtvr1.onion/lista.m3u',
      );
      expect(result.statusCode, isNull);
      expect(result.message, contains('.onion'));
    } finally {
      service.dispose();
    }
  });

  test('domínio inexistente (DNS) gera mensagem de rede, sem exceção bruta',
      () async {
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'http://provedor-que-nao-existe-xyz123.br/lista.m3u',
      );
      expect(result.statusCode, isNull);
      expect(
        (result.message ?? '').toLowerCase(),
        anyOf(contains('endereço'), contains('rede'), contains('internet')),
      );
    } finally {
      service.dispose();
    }
  });

  test('provedor que exige User-Agent devolve 403 sem UA', () async {
    final server = await _serveServer();
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'http://127.0.0.1:${server.port}/block.m3u',
      );
      // O cliente do app envia 'StreamBox-IPTV/...', então a lista carrega.
      // Este teste comprova que o UA é enviado: sem ele, o resultado seria 403.
      expect(result.statusCode, isNull);
      expect(result.channels, isNotEmpty);
    } finally {
      service.dispose();
      await server.close();
    }
  });

  test('provedor que responde HTML em vez da lista gera mensagem clara',
      () async {
    final server = await _serveServer();
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'http://127.0.0.1:${server.port}/html.m3u',
      );
      expect(result.sourceType?.name ?? '', isNot('playlist'));
      expect(result.message, anyOf(contains('HTML'), contains('página')));
    } finally {
      service.dispose();
      await server.close();
    }
  });

  test('importFromUrl nunca lança exceção bruta (mesmo com servidor lento)',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((request) async {
      await Future<void>.delayed(const Duration(seconds: 60));
      await request.response.close();
    }));
    final service = PlaylistService(timeout: const Duration(seconds: 6));
    try {
      final result = await service.importFromUrl(
        'http://127.0.0.1:${server.port}/slow.m3u',
      );
      expect((result.message ?? '').toLowerCase(), contains('demorou'));
    } finally {
      service.dispose();
      await server.close();
    }
  });
}
