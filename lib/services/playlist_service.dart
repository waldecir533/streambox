import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/channel.dart';
import 'm3u_parser.dart';

/// Resultado de uma tentativa de importação: os canais validados ou o tipo
/// de fonte detectado com mensagem de erro amigável (HTML, JSON, stream
/// individual etc.), sem nunca lançar exceção "seca" para a interface.
class ImportResult {
  const ImportResult({
    this.channels = const [],
    this.sourceType,
    this.message,
    this.statusCode,
    this.skippedLines = 0,
    this.bytes = 0,
  });

  final List<Channel> channels;
  final SourceType? sourceType;
  final String? message;
  final int? statusCode;
  final int skippedLines;
  final int bytes;

  bool get isSuccess => channels.isNotEmpty && sourceType == SourceType.playlist;
  bool get isIndividualStream => sourceType == SourceType.hlsStream ||
      sourceType == SourceType.directStream;
}

/// Mensagem amigável para códigos de status HTTP comuns.
String _statusMessage(int code) {
  switch (code) {
    case 401:
      return 'O endereço exige usuário e senha. Se a lista vem de um provedor, '
          'confira se a URL inclui o login ou use a aba Xtream com servidor, '
          'usuário e senha.';
    case 403:
      return 'O servidor recusou o acesso (erro 403). O provedor pode estar '
          'bloqueando downloads ou o link expirou. Tente atualizar o link na '
          'área do cliente dele.';
    case 404:
      return 'O endereço não foi encontrado (erro 404). Confira se o link da '
          'lista está correto e completo, sem espaços ou quebras.';
    case 429:
      return 'Muitas solicitações seguidas (erro 429). Aguarde alguns minutos '
          'e tente novamente.';
    case 502:
    case 503:
    case 504:
      return 'O servidor da lista está fora do ar ou em manutenção (erro '
          '$code). Tente mais tarde.';
    default:
      if (code >= 500) {
        return 'O servidor da lista respondeu com erro ($code). Tente mais '
            'tarde ou confira o link com o provedor.';
      }
      return 'O servidor respondeu com código HTTP $code.';
  }
}

/// Mensagem para falhas de rede (DNS, SSL, conexão).
String _networkMessage(dynamic error) {
  final text = error.toString().toLowerCase();
  if (text.contains('socket') || text.contains('connection refused') ||
      text.contains('failed host lookup') || text.contains('os error')) {
    return 'Não foi possível se conectar ao servidor. Verifique a internet '
        'e se o endereço da lista está correto.';
  }
  if (text.contains('certificate') || text.contains('handshake') ||
      text.contains('ssl') || text.contains('tls')) {
    return 'Falha de segurança na conexão (certificado SSL). Verifique a '
        'data/hora do aparelho e tente novamente.';
  }
  return 'Falha de rede ao baixar a lista. Verifique a conexão e tente '
      'novamente.';
}

/// Exceção com mensagem amigável quando a fonte não é uma playlist
/// (HTML, JSON, stream individual). É capturada pela interface para exibir
/// a mensagem específica em vez de um erro genérico.
class ImportSourceException implements Exception {
  const ImportSourceException(this.message);
  final String message;
  @override String toString() => message;
}

class PlaylistService {
  PlaylistService({
    http.Client? client,
    this.timeout = const Duration(seconds: 45),
  }) : _client = client ?? _createNoRedirectClient();

  /// Cliente que NÃO segue redirecionamentos automaticamente: quem controla
  /// os saltos é [_getFollowingRedirects], que mantém os headers
  /// personalizados (User-Agent) em cada passo.
  static http.Client _createNoRedirectClient() => _ManualClient();

  final http.Client _client;
  final Duration timeout;
  final M3uParser _parser = const M3uParser();

  /// Token de cancelamento da operação em andamento (por exemplo, quando a
  /// tela é fechada antes do fim do download/análise).
  CancelToken? cancelToken;

  /// Baixa e analisa uma playlist a partir de uma URL. Primeiro inspeciona o
  /// conteúdo para classificar o tipo de fonte (playlist, stream individual,
  /// HTML, JSON...), garantindo que um `.m3u8` de um único programa não seja
  /// confundido com uma lista. Erros de rede e HTTP geram mensagens
  /// específicas em vez de travar o aplicativo.
  Future<ImportResult> importFromUrl(
    String rawUrl, {
    void Function(double progress)? onProgress,
  }) async {
    cancelToken?.cancel();
    cancelToken = CancelToken();
    final token = cancelToken!;

    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return ImportResult(
        sourceType: SourceType.unknown,
        message: 'Informe uma URL http:// ou https:// válida.',
      );
    }

