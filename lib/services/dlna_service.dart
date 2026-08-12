import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/channel.dart';
import 'stream_proxy_service.dart';

export 'stream_proxy_service.dart' show DlnaProxyException;

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

/// Estado de reprodução da TV obtido via `GetTransportInfo` e
/// `GetPositionInfo`.
class DlnaPlayState {
  const DlnaPlayState({
    required this.transportState,
    required this.transportStatus,
    required this.mediaDuration,
    required this.mediaPosition,
  });

  final String transportState;
  final String transportStatus;
  final String mediaDuration;
  final String mediaPosition;

  bool get isPlaying => transportState == 'PLAYING';

  /// A posição avança (RelTime/TrackDuration não está travado em "00:00:00")?
  /// Algumas TVs (Samsung incluída) entram em PLAYING mesmo quando a mídia
  /// é rejeitada; a posição avançando é a prova real da reprodução.
  bool get positionAdvancing {
    final rel = _parseRelTime(mediaPosition);
    final duration = _parseRelTime(mediaDuration);
    if (rel == null || duration == null || duration.inSeconds <= 0) {
      return true; // sem duração conhecida (ao vivo/HLS) — não há o que checar
    }
    // Considera "avançando" quando a posição já saiu do início ou chegou a
    // mais de 1% do total; posição travada em 0 com duração > 0 = problema.
    return rel.inSeconds > 0 || duration.inSeconds < 60;
  }

  static Duration? _parseRelTime(String raw) {
    final parts = raw.trim().split(':');
    if (parts.length != 3) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final s = int.tryParse(parts[2]);
    if (h == null || m == null || s == null) return null;
    return Duration(hours: h, minutes: m, seconds: s);
  }
}

class DlnaException implements Exception {
  const DlnaException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DlnaService {
  DlnaService({http.Client? client}) : _client = client ?? http.Client();

  static const _searchTarget = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  final http.Client _client;
  final _devicesController = StreamController<List<DlnaDevice>>.broadcast();
  final Map<String, DlnaDevice> _devices = {};
  final StreamProxyService _proxy = StreamProxyService();
  RawDatagramSocket? _socket;
  Timer? _finishTimer;
  DlnaDevice? connectedDevice;

  Stream<List<DlnaDevice>> get devices => _devicesController.stream;

  Future<void> discover({Duration duration = const Duration(seconds: 5)}) async {
    await stopDiscovery();
    _devices.clear();
    _devicesController.add(const []);
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket = socket;
      socket.broadcastEnabled = true;
      socket.listen(_onSocketEvent, onError: (_) => stopDiscovery());
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
      _finishTimer = Timer(duration, stopDiscovery);
    } on SocketException {
      throw const DlnaException(
        'Não foi possível procurar TVs. Confirme que o Wi-Fi está ligado.',
      );
    }
  }

  Future<void> _onSocketEvent(RawSocketEvent event) async {
    if (event != RawSocketEvent.read) return;
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
      if (device != null) {
        _devices[device.id] = device;
        _devicesController.add(_devices.values.toList(growable: false));
      }
    } catch (_) {
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
    final response = await _client.get(location).timeout(const Duration(seconds: 5));
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
    await setChannel(device, channel);
    connectedDevice = device;
  }

  /// URLs locais do proxy retransmitem o vídeo para a TV com cabeçalhos
  /// completos (HEAD, Content-Length, Content-Type e Range/206), sem os
  /// quais TVs Samsung (ex.: AU7700) aceitam o comando mas não reproduzem.
  /// URL anunciada à TV na última chamada de `setChannel` (para diagnóstico).
  Uri? lastAnnouncedUrl;

  /// Servidor local usado (para diagnóstico de rede/IP/porta).
  StreamProxyService get proxy => _proxy;

  Future<void> setChannel(DlnaDevice device, Channel channel) async {
    // O proxy local sempre é usado: além de retransmitir os cabeçalhos do
    // canal, ele garante HEAD/Content-Length/Content-Type e Range/206 que
    // a TV exige.
    final remoteUrl = await _proxy.urlFor(channel);
    lastAnnouncedUrl = remoteUrl;
    // Antes de enviar à TV, verifica se a URL é realmente alcançável —
    // exatamente o que a TV fará. Se a TV não consegue acessar o servidor
    // do celular (rede diferente, Wi-Fi Direct, VPN, firewall Android),
    // o erro é claro em vez de "a TV exibe erro e não toca".
    final reachable = await _proxy.testUrl(remoteUrl);
    if (!reachable) {
      throw DlnaException(
        'O servidor do celular (http://${_proxy.advertisedHost}:${_proxy.port}) '
        'não respondeu à própria URL. Possíveis causas: celular conectado em '
        'outra rede que a TV (VPN, Wi-Fi Direct, dados móveis); app bloqueado '
        'pelo firewall Android (Configurações → Apps → StreamBox → Permitir '
        'acesso a dados em segundo plano / desativar “Restringir dados em '
        'background"); ou TV em rede 2,4/5 GHz isolada pelo roteador '
        '(desative AP Isolation). Repita a reprodução.',
      );
    }
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
    // Confirma que a TV iniciou a reprodução antes de considerar conectado.
    await _waitForPlaying(device);
  }

  Future<void> play(DlnaDevice device) => _soap(
        device.avTransportControlUrl,
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Play',
        {'InstanceID': '0', 'Speed': '1'},
      );

