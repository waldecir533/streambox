import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/services/library_section_service.dart';

void main() {
  group('LibrarySectionService', () {
    test('classifica categorias brasileiras de filmes', () {
      expect(LibrarySectionService.sectionOf('Filmes'), LibrarySection.movies);
      expect(LibrarySectionService.sectionOf('Filmes 4K'), LibrarySection.movies);
      expect(LibrarySectionService.sectionOf('Filmes HD'), LibrarySection.movies);
      expect(LibrarySectionService.sectionOf('Movies'), LibrarySection.movies);
      expect(LibrarySectionService.sectionOf('Cinema'), LibrarySection.movies);
    });

    test('classifica categorias de séries e novelas', () {
      expect(LibrarySectionService.sectionOf('Séries'), LibrarySection.series);
      expect(LibrarySectionService.sectionOf('Séries HD'), LibrarySection.series);
      expect(LibrarySectionService.sectionOf('Novelas'), LibrarySection.series);
      expect(LibrarySectionService.sectionOf('Episódios'), LibrarySection.series);
    });

    test('classifica categorias de esportes', () {
      expect(LibrarySectionService.sectionOf('Esportes'), LibrarySection.sports);
      expect(LibrarySectionService.sectionOf('Futebol'), LibrarySection.sports);
      expect(LibrarySectionService.sectionOf('Fight'), LibrarySection.sports);
    });

    test('canais sem categoria ou com categoria comum são TV ao vivo', () {
      expect(LibrarySectionService.sectionOf(null), LibrarySection.live);
      expect(LibrarySectionService.sectionOf(''), LibrarySection.live);
      expect(LibrarySectionService.sectionOf('Entretenimento'), LibrarySection.live);
      expect(LibrarySectionService.sectionOf('Notícias'), LibrarySection.live);
      expect(LibrarySectionService.sectionOf('Kids TV'), LibrarySection.live);
    });

    test('subtemas atribuem Notícias e Infantil à TV ao vivo', () {
      expect(LibrarySectionService.classify('Notícias').section, LibrarySection.live);
      expect(LibrarySectionService.classify('Notícias').subtopic, 'Notícias');
      expect(LibrarySectionService.classify('Kids TV').section, LibrarySection.live);
      expect(LibrarySectionService.classify('Kids TV').subtopic, 'Infantil');
      expect(LibrarySectionService.classify(null).subtopic, 'Todos');
      expect(LibrarySectionService.classify('Entretenimento').subtopic, 'Entretenimento');
    });

    test('tolera variações de caixa, sublinhado e hífen', () {
      expect(LibrarySectionService.sectionOf('FILMES'), LibrarySection.movies);
      expect(LibrarySectionService.sectionOf('esportes_hd'), LibrarySection.sports);
      expect(LibrarySectionService.sectionOf('Novelas-HD'), LibrarySection.series);
    });
  });
}
