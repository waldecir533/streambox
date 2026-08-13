// Organização do conteúdo no padrão brasileiro (Fase 2).
//
// Classifica cada canal em uma seção primária — TV ao vivo, Filmes, Séries,
// Esportes ou Outros — usando o group-title da própria lista. A classificação
// respeita sempre a categoria original: o group-title jamais é alterado,
// apenas agrupado sob a seção mais adequada ao estilo brasileiro de IPTV.
//
// Regras de precedência:
// 1. "Filme", "Filmes", "Movies", "Cinema", "VOD", "Filme 4K" → FILMES
// 2. "Série", "Séries", "Series", "Novelas", "Episódio" → SÉRIES
// 3. "Esporte", "Esportes", "Sports", "Futebol", "Fight" → ESPORTES
// 4. "Notícia", "Notícias", "News", "Info" → NOTÍCIAS (seção secundária)
// 5. "Infantil", "Kids", "Kids TV", "Desenho" → INFANTIL (seção secundária)
// 6. Qualquer outra categoria → TV AO VIVO (seções de canais em tempo real)
//
// As seções secundárias (Notícias e Infantil) pertencem ao universo
// "TV ao vivo": canais transmitidos ao vivo organizados por tema.

import 'package:flutter/material.dart';

enum LibrarySection {
  live('TV ao vivo', Icons.live_tv, 'TV ao vivo',
      'Canais transmitidos em tempo real, organizados por tema.'),
  movies('Filmes', Icons.movie, 'Filmes',
      'Filmes e títulos sob demanda (VOD) da lista.'),
  series('Séries', Icons.video_library, 'Séries',
      'Séries, novelas e episódios da lista.'),
  sports('Esportes', Icons.sports_soccer, 'Esportes',
      'Canais e eventos esportivos da lista.'),
  others('Outros', Icons.folder_outlined, 'Outros',
      'Entradas que não se encaixam nas seções principais.');

  const LibrarySection(this.label, this.icon, this.sectionName, this.description);
  final String label;
  final IconData icon;
  final String sectionName;
  final String description;
}

class LibrarySectionService {
  const LibrarySectionService._();

  /// Classifica o group-title em uma seção do padrão brasileiro.
  /// null/empty → [LibrarySection.live] (canal de TV em tempo real).
  static LibrarySection sectionOf(String? groupTitle) {
    final normalized = _normalize(groupTitle);
    if (normalized.isEmpty) return LibrarySection.live;
    if (_match(normalized, _kMovies)) return LibrarySection.movies;
    if (_match(normalized, _kSeries)) return LibrarySection.series;
    if (_match(normalized, _kSports)) return LibrarySection.sports;
    return LibrarySection.live;
  }

  /// Subtemas dentro de TV ao vivo (Notícias, Infantil, Música...).
  static String subtopicOf(String? groupTitle) {
    final normalized = _normalize(groupTitle);
    if (normalized.isEmpty) return 'Todos';
    if (_match(normalized, _kNews)) return 'Notícias';
    if (_match(normalized, _kKids)) return 'Infantil';
    if (_match(normalized, _kMusic)) return 'Música';
    if (_match(normalized, _kReligion)) return 'Religioso';
    return groupTitle!;
  }

  /// Seção + subtema resolvidos de uma só vez.
  static ({LibrarySection section, String subtopic}) classify(String? groupTitle) {
    final normalized = _normalize(groupTitle);
    if (normalized.isEmpty) {
      return (section: LibrarySection.live, subtopic: 'Todos');
    }
    if (_match(normalized, _kMovies)) return (section: LibrarySection.movies, subtopic: 'Filmes');
    if (_match(normalized, _kSeries)) return (section: LibrarySection.series, subtopic: 'Séries');
    if (_match(normalized, _kSports)) return (section: LibrarySection.sports, subtopic: 'Esportes');
    if (_match(normalized, _kNews)) return (section: LibrarySection.live, subtopic: 'Notícias');
    if (_match(normalized, _kKids)) return (section: LibrarySection.live, subtopic: 'Infantil');
    if (_match(normalized, _kMusic)) return (section: LibrarySection.live, subtopic: 'Música');
    if (_match(normalized, _kReligion)) return (section: LibrarySection.live, subtopic: 'Religioso');
    return (section: LibrarySection.live, subtopic: groupTitle!);
  }

  static String _normalize(String? value) =>
      (value ?? '').trim().toLowerCase().replaceAll('_', ' ').replaceAll('-', ' ');

  static bool _match(String normalized, Iterable<String> terms) =>
      terms.any((term) => normalized == term ||
          normalized.startsWith('$term ') ||
          normalized.endsWith(' $term') ||
          normalized.contains(' $term ') ||
          normalized.contains(' ($term)'));
}

const Set<String> _kMovies = {
  'filme', 'filmes', 'movie', 'movies', 'cinema', 'vod', 'filmes 4k',
  'filmes hd', 'filmes full hd', 'filmes sd', 'film', 'filmes 24h',
};

const Set<String> _kSeries = {
  'serie', 'series', 'série', 'séries', 'novela', 'novelas',
  'episodio', 'episódio', 'episodios', 'episódios', 'novelas hd',
};

const Set<String> _kSports = {
  'esporte', 'esportes', 'sport', 'sports', 'futebol', 'fight', 'ppv',
  'esportes hd', 'esportes 4k',
};

const Set<String> _kNews = {
  'noticia', 'notícias', 'noticias', 'notícia', 'news', 'informacao',
  'informação', 'info', '24h', '24 horas',
};

const Set<String> _kKids = {
  'infantil', 'kids', 'kids tv', 'desenho', 'desenhos', 'children',
  'kids hd',
};

const Set<String> _kMusic = {'musica', 'música', 'music', 'shows'};

const Set<String> _kReligion = {
  'religiao', 'religião', 'religion', 'evangelico', 'evangélico',
  'gospel', 'catolico', 'católico',
};
