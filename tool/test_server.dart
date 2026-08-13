// Servidor de teste para fixtures de importação (sem credenciais reais).
// Endpoints:
//   /small.m3u          playlist pequena válida (canais autorizados/fictícios)
//   /big.m3u?count=N    playlist grande (padrão 25000) — simula lista real BR
//   /big.m3u.gz         mesma playlist grande comprimida com gzip
//   /stream/channel.m3u8 stream HLS individual (uma mídia, sem #EXTM3U)
//   /stream/video.mp4   fluxo MPEG-TS/MP4 direto
//   /cloudflare.html    resposta HTML de bloqueio
//   /xtream.json        resposta JSON de erro do provedor
//   /slow.m3u           resposta lenta (5s por chunk)
//   /redir              redireciona para /small.m3u
//   /401, /404, /500    erros HTTP
// Todos os canais usam URLs públicas/locais fictícias (ex.: rtmp://invalid).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

String buildPlaylist(int count) {
  final groups = [
    'TV Aberta', 'Filmes e Séries', 'Esportes', 'Infantil', 'Documentários',
    'Variedades', 'Música', 'Religioso', 'Notícias', 'Adulto', 'Regional',
  ];
  final buf = StringBuffer();
  buf.writeln('#EXTM3U url-tvg="http://invalid.example.com/epg.xml" x-tvg-url="http://invalid.example.com/epg2.xml"');
  for (var i = 0; i < count; i++) {
    final g = groups[i % groups.length];
    buf.write('#EXTINF:-1 tvg-id="ch$i.example.com" tvg-name="Canal ${i + 1} BR" ');
    buf.write('tvg-language="PT" tvg-country="BR" tvg-logo="http://invalid.example.com/logo$i.png" ');
    buf.write('group-title="$g",Canal ${i + 1} — $g (Série "Aventura")\n');
    buf.writeln('http://invalid.example.com/stream/$i.ts');
  }
  return buf.toString();
}

final String smallPlaylist = '''#EXTM3U url-tvg="http://invalid.example.com/epg.xml"
#EXTINF:-1 tvg-id="aberta1.example.com" tvg-name="TV Aberta 1" tvg-language="PT" tvg-country="BR" group-title="TV Aberta",TV Aberta 1
http://invalid.example.com/aberta1.ts
#EXTINF:-1 tvg-id="film1.example.com" group-title="Filmes e Séries",Filme Exemplo (2024)
http://invalid.example.com/filme1.mp4
#EXTINF:-1 tvg-id="esp1.example.com" group-title="Esportes",Esporte Total
http://invalid.example.com/esp1.ts
''';

final String hlsStream = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.0,
segment0.ts
#EXTINF:6.0,
segment1.ts
''';

void main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8099);
  final big = buildPlaylist(25000);
  final bigGz = gzip.encode(utf8.encode(big));

  server.listen((req) async {
    try {
      if (req.uri.path == '/small.m3u') {
        req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.write(smallPlaylist);
      } else if (req.uri.path == '/big.m3u') {
        final count = int.tryParse(req.uri.queryParameters['count'] ?? '') ?? 25000;
        final playlist = count <= 25000 ? big : buildPlaylist(count);
        req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.write(playlist);
      } else if (req.uri.path == '/big.m3u.gz') {
        req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.add(bigGz);
      } else if (req.uri.path == '/stream/channel.m3u8') {
        req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        req.response.write(hlsStream);
      } else if (req.uri.path == '/cloudflare.html') {
        req.response.headers.contentType = ContentType.text;
        req.response.write('<!DOCTYPE html><html><body><title>Attention Required! | Cloudflare</title></body></html>');
      } else if (req.uri.path == '/xtream.json') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'user_info': {'auth': 0, 'status': 'expired'}, 'server_info': {}}));
      } else if (req.uri.path == '/slow.m3u') {
        req.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          req.response.write('linha $i\n');
        }
        req.response.write(smallPlaylist);
      } else if (req.uri.path == '/redir') {
        req.response.statusCode = HttpStatus.movedPermanently;
        req.response.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:8099/small.m3u');
      } else if (['/401', '/403', '/404', '/429', '/500'].contains(req.uri.path)) {
        req.response.statusCode = int.parse(req.uri.path.substring(1));
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    } catch (e) {
      try { await req.response.close(); } catch (_) {}
    }
  });

  stdout.writeln('Servidor de teste ouvindo em http://127.0.0.1:8099');
  // Manter vivo até interrupção.
  await Future<void>.delayed(const Duration(days: 1));
}
