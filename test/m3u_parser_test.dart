import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/services/m3u_parser.dart';

void main() {
  test('parses EXTINF channels and groups', () {
    const source = '''
#EXTM3U
#EXTINF:-1 tvg-id="news" tvg-logo="https://example.com/logo.png" group-title="Notícias",Canal Teste
https://example.com/live/index.m3u8
''';

    final channels = const M3uParser().parse(source);

    expect(channels, hasLength(1));
    expect(channels.first.name, 'Canal Teste');
    expect(channels.first.group, 'Notícias');
    expect(channels.first.tvgId, 'news');
    expect(channels.first.url, 'https://example.com/live/index.m3u8');
  });

  test('ignores comments, invalid URLs and entries without EXTINF', () {
    const source = '''
#EXTM3U
https://example.com/without-metadata.m3u8
#EXTINF:-1,Inválido
not-a-url
#EXTINF:-1,Canal seguro
https://example.com/live.m3u8
''';

    final channels = const M3uParser().parse(source);

    expect(channels, hasLength(1));
    expect(channels.single.name, 'Canal seguro');
  });

  test('preserves User-Agent and Referer options for remote playback', () {
    const source = '''
#EXTM3U
#EXTINF:-1,Canal protegido
#EXTVLCOPT:http-user-agent=StreamBox/1.0
#EXTVLCOPT:http-referrer=https://example.com/player
#EXTHTTP:{"Authorization":"Bearer secret"}
https://cdn.example.com/live.m3u8
''';

    final channel = const M3uParser().parse(source).single;

    expect(channel.headers['User-Agent'], 'StreamBox/1.0');
    expect(channel.headers['Referer'], 'https://example.com/player');
    expect(channel.headers['Authorization'], 'Bearer secret');
  });
}
