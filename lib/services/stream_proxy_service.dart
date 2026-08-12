import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/channel.dart';

/// Servidor HTTP local que retransmite vídeos (M3U, HLS e arquivos da
/// galeria) para Smart TVs via DLNA/UPnP.
///
/// TVs DLNA (em especial Samsung Tizen) validam a mídia antes de iniciar a
/// reprodução e exigem um servidor HTTP "comum":
/// - resposta a `HEAD` com `Content-Type`, `Content-Length` e
///   `Accept-Ranges` (a Samsung faz HEAD antes do GET; se HEAD falha a TV
///   exibe erro e não reproduz);
/// - `GET` com `Content-Type` compatível com H.264/AAC (video/mp4) e
///   `Content-Length` explícito;
/// - `Range` com `206 Partial Content` e `Content-Range`.
class StreamProxyService {
  HttpServer? _server;
  String? _host;
  final Map<String, _TokenEntry> _entries = {};

  Future<Uri> urlFor(Channel channel) async {
    await _ensureStarted();
    final token = base64Url.encode(utf8.encode(channel.url)).replaceAll('=', '');
    _entries[token] = _TokenEntry(channel);
    return Uri(
      scheme: 'http',
      host: _host,
      port: _server!.port,
      pathSegments: ['stream', token],
    );
  }

  /// Porta TCP em que o servidor escuta (para diagnóstico).
  int? get port => _server?.port;

  /// Endereço que o servidor se anuncia à rede (para diagnóstico).
  String? get advertisedHost => _host;

  bool get isRunning => _server != null;

  /// Testa se a URL anunciada é realmente alcançável pela rede — exatamente
  /// o que a TV fará ao tentar baixar a mídia. Se falhar, o problema é
  /// rede/endereço (TV em outra rede, Wi-Fi Direct, VPN, firewall do
  /// Android) e não o formato do vídeo.
  Future<bool> testUrl(Uri announcedUrl) async {
    final client = HttpClient();
    try {
      final request = await client
          .openUrl('GET', announcedUrl)
          .timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode == HttpStatus.partialContent ||
          response.statusCode == HttpStatus.ok) {
        await response.drain<void>();
        return true;
      }
      await response.drain<void>();
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    // Qualquer IPv4 da rede local para a TV alcançar o celular pela Wi-Fi.
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _host = await _advertisedAddress(server.port);
    unawaited(server.forEach(_handle));
  }

