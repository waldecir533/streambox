import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:streambox/models/channel.dart';
import 'package:streambox/services/tv_stream_resolver.dart';

void main() {
  test('uses authenticated HTTPS backend without exposing stream credentials', () async {
    final client = MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer backend-session');
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['headers'], {'Authorization': 'Bearer channel-secret'});
      return http.Response(
        jsonEncode({'url': 'https://proxy.example.com/opaque/abc123'}),
        200,
      );
    });
    final resolver = TvStreamResolver(
      client: client,
      backendUrl: 'https://proxy.example.com/session',
      backendToken: 'backend-session',
    );
    const channel = Channel(
      name: 'Protegido',
      url: 'https://origin.example.com/live.m3u8?token=origin-secret',
      headers: {'Authorization': 'Bearer channel-secret'},
    );

    final resolved = await resolver.resolve(channel);

    expect(resolved.toString(), 'https://proxy.example.com/opaque/abc123');
    expect(resolved.toString(), isNot(contains('origin-secret')));
    expect(resolved.toString(), isNot(contains('channel-secret')));
    await resolver.dispose();
  });
}
