import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:video_player/video_player.dart';

import '../models/channel.dart';
import '../widgets/cast_dialog.dart';

enum PlayerEngine { automatic, media3, libvlc }

enum VideoFit { contain, sixteenNine, fourThree, cover }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.channel});

  final Channel channel;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  PlayerEngine _preference = PlayerEngine.automatic;
  PlayerEngine _activeEngine = PlayerEngine.media3;
  VideoFit _fit = VideoFit.contain;
  VideoPlayerController? _mediaController;
  VlcPlayerController? _vlcController;
  bool _loading = true;
  bool _playing = false;
  bool _fullscreen = false;
  String? _error;
  double _speed = 1;

  @override
  void initState() {
    super.initState();
    _startMedia3();
  }

  Future<void> _startMedia3() async {
    await _disposePlayers();
    if (!mounted) return;
    setState(() {
      _activeEngine = PlayerEngine.media3;
      _loading = true;
      _error = null;
    });

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.channel.url),
      videoPlayerOptions: VideoPlayerOptions(
        mixWithOthers: false,
        allowBackgroundPlayback: false,
      ),
    );
    _mediaController = controller;
    controller.addListener(_onMediaChanged);

    try {
      await controller.initialize().timeout(const Duration(seconds: 12));
      await controller.setPlaybackSpeed(_speed);
      await controller.play();
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (_preference == PlayerEngine.automatic) {
        await _startVlc();
      } else if (mounted) {
        setState(() {
          _loading = false;
          _error = 'O player Android não conseguiu abrir este conteúdo.\n$error';
        });
      }
    }
  }

  void _onMediaChanged() {
    final controller = _mediaController;
    if (!mounted || controller == null) return;
    final value = controller.value;
    if (value.hasError && _preference == PlayerEngine.automatic) {
      _startVlc();
      return;
    }
    if (_playing != value.isPlaying) {
      setState(() => _playing = value.isPlaying);
    }
  }

  Future<void> _startVlc() async {
    await _disposePlayers();
    if (!mounted) return;
    setState(() {
      _activeEngine = PlayerEngine.libvlc;
      _loading = true;
      _error = null;
    });

    final controller = VlcPlayerController.network(
      widget.channel.url,
      autoPlay: true,
      hwAcc: HwAcc.full,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([VlcAdvancedOptions.networkCaching(1500)]),
      ),
    );
    _vlcController = controller;
    controller.addListener(_onVlcChanged);
    try {
      await controller.initialize().timeout(const Duration(seconds: 15));
      await controller.setPlaybackSpeed(_speed);
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Nenhum motor conseguiu abrir este conteúdo.\n$error';
        });
      }
    }
  }

  void _onVlcChanged() {
    final controller = _vlcController;
    if (!mounted || controller == null) return;
    final value = controller.value;
    if (_playing != value.isPlaying) {
      setState(() => _playing = value.isPlaying);
    }
  }

  Future<void> _disposePlayers() async {
    final media = _mediaController;
    _mediaController = null;
    media?.removeListener(_onMediaChanged);
    await media?.dispose();
    final vlc = _vlcController;
    _vlcController = null;
    vlc?.removeListener(_onVlcChanged);
    await vlc?.dispose();
  }

  Future<void> _selectEngine(PlayerEngine engine) async {
    _preference = engine;
    if (engine == PlayerEngine.libvlc) {
      await _startVlc();
    } else {
      await _startMedia3();
    }
  }

  Future<void> _togglePlay() async {
    if (_activeEngine == PlayerEngine.media3) {
      final controller = _mediaController;
      if (controller == null) return;
      controller.value.isPlaying ? await controller.pause() : await controller.play();
    } else {
      final controller = _vlcController;
      if (controller == null) return;
      controller.value.isPlaying ? await controller.pause() : await controller.play();
    }
  }

  Future<void> _setSpeed(double speed) async {
    _speed = speed;
    if (_activeEngine == PlayerEngine.media3) {
      await _mediaController?.setPlaybackSpeed(speed);
    } else {
      await _vlcController?.setPlaybackSpeed(speed);
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    if (mounted) setState(() {});
  }

  double get _aspectRatio {
    switch (_fit) {
      case VideoFit.sixteenNine:
        return 16 / 9;
      case VideoFit.fourThree:
        return 4 / 3;
      case VideoFit.contain:
      case VideoFit.cover:
        final ratio = _activeEngine == PlayerEngine.media3
            ? _mediaController?.value.aspectRatio
            : _vlcController?.value.aspectRatio;
        return ratio != null && ratio > 0 ? ratio : 16 / 9;
    }
  }

  Widget _video() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 16),
              FilledButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh), label: const Text('Tentar novamente')),
            ],
          ),
        ),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());

    final player = _activeEngine == PlayerEngine.media3
        ? VideoPlayer(_mediaController!)
        : VlcPlayer(controller: _vlcController!, aspectRatio: _aspectRatio, placeholder: const Center(child: CircularProgressIndicator()));
    return Center(
      child: AspectRatio(
        aspectRatio: _aspectRatio,
        child: ClipRect(
          child: _fit == VideoFit.cover ? SizedBox.expand(child: FittedBox(fit: BoxFit.cover, child: SizedBox(width: 1280, height: 720, child: player))) : player,
        ),
      ),
    );
  }

  Future<void> _reload() => _activeEngine == PlayerEngine.libvlc ? _startVlc() : _startMedia3();

  @override
  void dispose() {
    _disposePlayers();
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: _fullscreen ? null : AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(widget.channel.name)),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(child: GestureDetector(onDoubleTap: _toggleFullscreen, child: _video())),
              if (!_fullscreen) _controls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    return Material(
      color: Colors.black,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CastDialog(channel: widget.channel),
              ),
              color: Colors.white,
              tooltip: 'Transmitir para TV',
              icon: const Icon(Icons.cast),
            ),
            IconButton(onPressed: _reload, color: Colors.white, tooltip: 'Reconectar', icon: const Icon(Icons.refresh)),
            IconButton(onPressed: _loading ? null : _togglePlay, color: Colors.white, iconSize: 42, tooltip: _playing ? 'Pausar' : 'Reproduzir', icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle)),
            PopupMenuButton<double>(initialValue: _speed, tooltip: 'Velocidade', iconColor: Colors.white, icon: Text('${_speed}x', style: const TextStyle(color: Colors.white)), onSelected: _setSpeed, itemBuilder: (_) => [0.5, 1.0, 1.25, 1.5, 2.0].map((value) => PopupMenuItem(value: value, child: Text('${value}x'))).toList()),
            PopupMenuButton<VideoFit>(tooltip: 'Proporção', iconColor: Colors.white, icon: const Icon(Icons.aspect_ratio), onSelected: (value) => setState(() => _fit = value), itemBuilder: (_) => const [
              PopupMenuItem(value: VideoFit.contain, child: Text('Original')),
              PopupMenuItem(value: VideoFit.sixteenNine, child: Text('16:9')),
              PopupMenuItem(value: VideoFit.fourThree, child: Text('4:3')),
              PopupMenuItem(value: VideoFit.cover, child: Text('Preencher')),
            ]),
            PopupMenuButton<PlayerEngine>(tooltip: 'Motor do player', iconColor: Colors.white, icon: const Icon(Icons.settings_input_component), onSelected: _selectEngine, itemBuilder: (_) => const [
              PopupMenuItem(value: PlayerEngine.automatic, child: Text('Automático')),
              PopupMenuItem(value: PlayerEngine.media3, child: Text('Player Android')),
              PopupMenuItem(value: PlayerEngine.libvlc, child: Text('Compatibilidade')),
            ]),
            IconButton(onPressed: _toggleFullscreen, color: Colors.white, tooltip: 'Tela cheia', icon: const Icon(Icons.fullscreen)),
          ],
        ),
      ),
    );
  }
}
