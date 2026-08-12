import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/channel.dart';
import 'stream_proxy_service.dart';

class DlnaDevice {
  const DlnaDevice({
    required this.id,
    required this.name,
    required this.location,
    required this.avTransportControlUrl,
    this.renderingControlUrl,
    this.model,
  });

  final String id;
  final String name;
  final String? model;
  final Uri location;
  final Uri avTransportControlUrl;
  final Uri? renderingControlUrl;
}

class DlnaException implements Exception {
  const DlnaException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DlnaService {
  DlnaService({
    http.Client? client,
    this.searchTimeout = const Duration(seconds: 6),
    this.connectionTimeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  static const _searchTarget = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  final http.Client _client;
  final Duration searchTimeout;
  final Duration connectionTimeout;
  final _devicesController = StreamController<List<DlnaDevice>>.broadcast();
  final Map<String, DlnaDevice> _devices = {};
  final StreamProxyService _proxy = StreamProxyService();
  RawDatagramSocket? _socket;
  Timer? _finishTimer;
  Completer<void>? _discoveryCompleter;
  int _discoveryGeneration = 0;
  bool _disposed = false;
  DlnaDevice? connectedDevice;

  Stream<List<DlnaDevice>> get devices => _devicesController.stream;

  Future<void> discover({Duration? duration}) async {
    await stopDiscovery();
    if (_disposed) return;
    final generation = ++_discoveryGeneration;
    final completion = Completer<void>();
    _discoveryCompleter = completion;
    _devices.clear();
    _devicesController.add(const []);
    developer.log('Iniciando descoberta SSDP/UPnP', name: 'StreamBox.DLNA');
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket = socket;
      socket.broadcastEnabled = true;
      socket.listen(
        (event) => _onSocketEvent(event, generation),
        onError: (Object error) {
          developer.log('Erro no socket SSDP', name: 'StreamBox.DLNA', error: error);
          stopDiscovery();
        },
      );
      final request = [
        'M-SEARCH * HTTP/1.1',
        'HOST: 239.255.255.250:1900',
        'MAN: "ssdp:discover"',
        'MX: 3',
        'ST: $_searchTarget',
        '',
        '',
      ].join('\r\n');
      socket.send(
        utf8.encode(request),
        InternetAddress('239.255.255.250'),
        1900,
      );
      _finishTimer = Timer(duration ?? searchTimeout, stopDiscovery);
      await completion.future;
    } on SocketException {
      await stopDiscovery();
      throw const DlnaException(
        'Não foi possível conectar à TV',
      );
    }
  }

  Future<void> _onSocketEvent(RawSocketEvent event, int generation) async {
    if (event != RawSocketEvent.read || generation != _discoveryGeneration || _disposed) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    final response = utf8.decode(datagram.data, allowMalformed: true);
    final headers = _parseHeaders(response);
    final rawLocation = headers['location'];
    if (rawLocation == null) return;
    final location = Uri.tryParse(rawLocation);
    if (location == null || _devices.containsKey(location.toString())) return;
    try {
      final device = await _loadDescription(location);
      if (device != null && generation == _discoveryGeneration && !_disposed) {
        _devices[device.id] = device;
        _devicesController.add(_devices.values.toList(growable: false));
        developer.log('TV DLNA encontrada: ${device.name}', name: 'StreamBox.DLNA');
      }
    } catch (error, stackTrace) {
      developer.log(
        'Descrição UPnP inválida ou inacessível',
        name: 'StreamBox.DLNA',
        error: error,
        stackTrace: stackTrace,
      );
      // Other SSDP devices may return incomplete descriptions; ignore them.
    }
  }

  Map<String, String> _parseHeaders(String response) {
    final result = <String, String>{};
    for (final line in const LineSplitter().convert(response).skip(1)) {
      final separator = line.indexOf(':');
      if (separator > 0) {
        result[line.substring(0, separator).trim().toLowerCase()] =
            line.substring(separator + 1).trim();
      }
    }
    return result;
  }

  Future<DlnaDevice?> _loadDescription(Uri location) async {
    final response = await _client.get(location).timeout(connectionTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final document = XmlDocument.parse(response.body);
    final deviceNode = document.findAllElements('device').firstOrNull;
    if (deviceNode == null) return null;
    final services = deviceNode.findAllElements('service');
    Uri? avTransport;
    Uri? rendering;
    for (final service in services) {
      final type = service.getElement('serviceType')?.innerText ?? '';
      final control = service.getElement('controlURL')?.innerText.trim();
      if (control == null || control.isEmpty) continue;
      final resolved = location.resolve(control);
      if (type.contains(':AVTransport:')) avTransport = resolved;
      if (type.contains(':RenderingControl:')) rendering = resolved;
    }
    if (avTransport == null) return null;
    return DlnaDevice(
      id: deviceNode.getElement('UDN')?.innerText.trim() ?? location.toString(),
      name: deviceNode.getElement('friendlyName')?.innerText.trim() ?? 'Smart TV',
      model: deviceNode.getElement('modelName')?.innerText.trim(),
      location: location,
      avTransportControlUrl: avTransport,
      renderingControlUrl: rendering,
    );
  }

  Future<void> connect(DlnaDevice device, Channel channel) async {
    developer.log('Conectando via AVTransport: ${device.name}', name: 'StreamBox.DLNA');
    try {
      await setChannel(device, channel).timeout(connectionTimeout);
      connectedDevice = device;
      developer.log('Conexão DLNA concluída', name: 'StreamBox.DLNA');
    } on TimeoutException {
      developer.log('Timeout na conexão DLNA', name: 'StreamBox.DLNA');
      throw const DlnaException('Não foi possível conectar à TV');
    } catch (error, stackTrace) {
      developer.log(
        'Falha na conexão DLNA',
        name: 'StreamBox.DLNA',
        error: error,
        stackTrace: stackTrace,
      );
      if (error is DlnaException) rethrow;
      throw const DlnaException('Não foi possível conectar à TV');
    }
  }

  Future<void> setChannel(DlnaDevice device, Channel channel) async {
    final remoteUrl = channel.headers.isEmpty
        ? Uri.parse(channel.url)
        : await _proxy.urlFor(channel);
    final metadata = _didlMetadata(channel, remoteUrl);
    await _soap(
      device.avTransportControlUrl,
      'urn:schemas-upnp-org:service:AVTransport:1',
      'SetAVTransportURI',
      {
        'InstanceID': '0',
        'CurrentURI': remoteUrl.toString(),
        'CurrentURIMetaData': metadata,
      },
    );
    await play(device);
  }

  Future<void> play(DlnaDevice device) => _soap(
        device.avTransportControlUrl,
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Play',
        {'InstanceID': '0', 'Speed': '1'},
      );

  Future<void> pause(DlnaDevice device) => _soap(
        device.avTransportControlUrl,
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Pause',
        {'InstanceID': '0'},
      );

  Future<void> stop(DlnaDevice device) => _soap(
        device.avTransportControlUrl,
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Stop',
        {'InstanceID': '0'},
      );

  Future<void> setVolume(DlnaDevice device, double volume) async {
    final url = device.renderingControlUrl;
    if (url == null) {
      throw const DlnaException('Esta TV não oferece controle remoto de volume.');
    }
    await _soap(
      url,
      'urn:schemas-upnp-org:service:RenderingControl:1',
      'SetVolume',
      {
        'InstanceID': '0',
        'Channel': 'Master',
        'DesiredVolume': (volume.clamp(0, 1) * 100).round().toString(),
      },
    );
  }

  Future<void> disconnect() async {
    final device = connectedDevice;
    connectedDevice = null;
    if (device != null) {
      try {
        await stop(device);
      } catch (_) {}
    }
  }

  Future<void> _soap(
    Uri url,
    String serviceType,
    String action,
    Map<String, String> arguments,
  ) async {
    final body = StringBuffer(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$serviceType">',
    );
    arguments.forEach((key, value) {
      body.write('<$key>${_xmlEscape(value)}</$key>');
    });
    body.write('</u:$action></s:Body></s:Envelope>');
    try {
      final response = await _client.post(
        url,
        headers: {
          HttpHeaders.contentTypeHeader: 'text/xml; charset="utf-8"',
          'SOAPACTION': '"$serviceType#$action"',
        },
        body: body.toString(),
      ).timeout(connectionTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const DlnaException(
          'Não foi possível conectar à TV',
        );
      }
    } on TimeoutException {
      throw const DlnaException(
        'Não foi possível conectar à TV',
      );
    } on SocketException {
      throw const DlnaException(
        'Não foi possível conectar à TV',
      );
    }
  }

  String _didlMetadata(Channel channel, Uri remoteUrl) {
    final protocol = channel.url.toLowerCase().contains('.m3u8')
        ? 'application/vnd.apple.mpegurl'
        : 'video/mp4';
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="0" restricted="1">'
        '<dc:title>${_xmlEscape(channel.name)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:$protocol:*">${_xmlEscape(remoteUrl.toString())}</res>'
        '</item></DIDL-Lite>';
  }

  String _xmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<void> stopDiscovery() async {
    _discoveryGeneration++;
    _finishTimer?.cancel();
    _finishTimer = null;
    _socket?.close();
    _socket = null;
    final completion = _discoveryCompleter;
    _discoveryCompleter = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    developer.log('Descoberta SSDP encerrada', name: 'StreamBox.DLNA');
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopDiscovery();
    await _devicesController.close();
    await _proxy.dispose();
    _client.close();
  }
}
