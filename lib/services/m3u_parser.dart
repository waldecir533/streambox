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

class M3uParser {
  const M3uParser();

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
          .map((dynamic item) => Channel.fromJsonMap(item as Map<String, dynamic>))
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
          // Qualquer outro erro de leitura de cabeçalhos é ignorado.
        }
        continue;
      }

      if (line.startsWith('#')) {
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
    final name = commaIndex >= 0 && commaIndex + 1 < info.length
        ? info.substring(commaIndex + 1).trim()
        : 'Canal';

    String? attribute(String key) {
      final match = RegExp('$key="([^"]*)"', caseSensitive: false)
          .firstMatch(info);
      final value = match?.group(1)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    return <String, dynamic>{
      'name': name.isEmpty ? 'Canal' : name,
      'url': url,
      'logoUrl': attribute('tvg-logo'),
      'group': attribute('group-title'),
      'tvgId': attribute('tvg-id'),
      'headers': Map<String, String>.unmodifiable(headers),
    };
  }

  static bool _looksLikeUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https');
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