    // URLs .onion só resolvem dentro da rede Tor; por fora, o DNS falha
    // silenciosamente e a lista "não carrega". Informe o usuário em vez de
    // deixá-lo pensar que é um defeito do app ou da internet.
    if (uri.host.endsWith('.onion')) {
      return const ImportResult(
        sourceType: SourceType.unknown,
        message: 'Essa URL é da rede Tor (.onion) e só funciona dentro dela. '
            'Use uma URL normal (http:// ou https://) para a lista — o '
            'StreamBox não usa a rede Tor.',
      );
    }

    final List<int> bodyBytes;
    final http.Response response;
    try {
      // Redirect manual: o cliente padrão do Dart segue redirecionamentos,
      // mas DESCARTA headers personalizados (User-Agent, Accept-Encoding) no
      // salto — e muitos provedores IPTV bloqueiam o destino do redirect
      // sem esses headers (403 silencioso). Então seguimos os redirects
      // nós mesmos, sempre repassando os mesmos headers.
      response = await _getFollowingRedirects(uri, const {
        'Accept-Encoding': 'gzip',
        'User-Agent': 'StreamBox-IPTV/0.7',
      }).timeout(timeout);
    } on TimeoutException {
      return ImportResult(
        sourceType: SourceType.unknown,
        message: 'A conexão com o servidor da lista demorou mais que o '
            'esperado. Verifique a internet e tente novamente.',
      );
    } catch (error) {
      return ImportResult(
        sourceType: SourceType.unknown,
        message: _networkMessage(error),
      );
    }

    // Log temporário de diagnóstico: status HTTP e início do conteúdo
    // devolvido, para identificar provedores que respondem com página de
    // erro/HTML em vez da lista (sem registrar credenciais ou URL completa).
    debugPrint(
      '[StreamBox] Resposta da lista: HTTP ${response.statusCode} '
      '${response.contentLength} bytes | início: '
      '${_preview(response.bodyBytes)}',
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return ImportResult(
        statusCode: response.statusCode,
        sourceType: SourceType.unknown,
        message: _statusMessage(response.statusCode),
      );
    }

    bodyBytes = response.bodyBytes;
    if (bodyBytes.isEmpty) {
      return const ImportResult(
        statusCode: 204,
        sourceType: SourceType.unknown,
        message: 'A lista retornou vazia do servidor.',
      );
    }
    final head = M3uParser.decodeText(bodyBytes.take(8 * 1024).toList());
    final trimmed = head.trim();
    if (trimmed.isEmpty) {
      return const ImportResult(
        sourceType: SourceType.unknown,
        message: 'O conteúdo devolvido está vazio ou só contém espaços. '
            'Confira o endereço da lista e tente novamente.',
      );
    }

    // Classificação da fonte antes de analisar: usa apenas os primeiros KB
    // (a lista inteira nunca é duplicada como String antes da inspeção).
    final inspection = M3uParser.inspect(
      head,
      contentType: response.headers['content-type'],
    );

    if (!inspection.isPlaylist) {
      return ImportResult(
        sourceType: inspection.type,
        message: inspection.message,
        bytes: bodyBytes.length,
      );
    }

    if (token.isCancelled) {
      return const ImportResult(message: 'Importação cancelada.');
    }

    // Análise em Isolate separado (não trava a interface com listas grandes):
    // linhas inválidas são apenas ignoradas e o progresso é real.
    final text = M3uParser.decodeText(bodyBytes);
    late final List<Channel> channels;
    try {
      channels = await _parser.parseAsync(
        text,
        timeout: const Duration(minutes: 2),
        cancelToken: token,
        onProgress: onProgress,
      );
    } catch (error) {
      // Falha na análise nunca sobe como exceção bruta: vira mensagem clara
      // (lista corrompida, timeout da análise ou cancelamento).
      return ImportResult(
        sourceType: SourceType.unknown,
        message: error.toString().contains('cancel')
            ? 'Importação cancelada.'
            : 'Não foi possível analisar a lista (o conteúdo pode estar '
                'corrompido). Confira o endereço e tente novamente.',
        bytes: bodyBytes.length,
      );
    }