  /// Confirma a reprodução consultando `GetTransportInfo` e
  /// `GetPositionInfo` da TV. Retorna o estado e a posição atuais, ou
  /// `null` se a TV não responder às consultas.
  Future<DlnaPlayState?> playState(DlnaDevice device) async {
    try {
      final transport = await _soapQuery(
        device.avTransportControlUrl,
        'urn:schemas-upnp-org:service:AVTransport:1',
        'GetTransportInfo',
        {'InstanceID': '0'},
      );
      final position = await _soapQuery(
        device.avTransportControlUrl,
        'urn:schemas-upnp-org:service:AVTransport:1',
        'GetPositionInfo',
        {'InstanceID': '0'},
      );
      if (transport == null) return null;
      return DlnaPlayState(
        transportState: transport['CurrentTransportState'] ?? '',
        transportStatus: transport['CurrentTransportStatus'] ?? '',
        mediaDuration: position?['TrackDuration'] ?? '',
        mediaPosition: position?['RelTime'] ?? position?['AbsTime'] ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Aguarda até a TV sair de `STOPPED`/`NO_MEDIA_PRESENT` e entrar em
  /// `PLAYING`, ou até o tempo esgotar, evitando "tela preta" silenciosa.
  Future<void> _waitForPlaying(
    DlnaDevice device, {
    Duration timeout = const Duration(seconds: 25),
    Duration poll = const Duration(milliseconds: 800),
  }) async {
    final started = DateTime.now();
    while (DateTime.now().difference(started) < timeout) {
      await Future<void>.delayed(poll);
      final state = await playState(device);
      if (state == null) {
        throw const DlnaException(
          'A TV não respondeu à consulta de estado. Verifique a conexão.',
        );
      }
      if (state.transportState == 'PLAYING') {
        // PLAYING sozinho não basta para Samsung: confirma que a posição
        // também está avançando (se travar em 00:00:00, a TV rejeitou a
        // mídia e vai exibir erro em instantes).
        final waited = DateTime.now().difference(started);
        if (!state.positionAdvancing && waited > const Duration(seconds: 6)) {
          await play(device);
          continue;
        }
        return;
      }
      if (state.transportState == 'STOPPED' ||
          state.transportState == 'NO_MEDIA_PRESENT') {
        await play(device);
        continue;
      }
      if (state.transportState == 'TRANSITIONING') continue;
    }
    throw const DlnaException(
      'A TV não iniciou a reprodução a tempo. O formato pode não ser compatível.',
    );
  }

  Future<Map<String, String>?> _soapQuery(
    Uri url,
    String serviceType,
    String action,
    Map<String, String> arguments,
  ) {
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
    final xml = body.toString();
    return _client
        .post(
          url,
          headers: {
            HttpHeaders.contentTypeHeader: 'text/xml; charset="utf-8"',
            'SOAPACTION': '"$serviceType#$action"',
          },
          body: xml,
        )
        .timeout(const Duration(seconds: 8))
        .then((response) {
          if (response.statusCode < 200 || response.statusCode >= 300) {
            return null;
          }
          final parsed = <String, String>{};
          final document = XmlDocument.parse(response.body);
          for (final element in document.findAllElements('*')) {
            if (element.name.namespaceUri == 'http://schemas.xmlsoap.org/soap/envelope/') {
              continue;
            }
            parsed[element.name.local] = element.innerText;
          }
          return parsed;
        })
        .timeout(const Duration(seconds: 10), onTimeout: () => null)
        .catchError((_) => null);
  }

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
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const DlnaException(
          'A TV não aceitou este canal ou formato. A reprodução continuará no celular.',
        );
      }
    } on TimeoutException {
      throw const DlnaException(
        'A TV parou de responder. A reprodução continuará no celular.',
      );
    } on SocketException {
      throw const DlnaException(
        'A conexão com a TV foi perdida. A reprodução continuará no celular.',
      );
    }
  }

  String _didlMetadata(Channel channel, Uri remoteUrl) {
    // O `protocolInfo` acompanha o Content-Type que o proxy realmente
    // serve (mp4 → video/mp4; m3u8 → mpegurl etc.). TVs Samsung e LG são
    // exigentes: protocolInfo diferente do Content-Type real causa
    // recusa da mídia. Flags: OP=01 (play), CI=0 (sem conversão), e os
    // flags padrão de streaming que a Samsung espera.
    final protocol = _protocolFor(channel.url);
    return '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>${_xmlEscape(channel.name)}</dc:title>'
        '<dc:date>1970-01-01T00:00:00</dc:date>'
        '<upnp:class>object.item.videoItem.movie</upnp:class>'
        '<res protocolInfo="http-get:*:$protocol:DLNA.ORG_PN=_;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000">${_xmlEscape(remoteUrl.toString())}</res>'
        '</item></DIDL-Lite>';
  }

  String _protocolFor(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('mpegurl')) {
      return 'application/vnd.apple.mpegurl';
    }
    if (lower.contains('.ts') && lower.contains('.m3u')) {
      return 'video/mp2t';
    }
    if (lower.contains('.mkv')) return 'video/x-matroska';
    if (lower.contains('.webm')) return 'video/webm';
    return 'video/mp4';
  }


  String _xmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<void> stopDiscovery() async {
    _finishTimer?.cancel();
    _finishTimer = null;
    _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    await stopDiscovery();
    await _devicesController.close();
    await _proxy.dispose();
    _client.close();
  }
}
