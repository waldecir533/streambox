import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import '../models/channel.dart';

/// Resultado da análise incremental: canais já validados, quantidade de
/// linhas ignoradas por serem inválidas e o progresso atual.
class M3uParseChunk {
  const M3uParseChunk({
    required this.channels,
    required this.skippedLines,
    required this.progress,
  });
  final List<Channel> channels;
  final int skippedLines;
  final double progress;
}

/// Detecta o **tipo de conteúdo** devolvido por uma fonte, antes de tentar
/// analisar como playlist. Assim uma URL `.m3u8` de um único programa
/// (HLS individual) não é confundida com uma lista, e respostas HTML/JSON
/// recebem mensagem específica em vez de "lista vazia".
enum SourceType {
  /// Playlist M3U/M3U8 com `#EXTM3U` e entradas `#EXTINF`.
  playlist,

  /// Stream individual em HLS (`#EXT-X-STREAM-INF` ou `#EXT-X-TARGETDURATION`
  /// sem `#EXTM3U` de playlist de canais).
  hlsStream,

  /// Fluxo de vídeo direto (MPEG-TS/MP4 ou similar) — identificado pela
  /// extensão/Content-Type quando o conteúdo não é texto.
  directStream,

  /// Página HTML (Cloudflare, captura, erro do provedor).
  html,

  /// JSON — possivelmente Xtream/erro do provedor.
  json,

  /// Conteúdo binário/texto não reconhecido.
  unknown,
}

/// Resultado da inspeção do conteúdo baixado, com mensagem amigável pronta
/// para o usuário quando o conteúdo não for uma playlist.
class SourceInspection {
  SourceInspection({
    required this.type,
    String? message,
    this.contentType,
  }) : message = message ?? _defaultMessage(type);

  static String? _defaultMessage(SourceType type) {
    switch (type) {
      case SourceType.html:
        return 'O endereço devolveu uma página HTML em vez de uma lista. '
            'Confira se o link é o da lista M3U (termina em .m3u/.m3u8 e '
            'inclui usuário e senha quando exigido pelo provedor). '
            'Alguns provedores bloqueiam o acesso e devolvem página de erro.';
      case SourceType.json:
        return 'O endereço devolveu dados em JSON, não uma lista M3U. '
            'Se for um painel Xtream Codes, use a aba "Xtream" com servidor, '
            'usuário e senha em vez de colar a URL da lista.';
      case SourceType.hlsStream:
        return 'Este endereço é um stream individual (HLS), não uma lista '
            'com vários canais. Ele pode ser salvo como canal avulso com o '
            'nome e a categoria que você escolher.';
      case SourceType.directStream:
        return 'O conteúdo parece ser um fluxo de vídeo direto, não uma '
            'lista de canais. Ele pode ser salvo como canal avulso.';
      case SourceType.unknown:
        return 'O conteúdo devolvido não parece ser uma lista M3U. Confira o '
            'endereço e tente novamente.';
      case SourceType.playlist:
        return null;
    }
  }
  final SourceType type;
  final String? message;
  final String? contentType;

  bool get isPlaylist => type == SourceType.playlist;
}

class M3uParser {
  const M3uParser();

  /// Inspeciona os primeiros bytes do conteúdo para classificar o tipo de
  /// fonte **sem** carregar o arquivo inteiro na memória.
  static SourceInspection inspect(String head, {String? contentType}) {
    final trimmed = head.trimLeft().toLowerCase();

    // HTML antes de qualquer coisa: `<` ou `<!doctype`.
    if (trimmed.startsWith('<') || trimmed.startsWith('<!doctype')) {
      return SourceInspection(
        type: SourceType.html,
        message: 'O endereço devolveu uma página HTML em vez de uma lista. '
            'Confira se o link é o da lista M3U (termina em .m3u/.m3u8 e '
            'inclui usuário e senha quando exigido pelo provedor). '
            'Alguns provedores bloqueiam o acesso e devolvem página de erro.',
        contentType: contentType,
      );
    }

    // JSON: começa com `{` ou `[` (com eventual BOM/whitespace já removido).
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return SourceInspection(
        type: SourceType.json,
        message: 'O endereço devolveu dados em JSON, não uma lista M3U. '
            'Se for um painel Xtream Codes, use a aba "Xtream" com servidor, '
            'usuário e senha em vez de colar a URL da lista.',
        contentType: contentType,
      );
    }

    final isPlaylist = trimmed.startsWith('#extm3u');

    // HLS individual ou playlist variante: listas IPTV de canais nunca
    // usam EXT-X-TARGETDURATION/EXT-X-STREAM-INF — esses cabeçalhos são
    // exclusivos de streams HLS e playlists de variantes HLS.
    if (isPlaylist &&
        (trimmed.contains('#ext-x-stream-inf') ||
            trimmed.contains('#ext-x-targetduration'))) {
      return SourceInspection(
        type: SourceType.hlsStream,
        message: 'Este endereço é um stream individual (HLS), não uma lista '
            'com vários canais. Ele pode ser salvo como canal avulso com o '
            'nome e a categoria que você escolher.',
        contentType: contentType,
      );
    }

