import 'dart:async';
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
  }) : _client = client ?? http.Client();

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

    final List<int> bodyBytes;
    final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: const {
          // gzip é aceito e descompactado automaticamente pelo pacote http.
          'Accept-Encoding': 'gzip',
          'User-Agent': 'StreamBox-IPTV/0.7',
        },
      ).timeout(timeout);
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

  void dispose() {
    cancelToken?.cancel();
    _client.close();
  }
}
