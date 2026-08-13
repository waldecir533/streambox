// Diagnóstico M3U real: cenários de provedores com comportamentos reais
// (gzip, chunked, BOM, redirect externo, captura Cloudflare) reproduzidos
// contra o PlaylistService para encontrar o motivo da falha persistente.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/services/playlist_service.dart';

const String _playlist = '#EXTM3U\r\n'
    '#EXTINF:-1 tvg-id="globo" group-title="Abertos",Globo SP\r\n'
    'http://127.0.0.1/0/live/globo.ts\r\n'
    '#EXTINF:-1 group-title="Notícias",GNT\r\n'
    'http://127.0.0.1/0/live/gnt.ts\r\n';

class _Scenario {
  _Scenario(this.path, this.handler);
  final String path;
  final void Function(HttpRequest, HttpServer) handler;
}

List<_Scenario> _handlers({required int altPort}) => [
      _Scenario('/ok.m3u', (req, srv) {
        req.response
          ..headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl')
          ..write(_playlist);
        req.response.close();
      }),
      _Scenario('/bom.m3u', (req, srv) {
        req.response
          ..headers.contentType = ContentType.text
          ..add(utf8.encode('\uFEFF'))
          ..write(_playlist);
        req.response.close();
      }),
      _Scenario('/bom-crlf.m3u', (req, srv) {
        req.response
          ..headers.contentType = ContentType.text
          ..add(utf8.encode('\uFEFF'))
          ..write(_playlist.replaceAll('\r\n', '\n'));
        req.response.close();
      }),
      _Scenario('/cloudflare.m3u', (req, srv) {
        req.response
          ..headers.contentType = ContentType.html
          ..statusCode = HttpStatus.forbidden
          ..write('<!DOCTYPE html><html><body><h1>Attention Required!</h1>'
              '<p>Cloudflare</p></body></html>');
        req.response.close();
      }),
      _Scenario('/html-chunked.m3u', (req, srv) async {
        // Sem Content-Length e com add() direto, o servidor responde
        // com Transfer-Encoding: chunked automaticamente.
        req.response.headers.contentType = ContentType.html;
        req.response.add(utf8.encode('<html><body><h1>Under Attack</h1></body></html>'));
        await req.response.close();
      }),
      _Scenario('/ok-gzip.m3u', (req, srv) async {
        // Some providers always return gzip regardless of Accept-Encoding.
        final compressed = gzip.encode(utf8.encode(_playlist));
        req.response
          ..headers.contentType = ContentType.text
          ..headers.set('Content-Encoding', 'gzip');
        req.response.add(compressed);
        await req.response.close();
      }),
      _Scenario('/redirect-externo.m3u', (req, srv) {
        req.response
          ..statusCode = HttpStatus.movedPermanently
          ..headers
              .set(HttpHeaders.locationHeader, 'http://127.0.0.1:$altPort/dest.m3u')
          ..write('');
        req.response.close();
      }),
      _Scenario('/redirect-cadeia.m3u', (req, srv) {
        // Cadeia realista: 301 (troca de domínio) → 307 (revalidação) → lista.
        req.response
          ..statusCode = HttpStatus.movedPermanently
          ..headers.set(HttpHeaders.locationHeader,
              'http://127.0.0.1:$altPort/redir-307.m3u')
          ..write('');
        req.response.close();
      }),
      _Scenario('/redir-307.m3u', (req, srv) {
        req.response
          ..statusCode = HttpStatus.temporaryRedirect
          ..headers.set(HttpHeaders.locationHeader,
              'http://127.0.0.1:$altPort/dest.m3u')
          ..write('');
        req.response.close();
      }),
      _Scenario('/dest.m3u', (req, srv) {
        // Destino do redirect — bloqueia sem UA (comportamento real).
        final ua = req.headers.value(HttpHeaders.userAgentHeader);
        final ok = (ua ?? '').startsWith('VLC') ||
            (ua ?? '').startsWith('IPTVSmarters');
        req.response
          ..statusCode = ok ? HttpStatus.ok : HttpStatus.forbidden
          ..headers.contentType = ContentType.text
          ..write(ok ? _playlist : '<html><body>Forbidden</body></html>');
        req.response.close();
      }),
      _Scenario('/html-sem-tipo.m3u', (req, srv) {
        req.response
          ..headers.contentType = ContentType.text
          ..write('<!DOCTYPE html>\r\n<html><head><title>Erro</title></head>'
              '<body><h1>403 Forbidden</h1></body></html>');
        req.response.close();
      }),
      _Scenario('/vazio.m3u', (req, srv) {
        req.response
          ..headers.contentType = ContentType.text
          ..write('');
        req.response.close();
      }),
    ];

