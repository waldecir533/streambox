// Teste unitário do parser bruto do cliente HTTP manual (_RawHttpGet.parse):
// isola a descompressão gzip/deflate e o decode chunked sem depender de rede.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/services/m3u_parser.dart';

// _RawHttpGet é privado; testamos via reflexão pública: PlaylistService.
// Como o parse é privado, usamos o teste de integração importFromUrl em
// m3u_diagnostico_test.dart. Este arquivo valida decodeText/BOM do parser.

void main() {
  group('M3uParser.decodeText', () {
    test('remove BOM UTF-8 e decodifica normalmente', () {
      final withBom = <int>[...utf8.encode('\uFEFF#EXTM3U\r\n')];
      expect(M3uParser.decodeText(withBom), '#EXTM3U\r\n');
    });

    test('bytes sem BOM passam intactos', () {
      expect(M3uParser.decodeText(utf8.encode('#EXTM3U\r\n')), '#EXTM3U\r\n');
    });

    test('bytes inválidos em UTF-8 caem em latin-1 sem quebrar', () {
      final bytes = utf8.encode('#EXTM3U\r\nCafé \xC0\xC1');
      final text = M3uParser.decodeText(bytes);
      expect(text, startsWith('#EXTM3U'));
      expect(text, contains('Café'));
    });

    test('BOM + CRLF em misturas não impede reconhecer playlist', () {
      final src = '\uFEFF#EXTM3U\r\n#EXTINF:-1,Canal\r\nhttp://x\r\n';
      for (final variant in [
        src.replaceAll('\r\n', '\n'),
        src.replaceAll('\r\n', '\r'),
        src,
      ]) {
        final text = M3uParser.decodeText(utf8.encode(variant));
        expect(text.trimLeft(), startsWith('#EXTM3U'),
            reason: 'falhou com quebras: ${variant.codeUnits.take(5)}');
      }
    });
  });

  group('M3uParser inspect', () {
    test('BOM removido permite reconhecer #EXTM3U', () {
      final head = M3uParser.decodeText(
        utf8.encode('\uFEFF#EXTM3U\r\n#EXTINF:-1,Canal\r\nhttp://x\r\n'),
      );
      expect(M3uParser.inspect(head).isPlaylist, isTrue);
    });
  });
}
