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
}
