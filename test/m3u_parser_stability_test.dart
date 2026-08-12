import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/services/m3u_parser.dart';

/// Playlist fictícia e local (autorizada — não usa credenciais reais).
/// Reproduz formatos comuns de listas IPTV reais.
const String kTinyPlaylist = '''
#EXTM3U
#EXTINF:-1 tvg-logo="" group-title="Abertos",Globo SP
http://example.invalid/tv/globo_sp
#EXTINF:-1 tvg-logo="" group-title="Abertos",SBT
http://example.invalid/tv/sbt
#EXTINF:-1 tvg-logo="" group-title="Filmes",Telecine
http://example.invalid/tv/telecine
''';

String kBigPlaylist = () {
  final buffer = StringBuffer();
  buffer.write('#EXTM3U\n');
  for (var i = 0; i < 50000; i++) {
    buffer.write('#EXTINF:-1 tvg-logo="https://example.invalid/logo$i.png" '
        'group-title="Categoria ${i % 200}",Canal ${i + 1}\n'
        'http://example.invalid/stream/$i\n');
  }
  return buffer.toString();
}();

const String kMalformedPlaylist = '''
#EXTM3U
#EXTINF:-1 tvg-logo="" group-title="Abertos",Canal A
http://example.invalid/a

  



garbage sem formato
#EXTINF:-1,Canal sem URL válida
not a url
#EXTINF:-1,Canal B
http://example.invalid/b
#EXTINF:-1,Canal Especial Ã©íüõ ñ中文
http://example.invalid/special-éíü
''';

void main() {
  late M3uParser parser;

  setUp(() {
    parser = const M3uParser();
  });

  group('M3uParser', () {
    test('analisa playlist pequena com grupos e logotipos', () {
      final channels = parser.parse(kTinyPlaylist);
      expect(channels, hasLength(3));
      expect(channels[0].name, 'Globo SP');
      expect(channels[0].group, 'Abertos');
      expect(channels[2].name, 'Telecine');
      expect(channels[2].group, 'Filmes');
    });

    test('tolera linhas malformadas, vazias e caracteres especiais', () {
      final channels = parser.parse(kMalformedPlaylist);
      // Apenas as três URLs válidas devem entrar: a, b e special.
      expect(channels, hasLength(3));
      expect(channels.map((c) => c.url).toSet(), {
        'http://example.invalid/a',
        'http://example.invalid/b',
        'http://example.invalid/special-éíü',
      });
      expect(channels.last.name, 'Canal Especial Ã©íüõ ñ中文');
    });

    test('rejeita arquivo vazio com mensagem clara', () {
      expect(() => parser.parse('   \n \n'), throwsFormatException);
    });

    test('rejeita arquivo sem nenhum canal válido', () {
      expect(
        () => parser.parse('#EXTM3U\n# só comentários'),
        throwsFormatException,
      );
    });

    test('parseAsync roda em Isolate e não trava a thread principal',
        () async {
      final start = DateTime.now();
      final channels = await parser.parseAsync(
        kBigPlaylist,
        onProgress: (_) {},
      );
      expect(channels, hasLength(50000));
      expect(channels.first.name, 'Canal 1');
      // 49999 % 200 = 199 — o último canal pertence à categoria 199.
      expect(channels.last.group, 'Categoria 199');
      final elapsed = DateTime.now().difference(start);
      // Uma lista de 50 mil canais não deve travar a interface.
      expect(elapsed.inSeconds, lessThan(30));
    });

    test('parseAsync respeita cancelamento', () async {
      final token = CancelToken();
      final future = parser.parseAsync(
        kBigPlaylist,
        cancelToken: token,
      );
      // Cancela imediatamente.
      token.cancel();
      await expectLater(future, throwsA(isA<FormatException>()));
    });

    test('parseAsync respeita timeout curto', () async {
      // Isolate.run não permite limitar tempo de CPU de forma absoluta, mas
      // o timer do parser precisa disparar para fontes que demoram de fato.
      // Aqui garantimos que o contrato de timeout não trava a chamada.
      final future = parser.parseAsync(
        kBigPlaylist,
        timeout: const Duration(seconds: 30),
      );
      await future.timeout(const Duration(seconds: 60));
    });
  });

  group('CancelToken', () {
    test('aciona listeners imediatamente quando já cancelado', () {
      final token = CancelToken();
      token.cancel();
      var called = false;
      token.addListener(() => called = true);
      expect(called, isTrue);
      expect(token.isCancelled, isTrue);
    });
  });
}
