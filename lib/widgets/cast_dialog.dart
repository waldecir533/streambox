import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../models/channel.dart';
import '../services/cast_service.dart';
import '../services/dlna_service.dart';

enum _ConnectionKind { googleCast, dlna }

class CastDialog extends StatefulWidget {
  const CastDialog({
    super.key,
    required this.channel,
    this.channels = const [],
  });

  final Channel channel;
  final List<Channel> channels;

  @override
  State<CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends State<CastDialog> {
  final _dlna = DlnaService();
  StreamSubscription<List<DlnaDevice>>? _dlnaSubscription;
  List<DlnaDevice> _dlnaDevices = const [];
  DlnaDevice? _dlnaConnected;
  _ConnectionKind? _kind;
  late Channel _channel;
  bool _busy = false;
  bool _discovering = true;
  bool _playing = true;
  double _volume = .5;
  String? _message;

  @override
  void initState() {
    super.initState();
    _channel = widget.channel;
    _dlnaSubscription = _dlna.devices.listen((devices) {
      if (mounted) setState(() => _dlnaDevices = devices);
    });
    _discover();
  }

  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _message = null;
    });
    CastService.startDiscovery();
    try {
      await _dlna.discover();
    } on DlnaException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Não foi possível procurar TVs nesta rede.');
      }
    }
    await Future<void>.delayed(const Duration(seconds: 5));
    if (mounted) setState(() => _discovering = false);
  }

  Future<void> _connectCast(GoogleCastDevice device) async {
    await _runRemoteAction(() async {
      await CastService.cast(_channel, device);
      _kind = _ConnectionKind.googleCast;
      _message = 'Transmitindo para ${device.friendlyName}.';
    });
  }

  Future<void> _connectDlna(DlnaDevice device) async {
    await _runRemoteAction(() async {
      await _dlna.connect(device, _channel);
      _dlnaConnected = device;
      _kind = _ConnectionKind.dlna;
      _message = 'Transmitindo para ${device.name}.';
    });
  }

  Future<void> _runRemoteAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on DlnaException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = 'A TV não aceitou este canal. A reprodução continua no celular.';
          _kind = null;
          _dlnaConnected = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePlayback() async {
    await _runRemoteAction(() async {
      if (_kind == _ConnectionKind.googleCast) {
        _playing ? await CastService.pause() : await CastService.play();
      } else if (_dlnaConnected != null) {
        _playing
            ? await _dlna.pause(_dlnaConnected!)
            : await _dlna.play(_dlnaConnected!);
      }
      _playing = !_playing;
    });
  }

  Future<void> _changeChannel(Channel channel) async {
    await _runRemoteAction(() async {
      if (_kind == _ConnectionKind.googleCast) {
        await CastService.cast(channel, null);
      } else if (_dlnaConnected != null) {
        await _dlna.setChannel(_dlnaConnected!, channel);
      }
      _channel = channel;
      _playing = true;
      _message = 'Canal alterado para ${channel.name}.';
    });
  }

  Future<void> _setVolume(double value) async {
    setState(() => _volume = value);
    try {
      if (_kind == _ConnectionKind.googleCast) {
        GoogleCastSessionManager.instance.setDeviceVolume(value);
      } else if (_dlnaConnected != null) {
        await _dlna.setVolume(_dlnaConnected!, value);
      }
    } on DlnaException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) setState(() => _message = 'Não foi possível alterar o volume da TV.');
    }
  }

  Future<void> _disconnect() async {
    await _runRemoteAction(() async {
      if (_kind == _ConnectionKind.googleCast) await CastService.disconnect();
      if (_kind == _ConnectionKind.dlna) await _dlna.disconnect();
      _kind = null;
      _dlnaConnected = null;
      _message = 'TV desconectada. A reprodução continua no celular.';
    });
  }

  @override
  void dispose() {
    _dlnaSubscription?.cancel();
    _dlna.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
          title: const Text('Transmitir para TV'),
          actions: [
            IconButton(
              onPressed: _busy ? null : _discover,
              tooltip: 'Procurar novamente',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_busy || _discovering) const LinearProgressIndicator(),
              if (_message != null)
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(_message!),
                  ),
                ),
              if (_kind != null) _remoteControls(),
              const Padding(
                padding: EdgeInsets.only(top: 20, bottom: 8),
                child: Text('Google Cast / Chromecast', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              StreamBuilder<List<GoogleCastDevice>>(
                stream: CastService.devices,
                builder: (context, snapshot) {
                  final devices = snapshot.data ?? const <GoogleCastDevice>[];
                  if (devices.isEmpty) {
                    return const ListTile(
                      leading: Icon(Icons.cast),
                      title: Text('Nenhum Chromecast encontrado'),
                      subtitle: Text('Confirme que o celular e a TV estão na mesma rede Wi-Fi.'),
                    );
                  }
                  return Column(
                    children: [
                      for (final device in devices)
                        ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.cast)),
                          title: Text(device.friendlyName),
                          subtitle: Text(device.modelName ?? 'Google Cast'),
                          enabled: !_busy,
                          onTap: () => _connectCast(device),
                        ),
                    ],
                  );
                },
              ),
              const Padding(
                padding: EdgeInsets.only(top: 20, bottom: 8),
                child: Text('Smart TVs (DLNA)', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              if (_dlnaDevices.isEmpty)
                const ListTile(
                  leading: Icon(Icons.tv),
                  title: Text('Nenhuma Smart TV DLNA encontrada'),
                  subtitle: Text('Ative DLNA/UPnP na TV e mantenha os aparelhos na mesma rede.'),
                ),
              for (final device in _dlnaDevices)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.tv)),
                  title: Text(device.name),
                  subtitle: Text(device.model ?? 'Reprodutor DLNA/UPnP'),
                  enabled: !_busy,
                  onTap: () => _connectDlna(device),
                ),
              const Divider(height: 32),
              ListTile(
                leading: const Icon(Icons.screen_share),
                title: const Text('Espelhar a tela do celular'),
                subtitle: const Text('Alternativa para formatos não aceitos pela TV'),
                onTap: CastService.openAndroidScreenMirroring,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _remoteControls() {
    final availableChannels = widget.channels.isEmpty ? [_channel] : widget.channels;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_channel.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _busy ? null : _togglePlayback,
                  tooltip: _playing ? 'Pausar na TV' : 'Reproduzir na TV',
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                ),
                Expanded(
                  child: Slider(
                    value: _volume,
                    onChanged: _busy ? null : (value) => setState(() => _volume = value),
                    onChangeEnd: _setVolume,
                  ),
                ),
                const Icon(Icons.volume_up),
                IconButton(
                  onPressed: _busy ? null : _disconnect,
                  tooltip: 'Desconectar',
                  icon: const Icon(Icons.cast_connected),
                ),
              ],
            ),
            DropdownButtonFormField<Channel>(
              initialValue: availableChannels.contains(_channel) ? _channel : null,
              decoration: const InputDecoration(labelText: 'Trocar canal'),
              items: availableChannels
                  .map((channel) => DropdownMenuItem(value: channel, child: Text(channel.name)))
                  .toList(),
              onChanged: _busy ? null : (channel) {
                if (channel != null) _changeChannel(channel);
              },
            ),
          ],
        ),
      ),
    );
  }
}