    if (channels.isEmpty) {
      return const ImportResult(
        sourceType: SourceType.unknown,
        message: 'Nenhum canal válido foi encontrado na lista.',
      );
    }

    return ImportResult(
      channels: channels,
      sourceType: SourceType.playlist,
      bytes: bodyBytes.length,
    );
  }

  /// Carrega e analisa a playlist do arquivo local indicado, com as mesmas
  /// garantias da importação por URL.
  Future<ImportResult> importFromFile(
    String path, {
    void Function(double progress)? onProgress,
  }) async {
    final file = File(path.trim());
    if (!await file.exists()) {
      return const ImportResult(
        sourceType: SourceType.unknown,
        message: 'O arquivo indicado não existe neste aparelho.',
      );
    }
    final headBytes = await file.openRead(0, 8 * 1024).toList();
    final head = M3uParser.decodeText(headBytes.expand((e) => e).toList());
    final inspection = M3uParser.inspect(head);

    if (!inspection.isPlaylist) {
      return ImportResult(
        sourceType: inspection.type,
        message: inspection.message,
      );
    }

    final rawBytes = await file.readAsBytes();
    final text = M3uParser.decodeText(rawBytes);
    onProgress?.call(0.0);
    late final List<Channel> channels;
    try {
      channels = await _parser.parseAsync(
        text,
        timeout: const Duration(minutes: 2),
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    } catch (error) {
      return ImportResult(
        sourceType: SourceType.unknown,
        message: error.toString().contains('cancel')
            ? 'Importação cancelada.'
            : 'Não foi possível analisar o arquivo (o conteúdo pode estar '
                'corrompido). Tente outro arquivo.',
        bytes: rawBytes.length,
      );
    }

    if (channels.isEmpty) {
      return const ImportResult(
        sourceType: SourceType.unknown,
        message: 'Nenhum canal válido foi encontrado no arquivo.',
      );
    }

    return ImportResult(
      channels: channels,
      sourceType: SourceType.playlist,
      bytes: text.length,
    );
  }

  /// Faz a requisição e segue manualmente os redirects 301/302/303/307/308
  /// repassando os headers originais (limite de 5 saltos).
  Future<http.Response> _getFollowingRedirects(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = _client;
    for (var remaining = 5;;) {
      final response = await client.get(uri, headers: headers);
      if (response.statusCode != 301 &&
          response.statusCode != 302 &&
          response.statusCode != 303 &&
          response.statusCode != 307 &&
          response.statusCode != 308) {
        return response;
      }
      final location = response.headers['location'];
      if (location == null || location.isEmpty || remaining == 0) {
        return response;
      }
      final next = uri.resolve(location.trim());
      if (!next.hasScheme ||
          (next.scheme != 'http' && next.scheme != 'https')) {
        return response;
      }
      // 303 converte qualquer método em GET; 301/302 mantêm headers.
      uri = next;
      remaining--;
    }
  }

  /// Início do conteúdo devolvido pelo servidor (até 500 caracteres),
  /// para o log temporário de diagnóstico — identifica respostas HTML/JSON
  /// de erro em vez da lista, sem registrar credenciais ou URL completa.
  static String _preview(List<int> bytes) {
    try {
      final text = M3uParser.decodeText(bytes.take(500).toList()).trim();
      return text.isEmpty ? '(vazio)' : text;
    } catch (_) {
      return '(conteúdo não decodificável)';
    }
  }

  void dispose() {
    _client.close();
  }
}


