// Reproduz o fluxo de importação do StreamBox fora do Flutter (Dart standalone)
// para capturar a exceção exata que fecha o app. ESPLELHA o código real de
// lib/services (playlist_service, m3u_parser, channels_store) — qualquer bug
// de memória/performance lá aparece aqui igual.
//
// Uso: dart run tool/crash_reproducer.dart --url <URL> [--restore-only]
// Saída sanitizada (sem credenciais) em tool/crash_report.txt

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

// Loga no stdout (o analisador não recomenda print em código de produção).
void _log(Object? message) {
  stdout.writeln(message);
}

// ---------------------------------------------------------------------------
// Espelho de models/channel.dart (sem flutter)
// ---------------------------------------------------------------------------
class Channel {
  const Channel({
    required this.name,
    required this.url,
    this.logoUrl,
    this.group,
    this.tvgId,
    this.tvgName,
    this.tvgLanguage,
    this.tvgCountry,
    this.tvgUrl,
    this.headers = const {},
  });

  final String name;
  final String url;
  final String? logoUrl;
  final String? group;
  final String? tvgId;
  final String? tvgName;
  final String? tvgLanguage;
  final String? tvgCountry;
  final String? tvgUrl;
  final Map<String, String> headers;

  String get id => (tvgId != null && tvgId!.isNotEmpty) ? tvgId! : url;

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        name: json['name'] as String,
        url: json['url'] as String,
        logoUrl: json['logoUrl'] as String?,
        group: json['group'] as String?,
        tvgId: json['tvgId'] as String?,
        tvgName: json['tvgName'] as String?,
        tvgLanguage: json['tvgLanguage'] as String?,
        tvgCountry: json['tvgCountry'] as String?,
        tvgUrl: json['tvgUrl'] as String?,
        headers: (json['headers'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ) ??
            const {},
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'logoUrl': logoUrl,
        'group': group,
        'tvgId': tvgId,
        'tvgName': tvgName,
        'tvgLanguage': tvgLanguage,
        'tvgCountry': tvgCountry,
        'tvgUrl': tvgUrl,
        if (headers.isNotEmpty) 'headers': headers,
      };
}

// ---------------------------------------------------------------------------
// Espelho de services/m3u_parser.dart (cópia fiel do código do app)
// ---------------------------------------------------------------------------
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];
  bool get isCancelled => _cancelled;
  void addListener(void Function() fn) => _listeners.add(fn);
  void cancel() {
    _cancelled = true;
    for (final fn in _listeners) {
      fn();
    }
  }
}

class M3uParser {
  const M3uParser();

  Future<List<Channel>> parseAsync(
    String source, {
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancelToken,
    void Function(double progress)? onProgress,
    void Function(int skippedLines)? onSkippedLines,
  }) async {
    onProgress?.call(0.0);
    final token = cancelToken ?? CancelToken();
    final parseFuture = Isolate.run(
      () => _parseIsolated(source),
      debugName: 'm3u_parser',
    );
    final resultFuture = parseFuture.then((raw) {
      onProgress?.call(1.0);
      onSkippedLines?.call(raw['skipped'] as int);
      final channels = (raw['channels'] as List)
          .map((dynamic item) => Channel.fromJson(item as Map<String, dynamic>))
          .toList();
      return channels;
    });
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
      if (pendingInfo != null &&
          !line.startsWith('#') &&
          (line.startsWith('http://') ||
              line.startsWith('https://') ||
              line.startsWith('rtmp://') ||
              line.startsWith('rtsp://') ||
              line.startsWith('mms://'))) {
        final parsed = _parseExtInf(pendingInfo);
        if (parsed == null) {
          pendingInfo = null;
          skipped++;
          continue;
        }
        channels.add({
          ...parsed,
          'url': line,
          if (pendingHeaders.isNotEmpty) 'headers': pendingHeaders,
        });
        pendingInfo = null;
        pendingHeaders = <String, String>{};
        continue;
      }
      // Linha inválida: conta e ignora, sem fechar o app.
      if (line.startsWith('#')) continue;
      skipped++;
    }
    return {'channels': channels, 'skipped': skipped};
  }

  static Map<String, dynamic>? _parseExtInf(String line) {
    // #EXTINF:<duração> <atributos>,<nome>
    final nameStart = line.indexOf(',');
    final name = nameStart >= 0
        ? line.substring(nameStart + 1).trim()
        : 'Canal sem nome';
    final attrsPart = nameStart >= 0 ? line.substring(0, nameStart) : line;

    String? tvgId;
    String? tvgName;
    String? group;
    String? logoUrl;
    String? tvgLanguage;
    String? tvgCountry;
    String? tvgUrl;

    final attributePattern = RegExp(
      r'([a-zA-Z0-9_-]+)="([^"]*)"',
      caseSensitive: false,
    );
    for (final match in attributePattern.allMatches(attrsPart)) {
      final key = match.group(1)?.toLowerCase();
      final value = match.group(2);
      if (key == 'tvg-id') tvgId = value;
      if (key == 'tvg-name') tvgName = value;
      if (key == 'tvg-language') tvgLanguage = value;
      if (key == 'tvg-country') tvgCountry = value;
      if (key == 'group-title') group = value;
      if (key == 'tvg-logo') logoUrl = value;
      if (key == 'url-tvg' || key == 'x-tvg-url') tvgUrl = value;
    }

    return {
      'name': name,
      'tvgId': tvgId,
      'tvgName': tvgName,
      'tvgLanguage': tvgLanguage,
      'tvgCountry': tvgCountry,
      'group': group,
      'logoUrl': logoUrl,
      'tvgUrl': tvgUrl,
    };
  }
}

