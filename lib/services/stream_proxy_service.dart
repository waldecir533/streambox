import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/channel.dart';

class StreamProxyService {
  HttpServer? _server;
  String? _host;
  final Map<String, Map<String, String>> _headersByToken = {};

  Future<Uri> urlFor(Channel channel) async {
    await _ensureStarted();
    final token = base64Url.encode(utf8.encode(channel.url)).replaceAll('=', '');
    _headersByToken[token] = channel.headers;
    return Uri(
      scheme: 'http',
      host: _host,
      port: _server!.port,
      pathSegments: ['stream', token],
    );
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    _host = await _localIpv4();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    unawaited(server.forEach(_handle));
  }

  Future<String> _localIpv4() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) return address.address;
      }
    }
    throw const SocketException('Nenhuma rede local disponível.');
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.pathSegments.length != 2 ||
          request.uri.pathSegments.first != 'stream') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final token = request.uri.pathSegments[1];
      final target = Uri.parse(
        utf8.decode(base64Url.decode(base64Url.normalize(token))),
      );
      final headers = _headersByToken[token] ?? const <String, String>{};
      await _forward(request, target, headers);
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    }
  }

  Future<void> _forward(
    HttpRequest incoming,
    Uri target,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      final outgoing = await client.openUrl(incoming.method, target);
      headers.forEach(outgoing.headers.set);
      final range = incoming.headers.value(HttpHeaders.rangeHeader);
      if (range != null) outgoing.headers.set(HttpHeaders.rangeHeader, range);
      outgoing.followRedirects = true;
      final upstream = await outgoing.close().timeout(const Duration(seconds: 15));
      final contentType = upstream.headers.contentType?.mimeType ?? '';
      final isHls = target.path.toLowerCase().endsWith('.m3u8') ||
          contentType.contains('mpegurl');
      incoming.response.statusCode = upstream.statusCode;
      if (isHls) {
        incoming.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
          charset: 'utf-8',
        );
        final playlist = await utf8.decoder.bind(upstream).join();
        incoming.response.write(await _rewritePlaylist(playlist, target, headers));
      } else {
        upstream.headers.forEach((name, values) {
          if (name.toLowerCase() != 'transfer-encoding' &&
              name.toLowerCase() != 'connection') {
            incoming.response.headers.set(name, values);
          }
        });
        await incoming.response.addStream(upstream);
      }
      await incoming.response.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _rewritePlaylist(
    String playlist,
    Uri base,
    Map<String, String> headers,
  ) async {
    final output = <String>[];
    for (final line in const LineSplitter().convert(playlist)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        output.add(line);
      } else {
        final resolved = base.resolve(trimmed);
        final channel = Channel(name: 'segment', url: resolved.toString(), headers: headers);
        output.add((await urlFor(channel)).toString());
      }
    }
    return '${output.join('\n')}\n';
  }

  Future<void> dispose() async {
    _headersByToken.clear();
    await _server?.close(force: true);
    _server = null;
  }
}
