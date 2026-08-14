import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../services/recording_service.dart';
import '../services/stream_proxy_service.dart';
import 'player_screen.dart';

/// Lista de gravações de canais ao vivo (DVR).
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});
  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  final _service = RecordingService.instance;
  List<Recording> _recordings = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load().then((_) => _listen());
  }

  Future<void> _load() async {
    try {
      final list = await _service.list();
      if (mounted) setState(() { _recordings = list; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = 'Não foi possível abrir as gravações.'; _loading = false; });
    }
  }

  void _listen() {
    // Lista muda quando uma gravação é encerrada, excluída ou iniciada.
    _service.onRecordingsChanged.listen((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _open(Recording recording) async {
    // Gravações salvas são reproduzidas diretamente do arquivo local.
    // Gravações em andamento tocam pelo proxy enquanto o disco é escrito.
    final Uri url;
    if (recording.isRunning) {
      final proxy = StreamProxyService();
      try {
        url = proxy.recordingUrl(recording);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível iniciar o proxy local.')),
        );
        return;
      }
    } else {
      url = Uri.parse('file://${recording.file.path}');
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          channel: Channel(
            name: recording.channelName,
            url: url.toString(),
            group: 'Gravações',
          ),
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _delete(Recording recording) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Excluir gravação?'),
        content: Text('"${recording.channelName}" será removida do dispositivo.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await recording.delete();
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível excluir a gravação.')),
        );
      }
    }
  }

  String _formatDuration(int seconds) {
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatDate(DateTime date) {
    final dd = date.day.toString().padLeft(2, '0');
    final mm = date.month.toString().padLeft(2, '0');
    final yyyy = date.year;
    final hh = date.hour.toString().padLeft(2, '0');
    final min = date.minute.toString().padLeft(2, '0');
    return '$dd/$mm/$yyyy $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }
    return Column(children: [
      if (_recordings.isEmpty)
        const Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.videocam_off_outlined, size: 56, color: Colors.grey), SizedBox(height: 16), Text('Nenhuma gravação ainda.', style: TextStyle(color: Colors.grey)), SizedBox(height: 8), Text('Toque em Gravar durante a reprodução de um canal para registrar o conteúdo.', style: TextStyle(color: Colors.grey, fontSize: 12), textAlign: TextAlign.center)]))),
      if (_recordings.isNotEmpty)
        Expanded(
          child: ListView.builder(
            itemCount: _recordings.length,
            itemBuilder: (context, index) {
              final recording = _recordings[index];
              final size = recording.bytesWritten > 0 ? _formatSize(recording.bytesWritten) : '…';
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: recording.isRunning ? Colors.red : Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(recording.isRunning ? Icons.fiber_manual_record : Icons.play_circle_outline, color: recording.isRunning ? Colors.white : null),
                ),
                title: Text(recording.channelName),
                subtitle: Text(
                  '${_formatDate(recording.createdAt)} · ${_formatDuration(recording.estimatedSeconds)} · $size${recording.isRunning ? ' · gravando' : ''}',
                ),
                onTap: recording.estimatedSeconds > 10 || recording.isRunning ? () => _open(recording) : null,
                trailing: IconButton(
                  onPressed: () => _delete(recording),
                  icon: const Icon(Icons.delete_outline, color: Colors.grey),
                  tooltip: 'Excluir',
                ),
              );
            },
          ),
        ),
    ]);
  }
}