/// Cliente HTTP manual com redirects controlados pelo PlaylistService.
/// O HttpClient nativo NÃO pode desligar o follow automático de redirects,
/// mas ele não repassa headers customizados nos saltos — exatamente a causa
/// do bug relatado (provedor bloqueia o destino do 301/302 por falta de
/// User-Agent). Aqui as requisições são feitas com openUrl(): nenhum
/// redirect é seguido automaticamente; o PlaylistService gerencia os saltos.
/// Cliente HTTP manual com redirects controlados pelo PlaylistService.
///
/// O HttpClient nativo de dart:io SEMPRE segue redirecionamentos
/// automaticamente e não oferece como injetar headers no salto — exatamente
/// a causa do bug relatado (provedor bloqueia o destino do 301/302 por
/// falta de User-Agent e o app recebia 403/erro silencioso). Para ter
/// controle total, as requisições GET são feitas diretamente via socket
/// (HTTP/1.1 sem auto-follow); os redirects são gerenciados pelo
/// [_getFollowingRedirects], que repassa os mesmos headers em cada passo.
/// Cliente HTTP manual com redirects controlados pelo PlaylistService.
///
/// O HttpClient nativo de dart:io SEMPRE segue redirecionamentos
/// automaticamente e não permite injetar headers no salto — exatamente a
/// causa do bug relatado (provedor bloqueia o destino do 301/302 por falta
/// de User-Agent e o app recebia 403 ou erro silencioso). As requisições
/// GET aqui são feitas diretamente via socket (HTTP/1.1 sem auto-follow):
/// a resposta 301/302 chega inteira, e o PlaylistService gerencia os saltos
/// em [_getFollowingRedirects], repassando os mesmos headers em cada passo.

/// Cliente HTTP manual com redirects controlados pelo PlaylistService.
///
/// O HttpClient nativo de dart:io SEMPRE segue redirecionamentos
/// automaticamente e não permite injetar headers no salto — exatamente a
/// causa do bug relatado (provedor bloqueia o destino do 301/302 por falta
/// de User-Agent e o app recebia 403 ou erro silencioso). As requisições
/// GET aqui são feitas diretamente via socket (HTTP/1.1 sem auto-follow):
/// a resposta 301/302 chega inteira, e o PlaylistService gerencia os saltos
/// em [_getFollowingRedirects], repassando os mesmos headers em cada passo.
class _ManualClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final raw = await _RawHttpGet.perform(
      request.url,
      request.headers,
      const Duration(minutes: 2),
    );
    return http.StreamedResponse(
      Stream.value(raw.bytes),
      raw.statusCode,
      headers: raw.headers,
      contentLength: raw.bytes.length,
      request: request,
    );
  }

  @override
  void close() {}
}

class _RawHttpGet {
  _RawHttpGet(this.statusCode, this.headers, this.bytes);

  final int statusCode;
  final Map<String, String> headers;
  final List<int> bytes;

