import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Gravações de canais ao vivo (DVR).
///
/// Os bytes do stream chegam do proxy local (StreamProxyService) conforme
/// são baixados do provedor: escrevemos direto no disco, sem manter o
/// conteúdo na memória.
class RecordingService {
  static const String subFolder = 'streambox_recordings';

  /// Instância única do serviço (DVR é um recurso compartilhado do app).
  static final RecordingService instance = RecordingService._();
  RecordingService._();

  final StreamController<Recording> _changes = StreamController.broadcast();
  final Map<String, Recording> _active = {};

  /// Fluxo de mudanças das gravações (nova, concluída, excluída).
  Stream<Recording> get onRecordingsChanged => _changes.stream;

  /// Diretório onde as gravações são salvas (scoped storage Android 10+):
  /// documentos do app, sem nenhuma permissão de armazenamento.
  Future<Directory> get _dir async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory('${documents.path}/$subFolder');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  void _emit(Recording recording) {
    if (!_changes.isClosed) _changes.add(recording);
  }

  /// Inicia a gravação de um canal. Retorna a gravação em andamento.
  Future<Recording> start(String channelName, String channelUrl) async {
    final directory = await _dir;
    final stamp = DateTime.now().toIso8601String().substring(0, 19);
    final file = File('${directory.path}/${Recording._safe(channelName)}_$stamp.ts');
    final recording = Recording.inProgress(channelName, channelUrl, file);
    _active[recording.id] = recording;
    unawaited(recording.open());
    unawaited(recording.finished.then((_) {
      _active.remove(recording.id);
      _emit(recording);
    }));
    return recording;
  }

  /// Gravação em andamento pelo identificador.
  Recording? active(String id) => _active[id];


  /// Lista as gravações salvas no disco (as em andamento primeiro).
  Future<List<Recording>> list() async {
    final result = <Recording>[..._active.values];
    final activeIds = _active.keys.toSet();
    final directory = await _dir;
    await for (final entity in directory.list()) {
      if (entity is File &&
          entity.path.toLowerCase().endsWith('.ts') &&
          // Gravações em andamento também já têm arquivo no disco.
          !activeIds.contains(entity.path)) {
        result.add(Recording.fromFile(entity));
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// Limite de espaço opcional: apaga as gravações mais antigas até o
  /// total ficar abaixo de `maxBytes` (0 = sem limite).
  Future<void> enforceStorageLimit(int maxBytes) async {
    if (maxBytes <= 0) return;
    final recordings = await list().then((list) =>
        list.where((r) => !r.isRunning).toList());
    int total = 0;
    for (final recording in recordings) {
      total += await recording.fileSize;
    }
    for (final recording in recordings) {
      if (total <= maxBytes) return;
      total -= await recording.fileSize;
      await recording.delete();
    }
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}

/// Uma gravação de canal ao vivo em andamento ou já salva.
class Recording {
  Recording.inProgress(this.channelName, this.channelUrl, this.file)
      : createdAt = DateTime.now(),
        _state = _RecordingState.writing;

  Recording.fromFile(this.file)
      : createdAt = _parseStamp(file.path),
        channelName = _channelNameFrom(file.path),
        channelUrl = '',
        _state = _RecordingState.saved;

  final String channelName;
  final String channelUrl;
  final File file;
  final DateTime createdAt;
  _RecordingState _state;

  /// Identificador único da gravação (para acompanhar em andamento).
  String get id => file.path;

  bool get isRunning => _state == _RecordingState.writing;
  bool get isSaved => _state == _RecordingState.saved;

  RandomAccessFile? _handle;
  int bytesWritten = 0;
  final Completer<void> _finished = Completer<void>();

  /// Completa quando a gravação termina (stop() ou erro).
  Future<void> get finished => _finished.future;


  /// Duração estimada em segundos a partir dos bytes gravados (TS a
  /// aproximadamente 5 Mbps).
  int get estimatedSeconds => (bytesWritten / (5 * 1024 * 1024 / 8)).round();

  Future<void> open() async {
    if (_state != _RecordingState.writing) return;
    try {
      _handle = await file.open(mode: FileMode.writeOnlyAppend);
    } catch (_) {
      _state = _RecordingState.failed;
      if (!_finished.isCompleted) _finished.complete();
    }
  }

  /// Grava um trecho dos bytes do stream (chamado pelo proxy conforme
  /// chegam da rede; sem manter nada na memória).
  Future<void> write(List<int> chunk) async {
    if (_state != _RecordingState.writing) return;
    final handle = _handle;
    if (handle == null) return;
    try {
      bytesWritten += chunk.length;
      await handle.writeFrom(chunk);
    } catch (_) {
      _state = _RecordingState.failed;
      if (!_finished.isCompleted) _finished.complete();
    }
  }

  /// Encerra a gravação, fecha o arquivo e libera o disco.
  Future<void> stop() async {
    if (_state != _RecordingState.writing) return;
    await _handle?.flush();
    await _handle?.close();
    _handle = null;
    _state = _RecordingState.saved;
    if (!_finished.isCompleted) _finished.complete();
  }

  Future<int> get fileSize => isRunning
      ? Future.value(bytesWritten)
      : file.exists().then((exists) => exists ? file.length() : 0);

  Future<void> delete() async {
    await _handle?.close();
    _handle = null;
    _state = _RecordingState.deleted;
    if (await file.exists()) await file.delete();
  }

  static DateTime _parseStamp(String path) {
    // Nome gerado como "<canal>_2026-08-13T15:30:45.ts"
    final match = RegExp(r'_(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.ts$')
        .firstMatch(path);
    return DateTime.tryParse(match?.group(1) ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  static String _channelNameFrom(String path) {
    final base = path.split('/').last;
    final underscore = base.indexOf('_');
    if (underscore <= 0) return base;
    return base.substring(0, underscore).replaceAll('-', ' ');
  }

  static String _safe(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^\w\s\-]'), '').trim();
    final safe = cleaned.isEmpty ? 'canal' : cleaned;
    return safe.replaceAll(' ', '-').substring(0, safe.length.clamp(1, 40));
  }
}

enum _RecordingState { writing, saved, failed, deleted }
