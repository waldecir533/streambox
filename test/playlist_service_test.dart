import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:streambox/services/playlist_service.dart';

void main() {
  test('devolve mensagem amigável em vez de travar quando o servidor não responde',
      () async {
    final client = MockClient((_) => Completer<http.Response>().future);
    final service = PlaylistService(
      client: client,
      timeout: const Duration(milliseconds: 1),
    );

    final result = await service.importFromUrl(
      'https://example.com/list.m3u',
    );
    // Timeout nunca deve virar exceção para a interface: vira mensagem clara.
    expect(result.isSuccess, isFalse);
    expect(result.message, isNotNull);
    expect(result.message, contains('demorou'));
    service.dispose();
  });

  test('não falha com exceção para credenciais embutidas na URL (só sanitiza)',
      () async {
    var receivedHeaders = <String, String>{};
    final service = PlaylistService(
      client: MockClient((request) async {
        receivedHeaders = request.headers;
        return http.Response('#EXTM3U\n#EXTINF:-1,Canal 1\nhttp://x/1.ts\n', 200);
      }),
    );
    final result = await service.importFromUrl(
      'http://usuario:senha123@provedor.invalid/get.php?type=m3u_plus&output=ts',
    );
    expect(result.isSuccess, isTrue);
    expect(result.channels, hasLength(1));
    expect(receivedHeaders['user-agent'], contains('StreamBox'));
    service.dispose();
  });
}
