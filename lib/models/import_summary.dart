import '../models/channel.dart';
import '../services/library_section_service.dart';

/// Resumo estatístico de uma importação, usado no diálogo de conclusão
/// ("Ver detalhes"). Identifica seções por palavras-chave em `group-title`
/// (respeitando o agrupamento informado pela lista, como pede a Fase 1) e
/// conta entradas ignoradas, tempo e tamanho.
class ImportSummary {
  const ImportSummary({
    required this.channels,
    required this.movies,
    required this.series,
    required this.sports,
    required this.liveChannels,
    required this.groups,
    required this.skippedLines,
    required this.bytes,
    required this.durationSeconds,
  });

  final int channels;
  final int movies;
  final int series;
  final int sports;
  final int liveChannels;
  final int groups;
  final int skippedLines;
  final int bytes;
  final double durationSeconds;

  int get totalSections => movies + series + sports;

  /// Calcula o resumo a partir dos canais importados, classificando por
  /// palavras-chave reconhecidas do padrão brasileiro.
  factory ImportSummary.fromChannels({
    required List<Channel> channels,
    required int skippedLines,
    required int bytes,
    required double durationSeconds,
  }) {
    final groups = <String>{};
    int movies = 0, series = 0, sports = 0, liveChannels = 0;
    for (final channel in channels) {
      final g = channel.group ?? '';
      if (g.isNotEmpty) groups.add(g);
      switch (LibrarySectionService.sectionOf(channel.group)) {
        case LibrarySection.movies:
          movies++;
        case LibrarySection.series:
          series++;
        case LibrarySection.sports:
          sports++;
        case LibrarySection.live:
        case LibrarySection.others:
          liveChannels++;
      }
    }
    return ImportSummary(
      channels: channels.length,
      movies: movies,
      series: series,
      sports: sports,
      liveChannels: liveChannels,
      groups: groups.length,
      skippedLines: skippedLines,
      bytes: bytes,
      durationSeconds: durationSeconds,
    );
  }

  String get durationDescription {
    final seconds = durationSeconds.round();
    if (seconds < 60) return '$seconds segundos';
    final minutes = (seconds / 60).floor();
    final rest = seconds % 60;
    return rest > 0 ? '$minutes min e $rest s' : '$minutes minutos';
  }

  String get sizeDescription {
    final mb = bytes / (1024 * 1024);
    if (mb < 1) return '${(bytes / 1024).round()} KB';
    return '${mb.toStringAsFixed(1)} MB';
  }
}
