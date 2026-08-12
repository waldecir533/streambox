import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import '../models/channel.dart';

class M3uParser {
  const M3uParser();

  /// Analisa a playlist de forma assíncrona em um **Isolate** separado,
  /// liberando a thread principal para manter a interface fluida mesmo com
  /// listas gigantes (centenas de milhares de linhas).
  ///
  /// [timeout] limita o tempo total de análise; [cancelToken] permite
  /// cancelar a análise (por exemplo, quando a tela é fechada).
  /// [onProgress] recebe frações de progresso entre 0.0 e 1.0 quando
  /// disponível.
  Future<List<Channel>> parseAsync(
    String source, {
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancelToken,
    void Function(double progress)? onProgress,
  }) async {
    final token = cancelToken ?? CancelToken();
    final completer = Completer<List<Channel>>();
    onProgress?.call(0.0);

    final receivePort = ReceivePort();
    late Timer timeoutTimer;

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        receivePort.close();
        completer.completeError(TimeoutException(
          'A análise da lista demorou mais que o esperado.',
        ));
      }
    });

    token.addListener(() {
      if (!completer.isCompleted) {
        receivePort.close();
        timeoutTimer.cancel();
        completer.completeError(const FormatException('Análise cancelada.'));
      }
    });

    // O Isolate é criado em modo "spawn", com capacidade limitada de
    // alocação e tempo de CPU, para não prejudicar o restante do aparelho.
    Isolate.spawn<SendPort>(
      _parseEntryPoint,
      receivePort.sendPort,
      debugName: 'm3u_parser',
      errorsAreFatal: false,
    ).then((isolate) {
      SendPort? inputPort;
      receivePort.listen((message) {
        if (message is SendPort) {
          inputPort = message;
          inputPort!.send(source);
          return;
        }
        if (message is List<Map<String, dynamic>>) {
          timeoutTimer.cancel();
          receivePort.close();
          if (!completer.isCompleted) {
            onProgress?.call(1.0);
            completer.complete(
              message.map(Channel.fromJsonMap).toList(),
            );
          }
        } else if (message is String) {
          timeoutTimer.cancel();
          receivePort.close();
          if (!completer.isCompleted) {
            completer.completeError(
              FormatException('Não foi possível analisar a lista: $message'),
            );
          }
        }
      }, onError: (_) {
        // Erros de escuta são tratados pelo timeout/cancelamento.
      });
    }, onError: (error) {
      timeoutTimer.cancel();
      receivePort.close();
      if (!completer.isCompleted) {
        completer.completeError(
          const FormatException('Não foi possível iniciar a análise da lista.'),
        );
      }
    });

    return completer.future;
  }

  /// Análise síncrona (para testes e fontes já pequenas).
  List<Channel> parse(String source) {
    final rawChannels = _parseRaw(source);
    return rawChannels.map(Channel.fromJsonMap).toList();
  }

  static List<Map<String, dynamic>> _parseRaw(String source) {
    final lines = source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      throw const FormatException('O arquivo está vazio.');
    }

    final channels = <Map<String, dynamic>>[];
    String? pendingInfo;
    final pendingHeaders = <String, String>{};

    for (final line in lines) {
      if (line.startsWith('#EXTINF:')) {
        pendingInfo = line;
        pendingHeaders.clear();
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
        channels.add(_buildChannelMap(pendingInfo, line, pendingHeaders));
        pendingInfo = null;
        pendingHeaders.clear();
      }
    }

    if (channels.isEmpty) {
      throw const FormatException('Nenhum canal válido foi encontrado.');
    }

    return channels;
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

  /// Função de entrada do Isolate — o Dart cria automaticamente um ReceivePort
  /// interno e passa o SendPort correspondente como argumento; o isolate
  /// escuta esse SendPort para receber o texto da playlist.
  static void _parseEntryPoint(SendPort replyPort) async {
    final inputPort = ReceivePort();
    replyPort.send(inputPort.sendPort);
    await for (final message in inputPort) {
      if (message is! String) continue;
      try {
        replyPort.send(await Isolate.run(() => _parseRaw(message)));
      } catch (error) {
        replyPort.send(error.toString());
      }
      inputPort.close();
      return;
    }
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