  /// Escolhe o endereço que será anunciado à TV. Em celulares o endereço
  /// correto é sempre o da interface Wi-Fi na mesma sub-rede da TV; nunca
  /// loopback (a TV não conseguiria acessá-lo).
  Future<String> _advertisedAddress(int port) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    // Em ambientes sem rede externa (testes automatizados, emulador sem
    // Wi-Fi), aceita o loopback para o servidor não falhar; em celular
    // real sem Wi-Fi, a exceção orienta o usuário.
    if (interfaces.isEmpty) {
      final fallback = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
      );
      if (fallback.isEmpty) {
        throw const DlnaProxyException(
          'Sem rede Wi-Fi: conecte o celular em uma rede Wi-Fi na mesma rede da TV.',
        );
      }
      // Ambientes de teste/emulador sem rede: aceitar loopback para o
      // servidor não falhar ao iniciar. Em celular real isso significa
      // ausência de Wi-Fi, e o teste de acessibilidade vai falhar antes
      // de a TV ser usada, apontando a rede como causa.
      for (final interface in fallback) {
        for (final address in interface.addresses) {
          return address.address;
        }
      }
    }
    // Prioriza endereços de interface de rede comum (sem ponto-a-ponto tipo
    // VPN/USB). Se todas forem especiais, usa a primeira disponível.
    for (final interface in interfaces) {
      if (interface.name.toLowerCase().startsWith('rmnet') ||
          interface.name.toLowerCase().startsWith('tun') ||
          interface.name.toLowerCase().startsWith('dummy')) {
        continue;
      }
      for (final address in interface.addresses) {
        return address.address;
      }
    }
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        return address.address;
      }
    }
    throw const DlnaProxyException('Não foi possível determinar o endereço de rede do celular.');
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
      final entry = _entries[token];
      if (entry == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final channel = entry.channel;
      final target = Uri.tryParse(channel.url);
      if (target == null || target.isScheme('file')) {
        // Vídeos da galeria (file://) são servidos diretamente do arquivo
        // local, sem depender de rede ou do upstream.
        await _handleLocalFile(request, target, entry);
        return;
      }
      final headers = channel.headers;

      if (request.method == 'HEAD') {
        await _handleHead(request, target, headers);
        return;
      }
      if (request.method == 'GET') {
        await _forward(request, target, headers);
        return;
      }
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD, OPTIONS');
        request.response.headers.set('Accept-Ranges', 'bytes');
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
    } catch (error) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
      // Falhas de servidor nunca chegam à TV como exceção silenciosa;
      // ela vê 500 real, útil para diagnóstico.
    }
  }

  /// Atende um arquivo local (galeria): Content-Length, Content-Type por
  /// extensão e Range/206 com Content-Range — sem depender de upstream.
  Future<void> _handleLocalFile(
    HttpRequest request,
    Uri? target,
    _TokenEntry entry,
  ) async {
    final path = target?.path ?? entry.fileOrUrlPath;
    final file = File(path);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final length = await file.length();
    final response = request.response;
    response.headers.contentType = _contentTypeFor(entry);
    response.headers.set('Accept-Ranges', 'bytes');

    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range == null) {
      response.statusCode = HttpStatus.ok;
      response.contentLength = length;
      await response.addStream(file.openRead());
      await response.close();
      return;
    }
    final parsed = _parseByteRange(range, length);
    if (parsed == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      await response.close();
      return;
    }
    final (start, end) = parsed;
    response.statusCode = HttpStatus.partialContent;
    response.contentLength = (end - start + 1);
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      await response.addStream(file.openRead(start, end - start + 1));
    await response.close();
  }

  void _propagateHeadHeaders(
    HttpHeaders upstream,
    HttpResponse response,
    Uri target,
    _TokenEntry entry,
  ) {
    final contentType = upstream.contentType?.mimeType ?? '';
    final length = upstream.contentLength;
    final isHls = target.path.toLowerCase().endsWith('.m3u8') ||
        contentType.toLowerCase().contains('mpegurl');
    if (isHls) {
      response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      response.contentLength = -1;
    } else {
      // Content-Type compatível com H.264/AAC (mp4) que a Samsung espera.
      response.headers.contentType = _contentTypeFor(entry);
      if (length >= 0) response.contentLength = length;
    }
    response.headers.set('Accept-Ranges', 'bytes');
    _forwardHeader(upstream, response.headers, 'server');
    _forwardHeader(upstream, response.headers, 'last-modified');
    _forwardHeader(upstream, response.headers, 'etag');
    _forwardHeader(upstream, response.headers, 'cache-control');
  }

  void _forwardHeader(HttpHeaders source, HttpHeaders target, String name) {
    final value = source.value(name);
    if (value != null && value.isNotEmpty) target.set(name, value);
  }

  /// Content-Type que a TV DLNA espera, determinado pela extensão do
  /// recurso original: H.264/AAC em MP4 é o formato padrão de melhor
  /// compatibilidade com Samsung/LG/Sony/Philips.
  ContentType _contentTypeFor(_TokenEntry entry) {
    final lower = entry.fileOrUrlPath.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.mov')) {
      return ContentType('video', 'mp4');
    }
    if (lower.endsWith('.mkv')) return ContentType('video', 'x-matroska');
    if (lower.endsWith('.webm')) return ContentType('video', 'webm');
    if (lower.endsWith('.ts')) return ContentType('video', 'mp2t');
    if (lower.endsWith('.m3u8')) {
      return ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return ContentType('image', 'jpeg');
    }
    if (lower.endsWith('.png')) return ContentType('image', 'png');
    if (lower.endsWith('.mp3')) return ContentType('audio', 'mpeg');
    if (lower.endsWith('.m4a')) return ContentType('audio', 'mp4');
    return ContentType('video', 'mp4');
  }

  /// HEAD para a TV: se a origem falhar (lenta/offline), a TV vê o erro
  /// real (ex.: 404/502) em vez de um 500 interno sem explicação, e o
  /// diagnóstico no app aponta a causa. Content-Type e Accept-Ranges são
  /// devolvidos mesmo sem conseguir medir o tamanho da origem.
  Future<void> _handleHead(
    HttpRequest request,
    Uri target,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      final outgoing = await client.openUrl('HEAD', target);
      headers.forEach(outgoing.headers.set);
      outgoing.followRedirects = true;
      final upstream = await outgoing.close().timeout(const Duration(seconds: 15));
      request.response.statusCode = upstream.statusCode;
      _propagateHeadHeaders(upstream.headers, request.response, target, _entries[request.uri.pathSegments.last]!);
      await upstream.drain<void>();
      await request.response.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _forward(
    HttpRequest incoming,
    Uri target,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      final outgoing = await client.openUrl('GET', target);
      headers.forEach(outgoing.headers.set);

      final range = incoming.headers.value(HttpHeaders.rangeHeader);
      if (range != null) outgoing.headers.set(HttpHeaders.rangeHeader, range);
      outgoing.followRedirects = true;

      final upstream = await outgoing.close().timeout(const Duration(seconds: 15));
      final statusCode = upstream.statusCode;
      final contentType = upstream.headers.contentType?.mimeType ?? '';
      final isHls = target.path.toLowerCase().endsWith('.m3u8') ||
          contentType.toLowerCase().contains('mpegurl');
      final response = incoming.response;

      if (statusCode == HttpStatus.partialContent) {
        // Resposta 206 da origem: repassar o trecho byte a byte com os
        // cabeçalhos de Range completos que a TV espera.
        response.statusCode = HttpStatus.partialContent;
        response.headers.set('Accept-Ranges', 'bytes');
        _forwardRangeHeaders(upstream.headers, response.headers);
        if (isHls) {
          final playlist = await utf8.decoder.bind(upstream).join();
          response.write(await _rewritePlaylist(playlist, target, headers));
        } else {
          await response.addStream(upstream);
        }
        await response.close();
        return;
      }

      if (statusCode < 200 || statusCode >= 300) {
        response.statusCode = statusCode;
        await response.close();
        return;
      }

      if (isHls) {
        response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
          charset: 'utf-8',
        );
        // Listas HLS são pequenas e de texto: reescreve os segmentos para
        // passarem pelo proxy com os mesmos cabeçalhos do canal.
        final playlist = await utf8.decoder.bind(upstream).join();
        response.write(await _rewritePlaylist(playlist, target, headers));
        await response.close();
        return;
      }

      await _streamWithContentLength(incoming, upstream, target, _entries[incoming.uri.pathSegments.last]!);
    } finally {
      client.close(force: true);
    }
  }

  void _forwardRangeHeaders(HttpHeaders upstream, HttpHeaders response) {
    final contentRange = upstream.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) response.set(HttpHeaders.contentRangeHeader, contentRange);
    _forwardHeader(upstream, response, 'content-type');
    _forwardHeader(upstream, response, 'content-length');
    _forwardHeader(upstream, response, 'content-disposition');
  }

  Future<void> _streamWithContentLength(
    HttpRequest incoming,
    HttpClientResponse upstream,
    Uri target,
    _TokenEntry entry,
  ) async {
    final response = incoming.response;
    response.headers.contentType = _contentTypeFor(entry);

    final requestedRange = incoming.headers.value(HttpHeaders.rangeHeader);
    final contentLengthHeader =
        upstream.headers.value(HttpHeaders.contentLengthHeader);
    final transferEncoding =
        upstream.headers.value(HttpHeaders.transferEncodingHeader) ?? '';

    final hasLength = contentLengthHeader != null && contentLengthHeader.isNotEmpty;
    final int? originLength = hasLength ? int.tryParse(contentLengthHeader) : null;

    if (requestedRange != null && originLength != null) {
      // A origem não entendeu o Range (200 em vez de 206). Aplicamos o
      // recorte localmente e devolvemos 206 Partial Content.
      await _applyRangeLocally(incoming, upstream, requestedRange, originLength, entry);
      return;
    }

    response.statusCode = HttpStatus.ok;
    response.headers.set('Accept-Ranges', 'bytes');

    // Se a origem informou Content-Length mas não transfer-encoding,
    // repassamos o tamanho diretamente; caso contrário retransmitimos o
    // fluxo e buscamos o tamanho em um HEAD separado da origem.
    if (hasLength && !transferEncoding.toLowerCase().contains('chunked')) {
      response.contentLength = originLength!;
      await response.addStream(upstream);
      await response.close();
      return;
    }

    final headLength = await _headContentLength(target);
    if (headLength != null) response.contentLength = headLength;
    await response.addStream(upstream);
    await response.close();
  }

  Future<int?> _headContentLength(Uri target) async {
    final client = HttpClient();
    try {
      final outgoing = await client.openUrl('HEAD', target);
      outgoing.followRedirects = true;
      outgoing.headers.set('user-agent', 'Mozilla/5.0');
      final response = await outgoing.close().timeout(const Duration(seconds: 8));
      final raw = response.headers.value(HttpHeaders.contentLengthHeader);
      await response.drain<void>();
      return raw != null ? int.tryParse(raw) : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _applyRangeLocally(
    HttpRequest incoming,
    HttpClientResponse upstream,
    String rangeHeader,
    int totalLength,
    _TokenEntry entry,
  ) async {
    final parsed = _parseByteRange(rangeHeader, totalLength);
    if (parsed == null) {
      incoming.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      incoming.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$totalLength',
      );
      await incoming.response.close();
      await upstream.drain<void>();
      return;
    }
    final (start, end) = parsed;
    incoming.response.statusCode = HttpStatus.partialContent;
    incoming.response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/$totalLength',
    );
    incoming.response.contentLength = (end - start + 1);
    incoming.response.headers.set('Accept-Ranges', 'bytes');
    incoming.response.headers.contentType = _contentTypeFor(entry);

    int position = 0;
    bool dropped = false;
    await for (final chunk in upstream) {
      final begin = position;
      final blockEnd = position + chunk.length;
      position = blockEnd;
      if (blockEnd <= start || dropped) continue;
      final sliceStart = start > begin ? start - begin : 0;
      final sliceEnd = end < blockEnd ? end - begin + 1 : chunk.length;
      if (sliceStart >= chunk.length) {
        dropped = true;
        continue;
      }
      incoming.response.add(chunk.sublist(sliceStart, sliceEnd));
      if (end < blockEnd) break;
    }
    await incoming.response.close();
  }

  (int, int)? _parseByteRange(String header, int totalLength) {
    if (!header.toLowerCase().startsWith('bytes=')) return null;
    final spec = header.substring(6).trim();
    final parts = spec.split('-');
    if (parts.length != 2) return null;
    final startRaw = parts[0].trim();
    final endRaw = parts[1].trim();
    if (startRaw.isEmpty && endRaw.isEmpty) return null;
    if (startRaw.isEmpty) {
      final suffix = int.tryParse(endRaw) ?? 0;
      if (suffix <= 0) return null;
      final s = totalLength - suffix.clamp(0, totalLength);
      return (s, totalLength - 1);
    }
    final start = int.tryParse(startRaw);
    if (start == null || start >= totalLength) return null;
    final end = endRaw.isEmpty ? totalLength - 1 : (int.tryParse(endRaw) ?? totalLength - 1);
    if (end < start) return null;
    return (start, end.clamp(start, totalLength - 1));
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
    _entries.clear();
    await _server?.close(force: true);
    _server = null;
  }
}

class _TokenEntry {
  _TokenEntry(this.channel);

  final Channel channel;

  /// Caminho do arquivo local quando o canal aponta para a galeria
  /// (file://), ou a URL remota original.
  String get fileOrUrlPath => channel.url;

  /// Seção de diagnóstico: mostra exatamente o que está sendo servido.
  @override
  String toString() => fileOrUrlPath;
}

/// Falha de rede/ambiente detectada antes de anunciar a URL à TV.
class DlnaProxyException implements Exception {
  const DlnaProxyException(this.message);
  final String message;
  @override
  String toString() => message;
}
