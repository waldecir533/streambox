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
  bool _confirmed = false;
  double _volume = .5;
  String? _message;
  Timer? _stateTimer;
  String? _diagnosisResult;
  bool _diagnosing = false;

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
      _confirmed = true;
      _message = 'Transmitindo para ${device.name}. Reprodução confirmada pela TV.';
      _startStatePolling();
    });
  }

  /// Diagnóstico de rede: testa se a URL que será entregue à TV é
  /// realmente alcançável pelo próprio celular (mesmo caminho da TV).
  Future<void> _diagnose() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _diagnosing = true;
      _diagnosisResult = null;
    });
    try {
      final proxy = _dlna.proxy;
      final announced = await proxy.urlFor(_channel);
      final reachable = await proxy.testUrl(announced);
      if (mounted) {
        setState(() {
          _diagnosing = false;
          _diagnosisResult = reachable
              ? '✓ Servidor OK (${proxy.advertisedHost}:${proxy.port}) — a URL '
                  '${announced.host}:${announced.port} é alcançável. '
                  'Se a TV ainda exibir erro, veja se ela está na MESMA rede Wi-Fi '
                  'do celular (mesmo roteador) e repita a transmissão.'
              : '✗ URL INALCANÇÁVEL — http://${proxy.advertisedHost}:${proxy.port} '
                  'não respondeu. Causa provável: celular e TV em redes '
                  'diferentes (dados móveis/VPN/Wi-Fi Direct), roteador com '
                  'isolamento de AP ou firewall Android bloqueando o app. '
                  'Desative VPN/VPN privada do Android e repita.';
        });
      }
    } on DlnaProxyException catch (error) {
      if (mounted) {
        setState(() {
          _diagnosing = false;
          _diagnosisResult = '✗ ${error.message}';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _diagnosing = false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Consulta `GetTransportInfo`/`GetPositionInfo` periodicamente para
  /// detectar quando a TV para de reproduzir (travamento/tela preta) e
  /// alertar o usuário.
  void _startStatePolling() {
    _stateTimer?.cancel();
    _stateTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkDlnaState());
  }

  Future<void> _checkDlnaState() async {
    final device = _dlnaConnected;
    if (_kind != _ConnectionKind.dlna || device == null) return;
    final state = await _dlna.playState(device);
    if (state == null) return;
    final wasPlaying = _playing;
    final isPlaying = state.isPlaying;
    if (wasPlaying && !isPlaying && mounted) {
      setState(() {
        _playing = false;
        _message = 'A TV interrompeu a reprodução. Toque em reproduzir para retomar.';
      });
    }
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
        _playing = !_playing;
      } else if (_dlnaConnected != null) {
        if (_playing) {
          await _dlna.pause(_dlnaConnected!);
          _playing = false;
        } else {
          await _dlna.setChannel(_dlnaConnected!, _channel);
          _playing = true;
          _confirmed = true;
        }
      }
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
    _stateTimer?.cancel();
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
              if (_kind == null || _kind == _ConnectionKind.dlna) _diagnosisPanel(),
              if (_kind == _ConnectionKind.dlna && _dlnaConnected != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Icon(
                        _playing && _confirmed ? Icons.check_circle : Icons.circle_outlined,
                        size: 16,
                        color: _playing && _confirmed ? Colors.green : Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _playing && _confirmed
                              ? 'Reprodução confirmada pela TV (${_dlnaConnected!.name}).'
                              : 'Aguardando confirmação da TV...',
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
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

  /// Painel de diagnóstico DLNA: endereço do servidor local, URL que a TV
  /// receberá e resultado do teste de acessibilidade.
  Widget _diagnosisPanel() {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Diagnóstico DLNA', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              'Servidor local: http://${_dlna.proxy.advertisedHost ?? "…"}:${_dlna.proxy.port ?? "…"}\n'
              'URL enviada à TV: ${_dlna.lastAnnouncedUrl ?? "(ainda não enviada)"}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _diagnose,
                  icon: Icon(_diagnosing ? Icons.hourglass_empty : Icons.hub),
                  label: Text(_diagnosing ? 'Testando…' : 'Testar URL da TV'),
                ),
              ],
            ),
            if (_diagnosisResult != null) ...[
              const SizedBox(height: 8),
              Text(_diagnosisResult!, style: const TextStyle(fontSize: 12)),
            ],
          ],
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
