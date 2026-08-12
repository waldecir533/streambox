import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:streambox/models/channel.dart';
import 'package:streambox/services/dlna_service.dart';

void main() {
  const channel = Channel(
    name: 'Canal teste',
    url: 'https://example.com/live.m3u8',
  );
  final device = DlnaDevice(
    id: 'uuid:samsung-tv',
    name: 'Samsung TV',
    location: Uri.parse('http://192.168.1.10:9197/description.xml'),
    avTransportControlUrl: Uri.parse('http://192.168.1.10:9197/AVTransport/control'),
  );

  test('uses UPnP AVTransport SetAVTransportURI followed by Play', () async {
    final actions = <String>[];
    final client = MockClient((request) async {
      actions.add(request.headers['soapaction'] ?? '');
      if (actions.length == 1) {
        expect(request.body, contains('SetAVTransportURI'));
        expect(request.body, contains('https://example.com/live.m3u8'));
      }
      return http.Response('', 200);
    });
    final service = DlnaService(client: client);

    await service.connect(device, channel);

    expect(actions, [
      '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
      '"urn:schemas-upnp-org:service:AVTransport:1#Play"',
    ]);
    await service.dispose();
  });

  test('returns friendly connection error when Samsung TV times out', () async {
    final client = MockClient((_) => Completer<http.Response>().future);
    final service = DlnaService(
      client: client,
      connectionTimeout: const Duration(milliseconds: 1),
    );

    await expectLater(
      service.connect(device, channel),
      throwsA(
        isA<DlnaException>().having(
          (error) => error.message,
          'message',
          'Não foi possível conectar à TV',
        ),
      ),
    );
    await service.dispose();
  });
}
