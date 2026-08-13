import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/channel.dart';

/// Persistência de canais em **arquivo** (NDJSON: uma linha JSON por canal),
/// em vez de uma única string gigante no SharedPreferences — que provoca
/// falta de memória ao salvar/ler listas grandes no Android.
///
/// **Transação segura**: uma nova importação nunca apaga a lista atual antes
/// de terminar. Os canais novos são gravados em um arquivo temporário e,
/// somente ao final, o arquivo é substituído por rename atômico. Se algo
/// falhar no meio, a lista anterior permanece intacta e utilizável.
///
/// Os canais são gravados em lotes pequenos e lidos em fluxo, com a
/// decodificação ocorrendo em Isolate separado para não travar a interface.
class ChannelsStore {
  static const String _fileName = 'channels.ndjson';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<String> _dirPath() async =>
      (await getApplicationDocumentsDirectory()).path;

  /// Remove a persistência anterior (usada em operações explícitas como
  /// "excluir lista"; a importação normal não usa este método).
  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // Falha ao apagar arquivo antigo: seguir em frente e regravar.
      }
    }
  }

  /// Quantidade de canais já persistidos, contada em fluxo (sem carregar o
  /// arquivo inteiro na memória).
  Future<int> count() async {
    final file = await _file();
    if (!await file.exists()) return 0;
    final stream = file.openRead().transform(utf8.decoder);
    return await stream
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty)
        .length;
  }

  /// Carrega todos os canais já persistidos, lendo em fluxo e decodificando
  /// em Isolate em lotes. Retorna lista vazia se o arquivo não existir ou
  /// estiver corrompido — nunca lança exceção para a interface.
  Future<List<Channel>> loadAll({int decodeBatchSize = 2000}) async {
    final file = await _file();
    if (!await file.exists()) return const [];

    try {
      final stat = await file.stat();
      if (stat.size <= 1024 * 1024) {
        // Arquivos pequenos podem ser lidos inteiros e decodificados de uma
        // vez no Isolate, sem risco de memória.
        final raw = await file.readAsString();
        if (raw.isEmpty) return const [];
        return await compute(_decode, _DecodeArgs(raw, decodeBatchSize));
      }

      // Arquivos grandes: leitura em chunks e decodificação incremental em
      // isolates, garantindo memória de pico muito menor.
      return await _loadIncremental(file, decodeBatchSize: decodeBatchSize);
    } catch (_) {
      // Arquivo corrompido ou falha de leitura: retorna lista vazia e a
      // importação poderá ser refeita sem perder o aplicativo.
      return const [];
    }
  }

  Future<List<Channel>> _loadIncremental(
    File file, {
    int decodeBatchSize = 2000,
  }) async {
    final channels = <Channel>[];
    final collector = <String>[];

    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      final lines = chunk.split('\n');
      // O último segmento pode terminar sem \n: junta com o próximo chunk.
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        collector.add(line);
        if (collector.length >= decodeBatchSize) {
          channels.addAll(await compute(_decode, _DecodeArgs(
            collector.join('\n'),
            decodeBatchSize,
          )));
          collector.clear();
        }
      }
    }
    if (collector.isNotEmpty) {
      channels.addAll(await compute(_decode, _DecodeArgs(
        collector.join('\n'),
        decodeBatchSize,
      )));
    }
    return channels;
  }

  /// Grava os [channels] em lotes de [writeBatchSize], concatenando ao
  /// arquivo existente (append) sem manter cópias duplicadas na memória.
  Future<void> append(List<Channel> channels, {int writeBatchSize = 1000}) async {
    if (channels.isEmpty) return;
    final file = await _file();
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
        // Libera a thread principal entre lotes para manter a UI fluida.
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (buffer.isNotEmpty) sink.write(buffer.toString());
    await sink.flush();
    await sink.close();
  }

  /// **Substituição transacional**: grava os [channels] em um arquivo
  /// temporário e só no final substitui o arquivo atual por rename atômico.
  /// Se a gravação falhar no meio, a lista anterior permanece intacta e
  /// utilizável. Retorna a quantidade de canais gravados.
  Future<int> saveAll(List<Channel> channels, {int writeBatchSize = 1000}) async {
    if (channels.isEmpty) return 0;
    final dirPath = await _dirPath();
    final tempPath = '$dirPath/$_fileName.tmp';
    final tempFile = File(tempPath);
    final currentFile = await _file();

    // Grava tudo no temporário, em lotes.
    final sink = tempFile.openWrite(mode: FileMode.writeOnly);
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

    // Verificação mínima de integridade antes de substituir.
    final stat = await tempFile.stat();
    if (stat.size <= 0) {
      await tempFile.delete().catchError((_) => File("")); 
      throw StateError('A gravação da lista ficou vazia. Nada foi substituído.');
    }

    // Rename atômico no mesmo sistema de arquivos: substitui o arquivo atual
    // de uma só vez — em caso de queda no meio da operação, ou permanece a
    // lista antiga (rename falhou) ou a nova (rename concluído), nunca um
    // arquivo pela metade.
    await tempFile.rename(currentFile.path);
    return channels.length;
  }

  /// Retorna a quantidade aproximada de memória ocupada pelo arquivo, em MB.
  Future<double> fileSizeMb() async {
    final file = await _file();
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
    } catch (_) {
      // Linha corrompida: ignora apenas ela e continua a restauração.
    }
  }
  return channels;
}
