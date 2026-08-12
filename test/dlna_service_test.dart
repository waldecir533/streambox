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
        expect(request.body, contains('&lt;DIDL-Lite'));
        expect(request.body, contains('object.item.videoItem.movie'));
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

  test('DLNA diagnostic reports every accepted stage using public MP4',
      () async {
    final actions = <String>[];
    final stages = <DlnaTestStage>[];
    final client = MockClient((request) async {
      actions.add(request.headers['soapaction'] ?? '');
      expect(request.headers['authorization'], isNull);
      expect(request.body, isNot(contains('Bearer')));
      if (actions.length == 1) {
        expect(request.body, contains('SetAVTransportURI'));
        expect(request.body, contains('media.w3.org'));
        expect(request.body, contains('video/mp4'));
      }
      return http.Response('', 200);
    });
    final service = DlnaService(client: client);

    await service.testPublicVideo(device, onStage: stages.add);

    expect(stages, DlnaTestStage.values);
    expect(actions, [
      '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
      '"urn:schemas-upnp-org:service:AVTransport:1#Play"',
    ]);
    expect(service.connectedDevice, device);
    await service.dispose();
  });

  test('uses AVTransport service type and controlURL advertised by Samsung', () async {
    final service = DlnaService();
    const description = '''
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <URLBase>http://192.168.1.55:9197/base/</URLBase>
  <device>
    <friendlyName>Samsung AU7700</friendlyName>
    <manufacturer>Samsung Electronics</manufacturer>
    <modelName>UA50AU7700</modelName>
    <UDN>uuid:samsung-au7700</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/upnp/control/AVTransport2</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>connection/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

    final parsed = service.parseDeviceDescription(
      Uri.parse('http://192.168.1.55:9197/description.xml'),
      description,
    );

    expect(parsed, isNotNull);
    expect(parsed!.brand, TvBrand.samsung);
    expect(parsed.avTransportServiceType,
        'urn:schemas-upnp-org:service:AVTransport:2');
    expect(parsed.avTransportControlUrl.toString(),
        'http://192.168.1.55:9197/upnp/control/AVTransport2');
    expect(parsed.connectionManagerControlUrl.toString(),
        'http://192.168.1.55:9197/base/connection/control');
    await service.dispose();
  });

  test('selects embedded MediaRenderer and services advertised by any vendor',
      () async {
    final service = DlnaService();
    const description = '''
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>LG webOS Root</friendlyName>
    <manufacturer>LG Electronics</manufacturer>
    <deviceList>
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:2</deviceType>
        <friendlyName>TV da sala</friendlyName>
        <manufacturer>LG Electronics</manufacturer>
        <modelName>webOS TV</modelName>
        <UDN>uuid:generic-renderer</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>/control/avt1</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:3</serviceType>
            <controlURL>/control/avt3</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:2</serviceType>
            <controlURL>/control/rendering</controlURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:ConnectionManager:2</serviceType>
            <controlURL>/control/connection</controlURL>
          </service>
        </serviceList>
      </device>
    </deviceList>
  </device>
</root>
''';

    final parsed = service.parseDeviceDescription(
      Uri.parse('http://192.168.1.80:1400/device.xml'),
      description,
    );

    expect(parsed, isNotNull);
    expect(parsed!.id, 'uuid:generic-renderer');
    expect(parsed.name, 'TV da sala');
    expect(parsed.brand, TvBrand.lg);
    expect(parsed.avTransportServiceType,
        'urn:schemas-upnp-org:service:AVTransport:3');
    expect(parsed.avTransportControlUrl.toString(),
        'http://192.168.1.80:1400/control/avt3');
    expect(parsed.renderingControlServiceType,
        'urn:schemas-upnp-org:service:RenderingControl:2');
    expect(parsed.supportsVolume, isTrue);
    expect(parsed.connectionManagerServiceType,
        'urn:schemas-upnp-org:service:ConnectionManager:2');
    await service.dispose();
  });

  test('reports authorization error separately from connection failure', () async {
    final client = MockClient((_) async => http.Response('<error>denied</error>', 403));
    final service = DlnaService(client: client);

    await expectLater(
      service.connect(device, channel),
      throwsA(
        isA<DlnaException>()
            .having((error) => error.kind, 'kind', DlnaErrorKind.authorization)
            .having((error) => error.message, 'message', contains('autorização')),
      ),
    );
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

  test('checks ConnectionManager before sending an incompatible stream', () async {
    final client = MockClient((request) async {
      if ((request.headers['soapaction'] ?? '').contains('GetProtocolInfo')) {
        return http.Response(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><u:GetProtocolInfoResponse '
          'xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">'
          '<Source></Source><Sink>http-get:*:video/mp4:*</Sink>'
          '</u:GetProtocolInfoResponse></s:Body></s:Envelope>',
          200,
        );
      }
      fail('AVTransport must not be called for an incompatible protocol');
    });
    final service = DlnaService(client: client);
    final deviceWithCapabilities = DlnaDevice(
      id: device.id,
      name: device.name,
      location: device.location,
      avTransportControlUrl: device.avTransportControlUrl,
      connectionManagerControlUrl:
          Uri.parse('http://192.168.1.10:9197/ConnectionManager/control'),
    );

    await expectLater(
      service.connect(deviceWithCapabilities, channel),
      throwsA(isA<DlnaException>()),
    );
    await service.dispose();
  });
}
