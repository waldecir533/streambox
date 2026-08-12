import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../models/channel.dart';
import '../services/cast_service.dart';
import '../services/dlna_service.dart';
import '../services/tv_stream_resolver.dart';

enum _ConnectionKind { googleCast, dlna }

class _TvTarget {
  const _TvTarget.cast(this.castDevice) : dlnaDevice = null;
  const _TvTarget.dlna(this.dlnaDevice) : castDevice = null;

  final GoogleCastDevice? castDevice;
  final DlnaDevice? dlnaDevice;
}

class CastDialog extends StatefulWidget {
  const CastDialog({
    super.key,
    required this.channel,
    this.channels = const [],
    this.onConnectionStarted,
    this.onConnectionFailed,
  });

  final Channel channel;
  final List<Channel> channels;
  final VoidCallback? onConnectionStarted;
  final VoidCallback? onConnectionFailed;

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
  int _operationGeneration = 0;
  Timer? _positionTimer;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  DlnaDevice? _testDevice;
  final Set<DlnaTestStage> _testStages = {};
  bool _testRunning = false;
  bool _testFinished = false;

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
    if (!mounted || _busy) return;
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
    if (mounted) setState(() => _discovering = false);
  }

  Future<void> _connectCast(GoogleCastDevice device) async {
    widget.onConnectionStarted?.call();
    await _runRemoteAction(() async {
      await CastService.cast(_channel, device);
      _kind = _ConnectionKind.googleCast;
      _message = 'Transmitindo para ${device.friendlyName}.';
      _startPositionPolling();
    });
  }

  Future<void> _connectDlna(DlnaDevice device) async {
    widget.onConnectionStarted?.call();
    await _runRemoteAction(() async {
      await _dlna.connect(device, _channel);
      _dlnaConnected = device;
      _kind = _ConnectionKind.dlna;
      _message = 'Transmitindo para ${device.name}.';
      _startPositionPolling();
    });
  }

  Future<void> _testDlna(DlnaDevice device) async {
    if (_busy || _testRunning) return;
    widget.onConnectionStarted?.call();
    setState(() {
      _testDevice = device;
      _testStages.clear();
      _testRunning = true;
      _testFinished = false;
    });
    await _runRemoteAction(() async {
      await _dlna.testPublicVideo(
        device,
        onStage: (stage) {
          if (mounted) setState(() => _testStages.add(stage));
        },
      );
      _dlnaConnected = device;
      _kind = _ConnectionKind.dlna;
      _playing = true;
      _message = 'Teste DLNA concluído. O vídeo público está na TV.';
    });
    if (mounted) {
      setState(() {
        _testRunning = false;
        _testFinished = true;
      });
    }
  }

  Future<void> _runRemoteAction(Future<void> Function() action) async {
    if (_busy) return;
    final generation = ++_operationGeneration;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (generation != _operationGeneration) {
        if (_kind == _ConnectionKind.googleCast) await CastService.disconnect();
        if (_kind == _ConnectionKind.dlna) await _dlna.disconnect();
        _kind = null;
        _dlnaConnected = null;
        return;
      }
    } on DlnaException catch (error) {
      developer.log('Falha na operação com TV', name: 'StreamBox.Cast', error: error);
      if (mounted) {
        setState(() {
          _message = error.message;
          _kind = null;
          _dlnaConnected = null;
        });
      }
      widget.onConnectionFailed?.call();
    } on TvStreamException catch (error) {
      developer.log(
        'Falha ao preparar stream remoto',
        name: 'StreamBox.Cast',
        error: error,
      );
      if (mounted) {
        setState(() {
          _message = error.message;
          _kind = null;
          _dlnaConnected = null;
        });
      }
      widget.onConnectionFailed?.call();
    } on FormatException catch (error) {
      developer.log(
        'Formato de stream incompatível',
        name: 'StreamBox.Cast',
        error: error,
      );
      if (mounted) {
        setState(() {
          _message =
              'A TV não aceita o formato ou codec deste canal. A reprodução continua no celular.';
          _kind = null;
          _dlnaConnected = null;
        });
      }
      widget.onConnectionFailed?.call();
    } catch (error, stackTrace) {
      developer.log(
        'Falha inesperada na transmissão',
        name: 'StreamBox.Cast',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _message = 'Não foi possível conectar à TV';
          _kind = null;
          _dlnaConnected = null;
        });
      }
      widget.onConnectionFailed?.call();
    } finally {
      if (mounted && generation == _operationGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _cancelOperation() async {
    _operationGeneration++;
    CastService.stopDiscovery();
    await _dlna.stopDiscovery();
    if (mounted) {
      setState(() {
        _busy = false;
        _discovering = false;
        _testRunning = false;
        _testFinished = _testDevice != null;
        _message = 'Conexão cancelada.';
        _kind = null;
        _dlnaConnected = null;
      });
    }
    widget.onConnectionFailed?.call();
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

  void _startPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || _kind == null || _busy) return;
      try {
        if (_kind == _ConnectionKind.googleCast) {
          setState(() {
            _position = CastService.position;
            _duration = CastService.duration;
          });
        } else if (_dlnaConnected != null) {
          final info = await _dlna.position(_dlnaConnected!);
          if (mounted) {
            setState(() {
              _position = info.position;
              _duration = info.duration;
            });
          }
        }
      } catch (error) {
        developer.log('Falha ao consultar posição', name: 'StreamBox.Cast', error: error);
      }
    });
  }

  Future<void> _seek(double milliseconds) async {
    final position = Duration(milliseconds: milliseconds.round());
    await _runRemoteAction(() async {
      if (_kind == _ConnectionKind.googleCast) await CastService.seek(position);
      if (_kind == _ConnectionKind.dlna && _dlnaConnected != null) {
        await _dlna.seek(_dlnaConnected!, position);
      }
      _position = position;
    });
  }

  Future<void> _stopRemote() async {
    await _runRemoteAction(() async {
      if (_kind == _ConnectionKind.googleCast) await CastService.stop();
      if (_kind == _ConnectionKind.dlna && _dlnaConnected != null) {
        await _dlna.stop(_dlnaConnected!);
      }
      _playing = false;
      _position = Duration.zero;
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
      _positionTimer?.cancel();
    });
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _dlnaSubscription?.cancel();
    unawaited(_dlna.dispose());
    super.dispose();
  }

  Future<void> _close() async {
    _positionTimer?.cancel();
    _operationGeneration++;
    CastService.stopDiscovery();
    await _dlna.stopDiscovery();
    if (_kind == _ConnectionKind.googleCast) {
      try {
        await CastService.disconnect();
      } catch (_) {}
    }
    if (_kind == _ConnectionKind.dlna) {
      await _dlna.disconnect();
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Dialog.fullscreen(
        child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: _close,
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
              if (_busy)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _cancelOperation,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancelar conexão'),
                  ),
                ),
              if (_discovering)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      await _dlna.stopDiscovery();
                      if (mounted) setState(() => _discovering = false);
                    },
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancelar busca'),
                  ),
                ),
              if (_message != null)
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(_message!),
                  ),
                ),
              if (_testDevice != null) _dlnaTestStatus(),
              if (_kind != null) _remoteControls(),
              const Padding(
                padding: EdgeInsets.only(top: 20, bottom: 8),
                child: Text(
                  'Dispositivos disponíveis',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              StreamBuilder<List<GoogleCastDevice>>(
                stream: CastService.devices,
                builder: (context, snapshot) {
                  final targets = <_TvTarget>[
                    ...?snapshot.data?.map(_TvTarget.cast),
                    ..._dlnaDevices.map(_TvTarget.dlna),
                  ]..sort((left, right) {
                      final leftName = left.castDevice?.friendlyName ??
                          left.dlnaDevice?.name ??
                          '';
                      final rightName = right.castDevice?.friendlyName ??
                          right.dlnaDevice?.name ??
                          '';
                      return leftName.toLowerCase().compareTo(
                            rightName.toLowerCase(),
                          );
                    });
                  if (targets.isEmpty) {
                    return const ListTile(
                      leading: Icon(Icons.tv_off_outlined),
                      title: Text('Nenhuma TV compatível encontrada'),
                      subtitle: Text(
                        'Confirme que a TV e o celular estão na mesma rede Wi-Fi e que DLNA/UPnP ou Google Cast está ativo.',
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final target in targets)
                        ListTile(
                          leading: CircleAvatar(
                            child: Icon(
                              target.castDevice != null ? Icons.cast : Icons.tv,
                            ),
                          ),
                          title: Text(
                            target.castDevice?.friendlyName ??
                                target.dlnaDevice!.name,
                          ),
                          subtitle: Text(
                            target.castDevice != null
                                ? 'Google Cast • ${target.castDevice!.modelName ?? 'Chromecast'}'
                                : 'DLNA/UPnP • ${_brandName(target.dlnaDevice!.brand)} • ${target.dlnaDevice!.model ?? 'MediaRenderer'}',
                          ),
                          enabled: !_busy,
                          onTap: () => target.castDevice != null
                              ? _connectCast(target.castDevice!)
                              : _connectDlna(target.dlnaDevice!),
                          trailing: target.dlnaDevice == null
                              ? null
                              : TextButton(
                                  onPressed: _busy || _testRunning
                                      ? null
                                      : () => _testDlna(target.dlnaDevice!),
                                  child: const Text('Teste DLNA'),
                                ),
                        ),
                    ],
                  );
                },
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
                IconButton(
                  onPressed: _busy ? null : _stopRemote,
                  tooltip: 'Parar na TV',
                  icon: const Icon(Icons.stop),
                ),
                Expanded(
                  child: Slider(
                    value: _volume,
                    onChanged: _busy ||
                            (_kind == _ConnectionKind.dlna &&
                                !(_dlnaConnected?.supportsVolume ?? false))
                        ? null
                        : (value) => setState(() => _volume = value),
                    onChangeEnd: _busy ||
                            (_kind == _ConnectionKind.dlna &&
                                !(_dlnaConnected?.supportsVolume ?? false))
                        ? null
                        : _setVolume,
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
            if (_duration > Duration.zero)
              Slider(
                value: _position.inMilliseconds
                    .clamp(0, _duration.inMilliseconds)
                    .toDouble(),
                max: _duration.inMilliseconds.toDouble(),
                onChanged: _busy ? null : (value) => setState(
                  () => _position = Duration(milliseconds: value.round()),
                ),
                onChangeEnd: _seek,
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

  Widget _dlnaTestStatus() {
    Widget stage(DlnaTestStage value, String label) {
      final accepted = _testStages.contains(value);
      final firstMissing = DlnaTestStage.values
          .where((stage) => !_testStages.contains(stage))
          .firstOrNull;
      final failed = _testFinished && !accepted && value == firstMissing;
      final skipped = _testFinished && !accepted && !failed;
      return ListTile(
        dense: true,
        leading: Icon(
          accepted
              ? Icons.check_circle
              : failed
                  ? Icons.error_outline
                  : skipped
                      ? Icons.block
                      : Icons.pending_outlined,
          color: accepted
              ? Colors.green
              : failed
                  ? Theme.of(context).colorScheme.error
                  : null,
        ),
        title: Text(label),
        subtitle: Text(
          accepted
              ? 'Aceito'
              : failed
                  ? 'Falhou'
                  : skipped
                      ? 'Não executado'
                      : 'Aguardando',
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'Teste DLNA — ${_testDevice!.name}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            stage(DlnaTestStage.tvFound, 'TV encontrada'),
            stage(
              DlnaTestStage.setUriAccepted,
              'SetAVTransportURI aceito',
            ),
            stage(DlnaTestStage.playAccepted, 'Comando Play aceito'),
          ],
        ),
      ),
    );
  }

  String _brandName(TvBrand brand) => switch (brand) {
        TvBrand.samsung => 'Samsung',
        TvBrand.lg => 'LG',
        TvBrand.tcl => 'TCL',
        TvBrand.philco => 'Philco',
        TvBrand.sempToshiba => 'Semp/Toshiba',
        TvBrand.androidTv => 'Android TV',
        TvBrand.googleTv => 'Google TV',
        TvBrand.other => 'Smart TV',
      };
}
