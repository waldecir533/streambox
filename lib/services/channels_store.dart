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
/// Os canais são gravados em lotes pequenos e lidos em fluxo, com a
/// decodificação ocorrendo em Isolate separado para não travar a interface.
class ChannelsStore {
  static const String _fileName = 'channels.ndjson';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Remove a persistência anterior (usada antes de uma nova importação).
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

  /// Quantidade de canais já persistidos.
  Future<int> count() async {
    final file = await _file();
    if (!await file.exists()) return 0;
    final stream = file.openRead().transform(utf8.decoder);
    final lines = await stream
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty)
        .length;
    return lines;
  }

  /// Carrega todos os canais já persistidos, decodificando em Isolate.
  /// Retorna lista vazia se o arquivo não existir ou estiver corrompido.
  Future<List<Channel>> loadAll({int decodeBatchSize = 2000}) async {
    final file = await _file();
    if (!await file.exists()) return const [];

    final raw = await file.readAsString();
    if (raw.isEmpty) return const [];

    // Decodificação em Isolate em lotes, com tolerância a linhas inválidas.
    final channels = await compute(
      _decode,
      _DecodeArgs(raw, decodeBatchSize),
    );
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

  /// Substitui o conteúdo do arquivo pelos canais fornecidos, gravando em
  /// lotes (usado na importação completa após [clear]).
  Future<int> saveAll(List<Channel> channels, {int writeBatchSize = 1000}) async {
    await clear();
    await append(channels, writeBatchSize: writeBatchSize);
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
  int skipped = 0;

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    batchRaw.add(trimmed);
    if (batchRaw.length >= args.batchSize) {
      channels.addAll(_decodeBatch(batchRaw, skippedRef: skipped));
      skipped = 0; // recontado por lote
      batchRaw = [];
    }
  }
  if (batchRaw.isNotEmpty) {
    channels.addAll(_decodeBatch(batchRaw, skippedRef: skipped));
  }
  return channels;
}

List<Channel> _decodeBatch(List<String> raws, {int skippedRef = 0}) {
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