// ---------------------------------------------------------------------------
// Espelho de services/channels_store.dart (cópia fiel — inclui loadAll com
// readAsString, que é a hipótese principal de OOM na restauração)
// ---------------------------------------------------------------------------
class ChannelsStore {
  static const String _fileName = '/tmp/streambox_channels.ndjson';

  Future<void> clear() async {
    final file = File(_fileName);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  Future<int> count() async {
    final file = File(_fileName);
    if (!await file.exists()) return 0;
    final stream = file.openRead().transform(utf8.decoder);
    return await stream
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty)
        .length;
  }

  Future<List<Channel>> loadAll({int decodeBatchSize = 2000}) async {
    final file = File(_fileName);
    if (!await file.exists()) return const [];
    final raw = await file.readAsString();
    if (raw.isEmpty) return const [];
    return await compute(_decode, _DecodeArgs(raw, decodeBatchSize));
  }

  Future<void> append(List<Channel> channels, {int writeBatchSize = 1000}) async {
    if (channels.isEmpty) return;
    final file = File(_fileName);
    final sink = file.openWrite(mode: FileMode.append);
    final buffer = StringBuffer();
    int buffered = 0;
    for (final channel in channels) {
      buffer.writeln(jsonEncode(channel.toJson()));
      buffered++;
      if (buffered >= writeBatchSize) {
        sink.write(buffer.toString());
        buffer.clear();
        buffered = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (buffer.isNotEmpty) sink.write(buffer.toString());
    await sink.flush();
    await sink.close();
  }

  Future<int> saveAll(List<Channel> channels, {int writeBatchSize = 1000}) async {
    await clear();
    await append(channels, writeBatchSize: writeBatchSize);
    return channels.length;
  }

  Future<double> fileSizeMb() async {
    final file = File(_fileName);
    if (!await file.exists()) return 0;
    final stat = await file.stat();
    return stat.size / (1024 * 1024);
  }
}

class _DecodeArgs {
  const _DecodeArgs(this.raw, this.batchSize);
  final String raw;
  final int batchSize;
}

List<Channel> _decode(_DecodeArgs args) {
  final lines = args.raw.split('\n');
  final channels = <Channel>[];
  List<String> batchRaw = [];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    batchRaw.add(trimmed);
    if (batchRaw.length >= args.batchSize) {
      channels.addAll(_decodeBatch(batchRaw));
      batchRaw = [];
    }
  }
  if (batchRaw.isNotEmpty) {
    channels.addAll(_decodeBatch(batchRaw));
  }
  return channels;
}

List<Channel> _decodeBatch(List<String> raws) {
  final channels = <Channel>[];
  for (final raw in raws) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        channels.add(Channel.fromJson(decoded));
      }
    } catch (_) {}
  }
  return channels;
}

Future<T> compute<T, R>(T Function(R) function, R argument) async =>
    Isolate.run(() => function(argument));

// ---------------------------------------------------------------------------
// Espelho de services/playlist_service.dart (cópia fiel: response.body String)
// ---------------------------------------------------------------------------
class PlaylistService {
  PlaylistService({this.timeout = const Duration(seconds: 45)});

  final Duration timeout;
  final M3uParser _parser = const M3uParser();
  CancelToken? cancelToken;

  Future<List<Channel>> loadFromUrl(
    String rawUrl, {
    void Function(double progress)? onProgress,
  }) async {
    cancelToken?.cancel();
    cancelToken = CancelToken();

    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Informe uma URL http:// ou https:// válida.');
    }