Future<HttpServer> _serve(List<_Scenario> handlers,
    {int port = 0}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  unawaited(server.forEach((request) async {
    final found =
        handlers.where((h) => h.path == request.uri.path).toList();
    try {
      if (found.isEmpty) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      found.first.handler(request, server);
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }));
  return server;
}

void main() {
  test('gzip incondicional do provedor é descomprimido (cansa o gzip)',
      () async {
    final server = await _serve(_handlers(altPort: 0));
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'http://127.0.0.1:${server.port}/ok-gzip.m3u',
      );
      expect(result.message, isNull);
      expect(result.channels, hasLength(2));
    } finally {
      service.dispose();
      await server.close();
    }
  });

  test('BOM no início + CRLF mistura não impede a leitura da lista',
      () async {
    final server = await _serve(_handlers(altPort: 0));
    final service = PlaylistService();
    try {
      for (final path in ['/bom.m3u', '/bom-crlf.m3u', '/ok.m3u']) {
        final result = await service.importFromUrl(
          'http://127.0.0.1:${server.port}$path',
        );
        expect(
          result.channels.length,
          2,
          reason: 'falhou em $path (msg: ${result.message})',
        );
      }
    } finally {
      service.dispose();
      await server.close();
    }
  });

  test('redirect externo mantém User-Agent no destino', () async {
    final alt = await _serve(
      _handlers(altPort: 0).where((h) => h.path == '/dest.m3u').toList(),
    );
    final server = await _serve(_handlers(altPort: alt.port));
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'http://127.0.0.1:${server.port}/redirect-externo.m3u',
      );
      expect(result.channels, hasLength(2));
    } finally {
      service.dispose();
      await server.close();
      await alt.close();
    }
  });

  test('cadeia 301 → 307 é seguida mantendo User-Agent no destino', () async {
    // Cada handler captura 'altPort' no momento da criação; por isso o
    // servidor que hospeda /redir-307.m3u precisa ser criado COM a porta
    // real do destino já conhecida.
    Future<HttpServer> serveRedir307(int destPort) => _serve([
          _Scenario('/redir-307.m3u', (req, srv) {
            req.response
              ..statusCode = HttpStatus.temporaryRedirect
              ..headers.set(HttpHeaders.locationHeader,
                  'http://127.0.0.1:$destPort/dest.m3u')
              ..write('');
            req.response.close();
          }),
        ]);
    final alt = await _serve(
      _handlers(altPort: 0).where((h) => h.path == '/dest.m3u').toList(),
    );
    final mid = await serveRedir307(alt.port);
    final server = await _serve(_handlers(altPort: mid.port));
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'http://127.0.0.1:${server.port}/redirect-cadeia.m3u',
      );
      if (result.message != null) {
        fail('falha inesperada na cadeia 301 → 307: ${result.message}');
      }
      expect(result.channels, hasLength(2));
    } finally {
      service.dispose();
      await server.close();
      await mid.close();
      await alt.close();
    }
  });

  test('Cloudflare/HTML 403 vira mensagem clara em vez de "falha de rede"',
      () async {
    final server = await _serve(_handlers(altPort: 0));
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'http://127.0.0.1:${server.port}/cloudflare.m3u',
      );
      expect(result.statusCode, 403);
      expect((result.message ?? ''), contains('403'));
    } finally {
      service.dispose();
      await server.close();
    }
  });

  test('HTML devolvido como text/plain é detectado pelo conteúdo', () async {
    final server = await _serve(_handlers(altPort: 0));
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'http://127.0.0.1:${server.port}/html-sem-tipo.m3u',
      );
      expect(result.message, contains('HTML'));
    } finally {
      service.dispose();
      await server.close();
    }
  });

  test('resposta vazia recebe mensagem específica', () async {
    final server = await _serve(_handlers(altPort: 0));
    final service = PlaylistService();
    try {
      final result = await service.importFromUrl(
        'http://127.0.0.1:${server.port}/vazio.m3u',
      );
      expect(result.message, contains('vazia'));
    } finally {
      service.dispose();
      await server.close();
    }
  });
}
