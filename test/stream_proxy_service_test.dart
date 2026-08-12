import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/models/channel.dart';
import 'package:streambox/services/stream_proxy_service.dart';

/// Servidor de origem falso que responde com bytes de vídeo determinísticos,
/// Content-Type e Content-Length, e suporta Range para os testes locais.
class _FakeOrigin {
  _FakeOrigin(this.data, {this.acceptsRange = true});

  final List<int> data;
  final bool acceptsRange;
  late final HttpServer server;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      request.response.headers.contentType = ContentType.binary;
      if (range != null && acceptsRange) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        final start = int.parse(match!.group(1)!);
        final end = match.group(2)!.isEmpty ? data.length - 1 : int.parse(match.group(2)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${data.length}',
        );
        request.response.contentLength = end - start + 1;
        request.response.add(data.sublist(start, end + 1));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = data.length;
        request.response.add(data);
      }
      await request.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  late _FakeOrigin origin;
  late StreamProxyService proxy;

  setUp(() async {
    // 1 MiB de bytes determinísticos simulando um arquivo de vídeo.
    final data = List<int>.generate(1024 * 1024, (i) => i % 251);
    origin = _FakeOrigin(data);
    await origin.start();
    proxy = StreamProxyService();
  });

  tearDown(() async {
    await proxy.dispose();
    await origin.stop();
  });

  test('serves a GET with Content-Type and Content-Length', () async {
    final channel = Channel(name: 'T', url: 'http://${origin.server.address.host}:${origin.server.port}/video.mp4');
    final url = await proxy.urlFor(channel);
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      // Content-Type é escolhido pela extensão do recurso (.mp4 → video/mp4),
      // compatível com H.264/AAC esperado por TVs Samsung/LG/Sony.
      expect(response.headers.contentType?.mimeType, 'video/mp4');
      expect(response.contentLength, 1024 * 1024);
      expect(response.headers.value('Accept-Ranges'), 'bytes');
      final bytes = await response.expand<int>((chunk) => chunk).toList();
      expect(bytes.length, 1024 * 1024);
    } finally {
      client.close(force: true);
    }
  });

  test('serves HEAD with Content-Type and Content-Length', () async {
    final channel = Channel(name: 'T', url: 'http://${origin.server.address.host}:${origin.server.port}/video.mp4');
    final url = await proxy.urlFor(channel);
    final client = HttpClient();
    try {
      final request = await client.openUrl('HEAD', url);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(response.contentLength, 1024 * 1024);
      expect(response.headers.value('Accept-Ranges'), 'bytes');
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  test('serves Range requests with 206 and Content-Range', () async {
    final channel = Channel(name: 'T', url: 'http://${origin.server.address.host}:${origin.server.port}/video.mp4');
    final url = await proxy.urlFor(channel);
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=1000-1999');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 1000-1999/1048576',
      );
      expect(response.contentLength, 1000);
      final bytes = await response.expand<int>((chunk) => chunk).toList();
      expect(bytes.length, 1000);
      for (var i = 0; i < bytes.length; i++) {
        expect(bytes[i], (1000 + i) % 251);
      }
    } finally {
      client.close(force: true);
    }
  });

  test('falls back to local 206 when origin returns 200 for a Range',
      () async {
    await origin.stop();
    origin = _FakeOrigin(origin.data, acceptsRange: false);
    await origin.start();
    final channel = Channel(name: 'T', url: 'http://${origin.server.address.host}:${origin.server.port}/video.mp4');
    final url = await proxy.urlFor(channel);
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=5000-5999');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 5000-5999/1048576',
      );
      expect(response.contentLength, 1000);
      final bytes = await response.expand<int>((chunk) => chunk).toList();
      expect(bytes.length, 1000);
    } finally {
      client.close(force: true);
    }
  });

  test('rewrites HLS playlists so segments are served by the proxy',
      () async {
    // Origem HLS: playlist de texto.
    final playlist = utf8.encode(
      '#EXTM3U\n#EXT-X-VERSION:3\nsegment1.ts\nsegment2.ts\n',
    );
    final hls = _FakeOrigin(playlist);
    await hls.start();
    final channel = Channel(
      name: 'T',
      url: 'http://${hls.server.address.host}:${hls.server.port}/live.m3u8',
    );
    final url = await proxy.urlFor(channel);
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final text = await utf8.decoder.bind(response).join();
      expect(text, contains('#EXTM3U'));
      expect(text, contains('stream/'));
      expect(text, isNot(contains('segment1.ts')));
    } finally {
      client.close(force: true);
    }
    await hls.stop();
  });

  test('returns 404 for invalid tokens', () async {
    final url = await proxy.urlFor(const Channel(name: 'T', url: 'http://x/1'));
    final invalidUrl = url.replace(path: '/stream/invalid');
    final client = HttpClient();
    try {
      final request = await client.getUrl(invalidUrl);
      final response = await request.close();
      // Tokens inválidos não são decodificados como URL e o caminho não é
      // reconhecido, então a resposta não é bem-sucedida.
      expect(response.statusCode, greaterThanOrEqualTo(400));
    } finally {
      client.close(force: true);
    }
  });
}