  /// Executa um GET HTTP/1.1 direto no socket: o servidor de redirect
  /// responde com 301/302 e a leitura para (nada é seguido sozinho).
  static Future<_RawHttpGet> perform(
    Uri uri,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final secure = uri.scheme == 'https';
    final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
    final socket = await Socket.connect(uri.host, port).timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'A conexão com o servidor demorou mais que o esperado.',
      ),
    );
    Stream<List<int>> source = socket;
    if (secure) {
      try {
        source = await SecureSocket.secure(socket, host: uri.host).timeout(
          timeout,
          onTimeout: () {
            socket.destroy();
            throw TimeoutException(
              'A conexão segura demorou mais que o esperado.',
            );
          },
        );
      } catch (error) {
        socket.destroy();
        rethrow;
      }
    }

    final path = uri.hasQuery
        ? '${uri.path.isEmpty ? '/' : uri.path}?${uri.query}'
        : (uri.path.isEmpty ? '/' : uri.path);
    final requestBuffer = StringBuffer();
    requestBuffer.write('GET $path HTTP/1.1\r\n');
    headers.forEach((name, value) {
      requestBuffer.write('$name: $value\r\n');
    });
    requestBuffer.write('Host: ${uri.host}${uri.hasPort ? ':${uri.port}' : ''}\r\n');
    requestBuffer.write('Connection: close\r\n');
    requestBuffer.write('\r\n');
    socket.write(requestBuffer.toString());

    final chunks = <List<int>>[];
    final completer = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = source.listen(
      chunks.add,
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future.timeout(timeout, onTimeout: () {
      subscription.cancel();
      throw TimeoutException('O servidor demorou mais que o esperado.');
    });
    await subscription.cancel();
    await socket.close();
    return _RawHttpGet.parse(chunks);
  }

  static _RawHttpGet parse(List<List<int>> chunks) {
    final rawBytes = <int>[];
    for (final chunk in chunks) {
      rawBytes.addAll(chunk);
    }
    // O servidor pode responder com Transfer-Encoding: chunked (sem
    // Content-Length). Decodificamos os blocos manualmente — em bytes,
    // para não perder dados ao converter String antes da descompressão.
    final headerEnd = _indexOf(rawBytes, _crlfCrlf); // início 0
    final headerBlock = headerEnd >= 0
        ? String.fromCharCodes(rawBytes.sublist(0, headerEnd))
        : String.fromCharCodes(rawBytes);
    final transferEncoding = headerBlock
        .split('\r\n')
        .firstWhere(
          (line) => line.toLowerCase().startsWith('transfer-encoding'),
          orElse: () => '',
        );
    final isChunked = transferEncoding.toLowerCase().contains('chunked');
    List<int> bodyBytes = isChunked
        ? _decodeChunkedBytes(headerEnd >= 0
            ? rawBytes.sublist(headerEnd + 4)
            : rawBytes)
        : (headerEnd >= 0 ? rawBytes.sublist(headerEnd + 4) : <int>[]);

    // Conteúdo compactado (gzip/deflate): muitos provedores IPTV devolvem a
    // lista comprimida mesmo quando o app não pediu — sem decodificar, os
    // bytes crus não parecem playlist e a importação falha silenciosamente.
    final contentEncoding = headerBlock
        .split('\r\n')
        .firstWhere(
          (line) => line.toLowerCase().startsWith('content-encoding'),
          orElse: () => '',
        )
        .split(':')
        .last
        .trim()
        .toLowerCase();
    if (contentEncoding == 'gzip' || contentEncoding == 'x-gzip') {
      try {
        bodyBytes = GZipCodec().decode(bodyBytes);
      } catch (_) {
        // Falha na descompressão: mantém o corpo original e segue.
      }
    } else if (contentEncoding == 'deflate') {
      try {
        bodyBytes = ZLibCodec().decode(bodyBytes);
      } catch (_) {
        try {
          bodyBytes = ZLibCodec(raw: true).decode(bodyBytes);
        } catch (_) {}
      }
    }

    final firstLineEnd = headerBlock.indexOf('\r\n');
    final statusLine = firstLineEnd >= 0
        ? headerBlock.substring(0, firstLineEnd)
        : headerBlock;
    final parts = statusLine.split(' ');
    final status = parts.length >= 2
        ? int.tryParse(parts[1]) ?? 0
        : 0;

    final responseHeaders = <String, String>{};
    if (firstLineEnd >= 0) {
      for (final line
          in headerBlock.substring(firstLineEnd + 2).split('\r\n')) {
        final separator = line.indexOf(':');
        if (separator > 0) {
          responseHeaders[line.substring(0, separator).trim().toLowerCase()] =
              line.substring(separator + 1).trim();
        }
      }
    }
        return _RawHttpGet(status, responseHeaders, bodyBytes);
  }

  /// Marca do fim dos cabeçalhos HTTP (CRLF duplo) em bytes.
  static final List<int> _crlfCrlf = utf8.encode('\r\n\r\n');

  /// Busca uma sequência de bytes dentro de outra (para achar o CRLF duplo
  /// em bytes brutos, sem converter para String antes).
  static int _indexOf(List<int> haystack, List<int> needle, {int start = 0}) {
    if (needle.isEmpty) return start;
    for (var i = start; i <= haystack.length - needle.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  /// Remove a codificação chunked de HTTP/1.1 (tamanho em hexa + CRLF +
  /// dados, encerrado por '0\r\n'). Opera em bytes brutos para não perder
  /// dados de conteúdo binário (gzip, por exemplo) ao converter para String.
  static List<int> _decodeChunkedBytes(List<int> raw) {
    final buffer = <int>[];
    var cursor = 0;
    while (cursor < raw.length) {
      final lineEnd = _indexOf(raw, _crlf, start: cursor);
      if (lineEnd < 0) break;
      final sizeText =
          String.fromCharCodes(raw.sublist(cursor, lineEnd))
              .trim()
              .split(';')
              .first
              .trim();
      final size = int.tryParse(sizeText, radix: 16);
      if (size == null || size == 0) break;
      cursor = lineEnd + 2;
      if (cursor + size > raw.length) break;
      buffer.addAll(raw.sublist(cursor, cursor + size));
      cursor += size + 2;
    }
    return buffer;
  }

  /// CRLF em bytes.
  static final List<int> _crlf = utf8.encode('\r\n');

}
