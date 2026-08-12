import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import '../services/dlna_service.dart';

class DlnaTestScreen extends StatefulWidget {
  const DlnaTestScreen({super.key});

  @override
  State<DlnaTestScreen> createState() => _DlnaTestScreenState();
}

class _DlnaTestScreenState extends State<DlnaTestScreen> {
  final _dlna = DlnaService();
  StreamSubscription<List<DlnaDevice>>? _subscription;
  List<DlnaDevice> _devices = const [];
  DlnaDevice? _selectedDevice;
  final Set<DlnaTestStage> _acceptedStages = {};
  bool _searching = false;
  bool _testing = false;
  bool _testFinished = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _subscription = _dlna.devices.listen((devices) {
      if (!mounted) return;
      setState(() {
        _devices = devices;
        if (_selectedDevice != null &&
            !devices.any((device) => device.id == _selectedDevice!.id)) {
          _selectedDevice = null;
        }
      });
    });
  }

  Future<void> _search() async {
    if (_searching || _testing) return;
    setState(() {
      _searching = true;
      _message = null;
      _selectedDevice = null;
      _acceptedStages.clear();
      _testFinished = false;
    });
    try {
      await _dlna.discover();
      if (mounted && _devices.isEmpty) {
        setState(() => _message =
            'Nenhuma TV DLNA foi encontrada. Confirme que os aparelhos estão na mesma rede Wi-Fi.');
      }
    } on DlnaException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (error, stackTrace) {
      developer.log(
        'Falha na busca do teste DLNA',
        name: 'StreamBox.DLNA.Test',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _message = 'Não foi possível buscar TVs agora.');
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _playTestVideo() async {
    final device = _selectedDevice;
    if (device == null || _testing) return;
    setState(() {
      _testing = true;
      _testFinished = false;
      _acceptedStages.clear();
      _message = null;
    });
    try {
      await _dlna.testPublicVideo(
        device,
        onStage: (stage) {
          if (mounted) setState(() => _acceptedStages.add(stage));
        },
      );
      if (mounted) {
        setState(() => _message =
            'Teste concluído: o vídeo MP4 público foi enviado para a TV.');
      }
    } on DlnaException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (error, stackTrace) {
      developer.log(
        'Falha inesperada no teste DLNA',
        name: 'StreamBox.DLNA.Test',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _message = 'Não foi possível reproduzir o vídeo de teste.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
          _testFinished = true;
        });
      }
    }
  }

  Future<void> _cancel() async {
    await _dlna.stopDiscovery();
    if (mounted) setState(() => _searching = false);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_dlna.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Teste DLNA')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Este teste usa somente um vídeo MP4 público do W3C. Sua lista IPTV e suas credenciais não são utilizadas.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _searching || _testing ? null : _search,
              icon: const Icon(Icons.search),
              label: const Text('Buscar TVs'),
            ),
            if (_searching) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              TextButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancelar busca'),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_message!),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Text('TVs encontradas', style: Theme.of(context).textTheme.titleMedium),
            if (!_searching && _devices.isEmpty)
              const ListTile(
                leading: Icon(Icons.tv_off_outlined),
                title: Text('Nenhuma TV encontrada ainda'),
                subtitle: Text('Toque em “Buscar TVs” para iniciar a descoberta DLNA.'),
              ),
            for (final device in _devices)
              ListTile(
                selected: _selectedDevice?.id == device.id,
                leading: Icon(
                  _selectedDevice?.id == device.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                onTap: _testing
                    ? null
                    : () => setState(() {
                          _selectedDevice = device;
                          _acceptedStages.clear();
                          _testFinished = false;
                          _message = null;
                        }),
                title: Text(device.name),
                subtitle: Text(
                  '${device.manufacturer ?? 'Smart TV'} • ${device.model ?? 'DLNA/UPnP'}',
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _selectedDevice == null || _searching || _testing
                  ? null
                  : _playTestVideo,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Reproduzir vídeo MP4 de teste'),
            ),
            if (_selectedDevice != null) ...[
              const SizedBox(height: 20),
              Text('Resultado', style: Theme.of(context).textTheme.titleMedium),
              _stageTile(DlnaTestStage.tvFound, 'TV encontrada'),
              _stageTile(
                DlnaTestStage.setUriAccepted,
                'SetAVTransportURI aceito pela TV',
              ),
              _stageTile(DlnaTestStage.playAccepted, 'Play aceito pela TV'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stageTile(DlnaTestStage stage, String label) {
    final accepted = _acceptedStages.contains(stage);
    final firstMissing = DlnaTestStage.values
        .where((value) => !_acceptedStages.contains(value))
        .firstOrNull;
    final failed = _testFinished && !accepted && firstMissing == stage;
    return ListTile(
      leading: Icon(
        accepted
            ? Icons.check_circle
            : failed
                ? Icons.error_outline
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
            ? 'Concluído com sucesso'
            : failed
                ? 'A TV não aceitou esta etapa'
                : 'Aguardando o teste',
      ),
    );
  }
}