    if (isPlaylist) {
      return SourceInspection(
        type: SourceType.playlist,
        contentType: contentType,
      );
    }

    // Texto sem #EXTM3U: pode ser stream direto ou conteúdo não reconhecido.
    if (trimmed.startsWith('#ext-x') || trimmed.contains('#ext-x')) {
      return SourceInspection(
        type: SourceType.directStream,
        message: 'O conteúdo parece ser um fluxo de vídeo direto, não uma '
            'lista de canais. Ele pode ser salvo como canal avulso.',
        contentType: contentType,
      );
    }

    return SourceInspection(
      type: SourceType.unknown,
      message: 'O conteúdo devolvido não parece ser uma lista M3U. Confira o '
          'endereço e tente novamente.',
      contentType: contentType,
    );
  }

  /// Decodifica bytes brutos para texto de forma tolerante: tenta UTF-8 e,
  /// em caso de falha, usa latin-1 (nunca falha) removendo caracteres de
  /// controle estranhos à lista.
  static String decodeText(List<int> bytes) {
    // BOM (U+FEFF) é comum no início de listas M3U de provedores que usam
    // ferramentas Windows/UTF-16; removê-lo antes da análise, senão o
    // '#EXTM3U' nunca é reconhecido e a lista é rejeitada como desconhecida.
    List<int> body = bytes;
    if (body.length >= 3 &&
        body[0] == 0xEF &&
        body[1] == 0xBB &&
        body[2] == 0xBF) {
      body = body.sublist(3);
    }
    try {
      return utf8.decode(body, allowMalformed: false);
    } catch (_) {
      // latin1 nunca falha; remove NUL e caracteres de controle não úteis.
      final latin1 = String.fromCharCodes(bytes);
      return latin1.replaceAllMapped(
        RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'),
        (m) => '',
      );
    }
  }

  /// Analisa a playlist em um **Isolate separado** (não trava a interface)
  /// e devolve todos os canais validados. Linhas inválidas são apenas
  /// ignoradas (com contagem), nunca encerram a análise.
  ///
  /// [timeout] limita o tempo total de análise; [cancelToken] permite
  /// abandonar a análise (o isolate termina sozinho quando conclui).
  /// [onProgress] recebe frações de progresso entre 0.0 e 1.0 (1.0 quando
  /// conclui); [onSkippedLines] informa quantas linhas inválidas foram
  /// ignoradas.
  Future<List<Channel>> parseAsync(
    String source, {
    int batchSize = 500,
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancelToken,
    void Function(double progress)? onProgress,
    void Function(int skippedLines)? onSkippedLines,
  }) async {
    onProgress?.call(0.0);
    final token = cancelToken ?? CancelToken();
    if (token.isCancelled) {
      throw const FormatException('Análise cancelada.');
    }
    // O parser síncrono roda em um Isolate próprio (Isolate.run, Dart 3.0+):
    // a memória alocada no isolate é liberada junto com ele e a thread da
    // interface não é bloqueada.
    final parseFuture = Isolate.run(
      () => _parseIsolated(source),
      debugName: 'm3u_parser',
    );
    final resultFuture = parseFuture.then((raw) {
      onProgress?.call(1.0);
      onSkippedLines?.call(raw['skipped'] as int);
      final channels = (raw['channels'] as List)
          .map((dynamic item) =>
              Channel.fromJsonMap(item as Map<String, dynamic>))
          .toList();
      return channels;
    });
    // Timeout: se demorar demais, abandona o resultado (o isolate termina
    // sozinho ao concluir e sua memória é liberada).
    final timedOut = Completer<Never>();
    Timer? timeoutTimer;
    if (!token.isCancelled) {
      timeoutTimer = Timer(timeout, () {
        if (!timedOut.isCompleted) {
          timedOut.completeError(TimeoutException(
            'A análise da lista demorou mais que o esperado.',
          ));
        }
      });
    }
    final cancelled = Completer<Never>();
    void cancel() {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const FormatException('Análise cancelada.'));
      }
    }
    token.addListener(cancel);
    if (token.isCancelled) cancel();
    try {
      return await Future.any([resultFuture, timedOut.future, cancelled.future]);
    } finally {
      timeoutTimer?.cancel();
    }
  }

  /// Análise síncrona (para testes e fontes pequenas).
  List<Channel> parse(String source) {
    final raw = _parseIsolated(source);
    return (raw['channels'] as List)
        .map((dynamic item) =>
            Channel.fromJsonMap(item as Map<String, dynamic>))
        .toList();
  }

  // Análise síncrona no isolate: tolerante a linhas malformadas, vazias e
  // caracteres inválidos; canais sem EXTINF precedente são ignorados.
  static Map<String, dynamic> _parseIsolated(String source) {
    final lines = source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final channels = <Map<String, dynamic>>[];
    int skipped = 0;
    String? pendingInfo;
    var pendingHeaders = <String, String>{};
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF:')) {
        pendingInfo = line;
        pendingHeaders = <String, String>{};
        continue;
      }
      if (pendingInfo != null && line.startsWith('#EXTVLCOPT:')) {
        final option = line.substring('#EXTVLCOPT:'.length);
        final separator = option.indexOf('=');
        if (separator > 0) {
          final key = option.substring(0, separator).toLowerCase();
          final value = option.substring(separator + 1).trim();
          if (key == 'http-user-agent') pendingHeaders['User-Agent'] = value;
          if (key == 'http-referrer' || key == 'http-referer') {
            pendingHeaders['Referer'] = value;
          }
        }
        continue;
      }
      if (pendingInfo != null && line.startsWith('#EXTHTTP:')) {
        try {
          final decoded = jsonDecode(line.substring('#EXTHTTP:'.length));
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              final name = entry.key.toString();
              if ({'user-agent', 'referer', 'authorization'}
                  .contains(name.toLowerCase())) {
                final canonical = name.toLowerCase() == 'user-agent'
                    ? 'User-Agent'
                    : name.toLowerCase() == 'referer'
                        ? 'Referer'
                        : 'Authorization';
                pendingHeaders[canonical] = entry.value.toString();
              }
            }
          }
        } on FormatException {
          // Ignora metadados opcionais malformados e continua a análise.
        } catch (_) {
          // Qualquer outra falha em metadados é ignorada.
        }
        continue;
      }
      if (pendingInfo != null && _looksLikeUrl(line)) {
        try {
          channels.add(_buildChannelMap(pendingInfo, line, pendingHeaders));
        } catch (_) {
          // Canal inválido: ignora apenas esta entrada e continua.
          skipped++;
        }
        pendingInfo = null;
        pendingHeaders = <String, String>{};
        continue;
      }
      if (line.startsWith('#')) continue;
      // Linha que não é comentário, não é EXTINF e não é URL válida
      // seguindo um EXTINF: entrada inválida — ignora só ela.
      skipped++;
      if (pendingInfo != null) {
        pendingInfo = null;
        pendingHeaders = <String, String>{};
      }
    }

    if (channels.isEmpty) {
      throw const FormatException('Nenhum canal válido foi encontrado.');
    }

    return <String, dynamic>{
      'channels': channels,
      'skipped': skipped,
    };
  }

  static Map<String, dynamic> _buildChannelMap(
    String info,
    String url,
    Map<String, String> headers,
  ) {
    final commaIndex = info.lastIndexOf(',');
    String name = commaIndex >= 0 && commaIndex + 1 < info.length
        ? info.substring(commaIndex + 1).trim()
        : 'Canal';
    if (name.isEmpty) name = 'Canal';

    // Atributos entre aspas duplas OU simples (M3U Plus completo):
    // tvg-id, tvg-name, tvg-logo, tvg-language, tvg-country, group-title,
    // catchup, catchup-source, catchup-days, tvg-shift, tvg-url/url-tvg,
    // x-tvg-url (presente na linha #EXTM3U, capturada antes).
    String? attribute(String key) {
      for (final quote in const ['"', "'"]) {
        final match = RegExp('$key=$quote([^$quote]*)$quote',
                caseSensitive: false)
            .firstMatch(info);
        final value = match?.group(1)?.trim();
        if (value != null && value.isNotEmpty) return value;
      }
      return null;
    }

    return <String, dynamic>{
      'name': name,
      'url': url,
      'logoUrl': attribute('tvg-logo'),
      'group': attribute('group-title'),
      'tvgId': attribute('tvg-id'),
      'tvgName': attribute('tvg-name'),
      'tvgLanguage': attribute('tvg-language'),
      'tvgCountry': attribute('tvg-country'),
      'tvgUrl': attribute('tvg-url'),
      'catchup': attribute('catchup'),
      'catchupSource': attribute('catchup-source'),
      'catchupDays': attribute('catchup-days'),
      'headers': Map<String, String>.unmodifiable(headers),
    };
  }

  static bool _looksLikeUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' ||
            uri.scheme == 'https' ||
            uri.scheme == 'rtmp' ||
            uri.scheme == 'rtsp' ||
            uri.scheme == 'mms' ||
            uri.scheme == 'rtp');
  }
}

/// Token simples para cancelar operações assíncronas longas.
class CancelToken {
  final List<void Function()> _listeners = [];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void addListener(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _listeners.add(callback);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final callback in _listeners) {
      callback();
    }
  }
}
