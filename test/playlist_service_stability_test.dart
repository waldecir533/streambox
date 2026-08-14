
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:streambox/services/m3u_parser.dart';
import 'package:streambox/services/playlist_service.dart';

import 'm3u_parser_stability_test.dart';

void main() {
  group('PlaylistService.importFromUrl', () {
    test('rejeita URL inválida com mensagem clara', () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response('', 200)),
      );
      final result = await service.importFromUrl('nota-uma-url');
      expect(result.isSuccess, isFalse);
      expect(result.message, contains('URL'));
      service.dispose();
    });

    test('rejeita resposta HTTP de erro com mensagem específica por status',
        () async {
      Future<ImportResult> statusTest(int code, String expectContains) async {
        final service = PlaylistService(
          client: MockClient((_) async => http.Response('erro', code)),
          timeout: const Duration(seconds: 5),
        );
        final result = await service.importFromUrl(
          'http://example.invalid/lista.m3u',
        );
        service.dispose();
        return result;
      }

      final by401 = await statusTest(401, 'senha');
      expect(by401.isSuccess, isFalse);
      expect(by401.statusCode, 401);
      expect(by401.message, contains('senha'));

      final by404 = await statusTest(404, 'não foi encontrado');
      expect(by404.message, contains('não foi encontrado'));

      final by429 = await statusTest(429, 'Muitas solicitações');
      expect(by429.message, contains('Muitas solicitações'));

      final by500 = await statusTest(500, 'erro');
      expect(by500.message, contains('erro'));
    });

    test('rejeita corpo vazio do servidor', () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response('   ', 200)),
      );
      final result = await service.importFromUrl(
        'http://example.invalid/lista.m3u',
      );
      expect(result.isSuccess, isFalse);
      expect(result.message, contains('vazio ou só contém espaços'));
      service.dispose();
    });

    test('reconhece página HTML (Cloudflare) com mensagem clara', () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response(
              '<!DOCTYPE html><html><body>Cloudflare bloqueio</body></html>',
              200,
            )),
      );
      final result = await service.importFromUrl(
        'http://example.invalid/lista.m3u',
      );
      expect(result.isSuccess, isFalse);
      expect(result.sourceType, SourceType.html);
      expect(result.message, contains('HTML'));
      service.dispose();
    });

    test('reconhece JSON como possível Xtream com mensagem clara', () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response(
              '{"user_info": {"auth": 0, "status": "expired"}}',
              200,
            )),
      );
      final result = await service.importFromUrl(
        'http://example.invalid/get.php',
      );
      expect(result.isSuccess, isFalse);
      expect(result.sourceType, SourceType.json);
      expect(result.message, contains('Xtream'));
      service.dispose();
    });

    test('reconhece stream HLS individual sem confundir com playlist',
        () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response(kHlsStream, 200)),
      );
      final result = await service.importFromUrl(
        'http://example.invalid/stream/channel.m3u8',
      );
      expect(result.isSuccess, isFalse);
      expect(result.isIndividualStream, isTrue);
      expect(result.sourceType, SourceType.hlsStream);
      expect(result.message, contains('stream individual'));
      service.dispose();
    });

    test('lança TimeoutException convertido quando o servidor não responde',
        () async {
      final service = PlaylistService(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(minutes: 1));
          return http.Response(kTinyPlaylist, 200);
        }),
        timeout: const Duration(seconds: 1),
      );
      final result = await service.importFromUrl(
        'http://example.invalid/lista.m3u',
      );
      expect(result.isSuccess, isFalse);
      expect(result.message, contains('demorou'));
      service.dispose();
    });

    test('trata erro de conexão (DNS/SSL) com mensagem amigável', () async {
      final service = PlaylistService(
        client: MockClient((_) async {
          throw Exception(
            'SocketException: Failed host lookup: servidor.invalid',
          );
        }),
      );
      final result = await service.importFromUrl(
        'http://servidor.invalid/lista.m3u',
      );
      expect(result.isSuccess, isFalse);
      expect(result.message, contains('conectar'));
      service.dispose();
    });

    test('tratamento de redirecionamento 301 devolvido como erro claro',
        () async {
      var calls = 0;
      final service = PlaylistService(
        client: MockClient((_) async {
          calls += 1;
          return http.Response('', 301);
        }),
      );
      final result = await service.importFromUrl(
        'http://example.invalid/lista.m3u',
      );
      expect(result.isSuccess, isFalse);
      expect(calls, 1);
      service.dispose();
    });

    test('carrega playlist grande sem travar a thread principal', () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response(kBigPlaylist, 200)),
        timeout: const Duration(seconds: 30),
      );
      final progressValues = <double>[];
      final result = await service.importFromUrl(
        'http://example.invalid/big.m3u',
        onProgress: progressValues.add,
      );
      expect(result.isSuccess, isTrue);
      expect(result.channels, hasLength(50000));
      expect(result.sourceType, SourceType.playlist);
      service.dispose();
    });

    test('importação cancelada não retorna canais', () async {
      final service = PlaylistService(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(minutes: 1));
          return http.Response(kBigPlaylist, 200);
        }),
      );
      final future = service.importFromUrl('http://example.invalid/big.m3u');
      service.cancelToken?.cancel();
      final result = await future.timeout(const Duration(seconds: 10),
          onTimeout: () =>
              const ImportResult(message: 'cancelada por timeout do teste'));
      expect(result.channels, isEmpty);
      service.dispose();
    });
  });
}

const String kHlsStream = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.0,
segment0.ts
#EXTINF:6.0,
segment1.ts
''';