    final HttpClient client = HttpClient();
    client.connectionTimeout = timeout;
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('A playlist respondeu HTTP ${response.statusCode}.');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    // Aqui está o espelho do código do app: a lista inteira vira uma String.
    final body = utf8.decode(bytes, allowMalformed: true);

    if (body.trim().isEmpty) {
      throw const FormatException('A lista retornou vazia do servidor.');
    }

    final channels = await _parser.parseAsync(
      body,
      timeout: const Duration(minutes: 2),
      cancelToken: cancelToken,
      onProgress: onProgress,
    );

    if (channels.isEmpty) {
      throw const FormatException('Nenhum canal válido foi encontrado na playlist.');
    }
    client.close();
    return channels;
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------
String sanitize(String s) {
  return s
      .replaceAllMapped(
        RegExp('https?://[^\\s"\'<>]+'),
        (m) => '[URL-OCULTA]',
      )
      .replaceAllMapped(
        RegExp(r'(pass(word)?|senha|token|authorization|key)\s*[=:]\s*\S+',
            caseSensitive: false),
        (m) => '[CREDENCIAL-OCULTA]',
      );
}

Future<void> main(List<String> args) async {
  var url = '';
  var restoreOnly = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--url' && i + 1 < args.length) url = args[++i];
    if (args[i] == '--restore-only') restoreOnly = true;
  }

  final report = StringBuffer();
  report.writeln('=== RELATÓRIO DE REPRODUÇÃO DE CRASH (sanitizado) ===');
  report.writeln('Data: ${DateTime.now().toIso8601String()}');
  report.writeln('RSS inicial: ${(ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1)} MB');

  if (restoreOnly) {
    final sw = Stopwatch()..start();
    try {
      final store = ChannelsStore();
      final count = await store.count();
      report.writeln('Canais no arquivo: $count');
      final channels = await store.loadAll();
      report.writeln('Canais restaurados: ${channels.length} em ${sw.elapsed}');
      report.writeln('RSS final: ${(ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1)} MB');
      report.writeln('FASE: restauração concluída sem crash.');
    } catch (e, st) {
      report.writeln('FASE: restauração');
      report.writeln('EXCEÇÃO: ${e.runtimeType}: $e');
      report.writeln('STACK (sanitizado):\n${sanitize('$st')}');
    }
    File('tool/crash_report.txt').writeAsStringSync(report.toString());
    _log(report);
    exit(0);
  }

  if (url.isEmpty) {
    _log('Uso: dart run tool/crash_reproducer.dart --url <URL> [--restore-only]');
    exit(64);
  }

  final service = PlaylistService();
  final sw = Stopwatch()..start();
  try {
    report.writeln('FASE: download+análise');
    report.writeln('Fonte: [URL-OCULTA]');
    final channels = await service.loadFromUrl(url, onProgress: (p) {
      report.writeln('Progresso: ${(p * 100).round()}%');
    });
    report.writeln('Analisados: ${channels.length} em ${sw.elapsed}');
    report.writeln('RSS após análise: ${(ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1)} MB');

    final store = ChannelsStore();
    report.writeln('FASE: gravação em lotes');
    final saved = await store.saveAll(channels);
    report.writeln('Gravados: $saved');
    report.writeln('Tamanho do arquivo: ${(await store.fileSizeMb()).toStringAsFixed(2)} MB');
    report.writeln('FASE: restauração (loadAll)');
    sw.reset();
    final restored = await store.loadAll();
    report.writeln('Restaurados: ${restored.length} em ${sw.elapsed}');
    report.writeln('RSS final: ${(ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1)} MB');
    report.writeln('FASE: importação completa sem crash.');
  } on TimeoutException catch (e, st) {
    report.writeln('FASE: download');
    report.writeln('EXCEÇÃO: ${e.runtimeType}: $e');
    report.writeln('STACK (sanitizado):\n${sanitize('$st')}');
  } on FormatException catch (e, st) {
    report.writeln('FASE: análise');
    report.writeln('EXCEÇÃO: ${e.runtimeType}: $e');
    report.writeln('STACK (sanitizado):\n${sanitize('$st')}');
  } catch (e, st) {
    report.writeln('FASE: desconhecida');
    report.writeln('EXCEÇÃO: ${e.runtimeType}: $e');
    report.writeln('STACK (sanitizado):\n${sanitize('$st')}');
  } finally {
    service.cancelToken?.cancel();
  }

  File('tool/crash_report.txt').writeAsStringSync(report.toString());
  _log(report);
  exit(0);
}
