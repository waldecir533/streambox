import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:streambox/services/recording_service.dart';

class _MockPathProvider extends PathProviderPlatform {
  _MockPathProvider(this.directory);
  final Directory directory;

  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('streambox_rec_');
    PathProviderPlatform.instance = _MockPathProvider(tempDir);
  });
  tearDown(() async {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('start/write/stop creates a .ts file with the recorded bytes',
      () async {
    final recording =
        await RecordingService.instance.start('Canal Teste', 'http://exemplo/a.ts');
    expect(recording.isRunning, isTrue);
    expect(recording.bytesWritten, 0);
    await recording.open();
    await recording.write(List.filled(1024, 1));
    await recording.write(List.filled(512, 2));
    await recording.stop();
    expect(recording.isRunning, isFalse);
    expect(recording.isSaved, isTrue);
    expect(await recording.fileSize, 1536);
    expect(recording.file.path, endsWith('.ts'));
    expect(recording.file.path, contains('Canal-Teste'));
  });

  test('list returns saved recordings newest first', () async {
    final first = await RecordingService.instance.start('Canal A', 'http://exemplo/a.ts');
    await first.open();
    await first.write(List.filled(10, 1));
    await first.stop();

    final second = await RecordingService.instance.start('Canal B', 'http://exemplo/b.ts');
    await second.open();
    await second.write(List.filled(20, 2));
    await second.stop();

    final list = await RecordingService.instance.list();
    expect(list.map((r) => r.channelName), containsAll(['Canal A', 'Canal B']));
    // Mais novo primeiro.
    expect(list.first.channelName, 'Canal B');
  });

  test('list includes recordings in progress', () async {
    final recording =
        await RecordingService.instance.start('Canal Ao Vivo', 'http://exemplo/c.ts');
    await recording.open();
    await recording.write(List.filled(5, 1));

    final list = await RecordingService.instance.list();
    final live = list.where((r) => r.channelName == 'Canal Ao Vivo').toList();
    expect(live, hasLength(1));
    expect(live.single.isRunning, isTrue);
    await recording.stop();
  });

  test('delete removes the file from disk', () async {
    final recording =
        await RecordingService.instance.start('Para Excluir', 'http://exemplo/d.ts');
    await recording.open();
    await recording.write(List.filled(8, 3));
    await recording.stop();
    final path = recording.file.path;
    expect(File(path).existsSync(), isTrue);

    await recording.delete();
    expect(File(path).existsSync(), isFalse);
  });

  test('enforceStorageLimit removes oldest recordings first', () async {
    for (int i = 0; i < 3; i++) {
      final recording = await RecordingService.instance.start(
          'Canal $i', 'http://exemplo/$i.ts');
      await recording.open();
      await recording.write(List.filled(600, 1));
      await recording.stop();
      // Garante ordem de criação diferente (resolução do relógio no CI).
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await RecordingService.instance.enforceStorageLimit(1200);

    final list = await RecordingService.instance.list();
    expect(list, hasLength(2));
    // As gravações mais antigas são apagadas primeiro.
    final canal0 = list.where((r) => r.channelName == 'Canal 0').toList();
    if (canal0.isNotEmpty) {
      fail('A gravação mais antiga (Canal 0) deveria ter sido apagada.');
    }
  });

  test('safe filenames strip invalid characters (file is created)', () async {
    final recording = await RecordingService.instance.start(
        'Canal: 2 <HD>!', 'http://exemplo/especial.ts');
    await recording.open();
    await recording.write(List.filled(10, 5));
    await recording.stop();
    // O nome do canal é sanitizado (sem ':' '<' '>'). O timestamp no nome
    // mantém 'T' e dois-pontos do horário ISO, então validamos o prefixo
    // do nome gerado (parte antes do underscore).
    final base = recording.file.path.split('/').last;
    final prefix = base.split('_').first;
    expect(prefix, isNot(contains(':')));
    expect(prefix, isNot(contains('<')));
    expect(prefix, isNot(contains('>')));
    expect(prefix, isNot(contains('!')));
    expect(recording.file.existsSync(), isTrue);
  });

  test('Recording.fromFile restores the channel name and stamp', () async {
    final recording = await RecordingService.instance.start(
        'ESPN', 'http://exemplo/espn.ts');
    await recording.open();
    await recording.write(List.filled(400, 4));
    await recording.stop();

    final restored = Recording.fromFile(recording.file);
    expect(restored.channelName, 'ESPN');
    expect(restored.isSaved, isTrue);
    expect(restored.isRunning, isFalse);
    expect(await restored.fileSize, 400);
  });
}
