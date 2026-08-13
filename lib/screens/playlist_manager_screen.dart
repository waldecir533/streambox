// Gerenciar Playlists (Fase 3).
//
// Lista os acessos salvos (M3U por URL e Xtream), permite atualizar a lista
// ou remover o acesso. Remover nunca apaga os canais antes: a gravação nova
// continua sendo transacional no ChannelsStore. As credenciais aparecem
// mascaradas em qualquer tela.
import 'package:flutter/material.dart';
import '../services/diagnostic_service.dart';
import '../services/preferences_service.dart';
import '../services/xtream_service.dart';

class PlaylistManagerScreen extends StatefulWidget {
  const PlaylistManagerScreen({super.key, required this.onReload});

  /// Chamado depois que o usuário atualiza ou remove um acesso, para a tela
  /// principal recarregar a biblioteca.
  final VoidCallback onReload;

  @override
  State<PlaylistManagerScreen> createState() => _PlaylistManagerScreenState();
}

class _PlaylistManagerScreenState extends State<PlaylistManagerScreen> {
  final _prefs = PreferencesService();
  final _xtream = XtreamService();
  String? _m3uUrl;
  String? _xtreamServer;
  String? _xtreamUser;
  bool _loading = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _m3uUrl = await _prefs.playlistUrl();
      _xtreamServer = await _prefs.xtreamServer();
      _xtreamUser = await _prefs.xtreamUser();
    } catch (_) {
      // Falha ao ler não fecha o app: segue com tela vazia.
    }
    if (mounted) setState(() {});
  }

  String _mask(String value) => value.length <= 4
      ? '••••'
      : '${value.substring(0, 3)}${'*' * (value.length - 7)}${value.substring(value.length - 3)}';

  Future<void> _refreshM3u() async {
    final url = _m3uUrl;
    if (url == null || url.isEmpty) return;
    setState(() { _loading = true; _status = 'Atualizando a lista…'; });
    try {
      final result = await _prefs.refreshPlaylistFromUrl(url);
      if (mounted) {
        setState(() {
          _loading = false;
          _status = result.success
              ? 'Lista atualizada (${result.count} canais).'
              : (result.message ?? 'Não foi possível atualizar a lista.');
        });
        if (result.success) widget.onReload();
      }
    } catch (error) {
      DiagnosticService.importDiagnostic
        ..failurePhase = 'atualização da lista'
        ..errorMessage = '$error';
      if (mounted) {
        setState(() {
          _loading = false;
          _status = 'Não foi possível atualizar a lista agora.';
        });
      }
    }
  }

  Future<void> _removeM3u() async {
    final keep = await showDialog<bool>(context: context, builder: (context) =>
        AlertDialog(
          title: const Text('Remover a lista M3U?'),
          content: const Text('O acesso e os canais salvos serão removidos. Seus favoritos e o histórico continuam no aplicativo.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remover')),
          ],
        ));
    if (keep != true) return;
    try {
      await _prefs.clearAccess();
      if (mounted) {
        setState(() { _m3uUrl = null; _status = 'Lista removida.'; });
        widget.onReload();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Não foi possível remover a lista agora.');
      }
    }
  }

  Future<void> _removeXtream() async {
    final keep = await showDialog<bool>(context: context, builder: (context) =>
        AlertDialog(
          title: const Text('Remover o acesso Xtream?'),
          content: const Text('O acesso e os canais salvos serão removidos. Seus favoritos e o histórico continuam no aplicativo.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remover')),
          ],
        ));
    if (keep != true) return;
    try {
      await _prefs.clearXtreamAccess();
      if (mounted) {
        setState(() { _xtreamServer = null; _xtreamUser = null; _status = 'Acesso removido.'; });
        widget.onReload();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Não foi possível remover o acesso agora.');
      }
    }
  }

  @override
  void dispose() { _xtream.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Gerenciar Playlists')),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_status != null)
          Container(color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(_status!, style: const TextStyle(fontSize: 13))),
        Expanded(child: ListView(children: [
          if (_m3uUrl == null && _xtreamServer == null)
            const Padding(padding: EdgeInsets.all(28),
              child: Text('Nenhum acesso salvo. Adicione uma lista M3U ou um acesso Xtream na tela inicial.', textAlign: TextAlign.center)),
          if (_m3uUrl != null) ListTile(
            leading: const CircleAvatar(child: Icon(Icons.link)),
            title: const Text('Lista M3U'),
            subtitle: Text(_mask(_m3uUrl!)),
            trailing: Wrap(direction: Axis.horizontal, spacing: 8, children: [
              IconButton(tooltip: 'Atualizar', onPressed: _loading ? null : _refreshM3u, icon: const Icon(Icons.refresh)),
              IconButton(tooltip: 'Remover', onPressed: _removeM3u, icon: const Icon(Icons.delete_outline)),
            ]),
          ),
          if (_xtreamServer != null) ListTile(
            leading: const CircleAvatar(child: Icon(Icons.cloud)),
            title: const Text('Acesso Xtream'),
            subtitle: Text('${_mask(_xtreamServer!)}\nUsuário: ${_mask(_xtreamUser ?? '')}'),
            trailing: IconButton(tooltip: 'Remover', onPressed: _removeXtream, icon: const Icon(Icons.delete_outline)),
          ),
        ])),
      ],
    ),
  );
}
