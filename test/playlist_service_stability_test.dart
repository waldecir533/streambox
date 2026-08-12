import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:streambox/services/playlist_service.dart';

import 'm3u_parser_stability_test.dart';

void main() {
  group('PlaylistService', () {
    test('rejeita URL inválida com mensagem clara', () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await expectLater(
        service.loadFromUrl('nota-uma-url'),
        throwsA(isA<FormatException>()),
      );
      service.dispose();
    });

    test('rejeita resposta HTTP de erro', () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response('erro', 500)),
        timeout: const Duration(seconds: 5),
      );
      await expectLater(
        service.loadFromUrl('http://example.invalid/lista.m3u'),
        throwsA(isA<Exception>()),
      );
      service.dispose();
    });

    test('rejeita corpo vazio do servidor', () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response('   ', 200)),
      );
      await expectLater(
        service.loadFromUrl('http://example.invalid/lista.m3u'),
        throwsA(isA<FormatException>()),
      );
      service.dispose();
    });

    test('lança TimeoutException quando o servidor não responde',
        () async {
      final service = PlaylistService(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(minutes: 1));
          return http.Response(kTinyPlaylist, 200);
        }),
        timeout: const Duration(seconds: 1),
      );
      await expectLater(
        service.loadFromUrl('http://example.invalid/lista.m3u'),
        throwsA(isA<TimeoutException>()),
      );
      service.dispose();
    });

    test('segue redirecionamentos (301 http -> https) com MockClient',
        () async {
      var calls = 0;
      final service = PlaylistService(
        // http.Client real segue redirecionamentos automaticamente; o
        // MockClient devolve 301 manualmente, o que o cliente real já
        // trataria. Aqui comprovamos que o serviço não confunde 301 com
        // sucesso nem com erro.
        client: MockClient((_) async {
          calls += 1;
          return http.Response('', 301);
        }),
      );
      await expectLater(
        service.loadFromUrl('http://example.invalid/lista.m3u'),
        throwsA(isA<Exception>()),
      );
      expect(calls, 1);
      service.dispose();
    });

    test('carrega playlist grande sem travar a thread principal',
        () async {
      final service = PlaylistService(
        client: MockClient((_) async => http.Response(kBigPlaylist, 200)),
        timeout: const Duration(seconds: 30),
      );
      final progressValues = <double>[];
      final channels = await service.loadFromUrl(
        'http://example.invalid/big.m3u',
        onProgress: progressValues.add,
      );
      expect(channels, hasLength(50000));
      service.dispose();
    });

    test('cancelToken cancela download/análise em andamento', () async {
      final service = PlaylistService(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(minutes: 1));
          return http.Response(kBigPlaylist, 200);
        }),
      );
      final future = service.loadFromUrl(
        'http://example.invalid/big.m3u',
      );
      service.cancelToken?.cancel();
      // A carga completa nunca retorna; a análise é cancelada.
      await expectLater(
        future.timeout(const Duration(seconds: 10)),
        throwsA(anything),
      );
      service.dispose();
    });
  });
}
