import 'dart:async';

import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/import_summary.dart';
import '../services/diagnostic_service.dart';
import '../services/epg_service.dart';
import '../services/library_section_service.dart';
import '../services/m3u_parser.dart';
import '../services/playlist_service.dart';
import '../services/preferences_service.dart';
import '../services/xtream_service.dart';
import 'player_screen.dart';
import 'playlist_manager_screen.dart';
import 'settings_screen.dart';
import '../widgets/channel_list_tile.dart';

enum LibraryView { channels, favorites, history }

/// Navegação principal da aba de canais (padrão brasileiro, Fase 3).
enum HomeTab { home, tv, movies, series, sports }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _playlist = PlaylistService();
  final _xtream = XtreamService();
  final _prefs = PreferencesService();
  final _search = TextEditingController();
  List<Channel> _channels = const [];
  Set<String> _favorites = {};
  List<String> _history = [];
  String? _group;
  bool _loading = false;
  String? _error;
  String? _retryPlaylistUrl;
  double? _progress;
  int? _savedCount;
  int? _skippedLines;
  LibraryView _view = LibraryView.channels;
  List<String> _memoGroups = const [];
  LibrarySection? _section;
  HomeTab _tab = HomeTab.home;
  LibrarySection get _activeSection {
    // Na aba Início a seção selecionada prevalece; nas abas específicas,
    // a seção é fixa (TV ao vivo, Filmes, Séries, Esportes).
    switch (_tab) {
      case HomeTab.tv:
        return LibrarySection.live;
      case HomeTab.movies:
        return LibrarySection.movies;
      case HomeTab.series:
        return LibrarySection.series;
      case HomeTab.sports:
        return LibrarySection.sports;
      case HomeTab.home:
        return _section ?? LibrarySection.live;
    }
  }
  @override void initState() { super.initState(); _restore(); }
  Future<void> _restore() async {
    try {
      _favorites = await _prefs.favorites(); _history = await _prefs.history();
      _channels = await _prefs.cachedChannels();
      final url = await _prefs.playlistUrl();
      if (mounted) setState(() => _memoGroups = _computeGroups());
      if (url != null && url.isNotEmpty) await _loadM3u(url, restoring: true);
    } catch (error, stack) {
      DiagnosticService.importDiagnostic
        ..failurePhase = 'restauração dos canais salvos'
        ..errorMessage = '$error'
        ..stackTrace = '$stack';
      // Falha na restauração nunca fecha o app: segue com a tela vazia.
    }
  }

  /// Contagem de canais por seção do padrão brasileiro (para a barra de seções).
  Map<LibrarySection, int> get _sectionCounts {
    final counts = <LibrarySection, int>{for (final s in LibrarySection.values) s: 0};
    for (final channel in _channels) {
      counts[LibrarySectionService.sectionOf(channel.group)] =
          (counts[LibrarySectionService.sectionOf(channel.group)] ?? 0) + 1;
    }
    return counts;
  }

  List<String> _computeGroups() => (_channels
      .map((c) => c.group)
      .whereType<String>()
      .where((v) => v.isNotEmpty)
      .toSet()
      ..removeWhere((v) => v.isEmpty))
      .toList()
    ..sort();
  List<Channel> get _visible {
    Iterable<Channel> result = _channels;
    if (_view == LibraryView.favorites) result = result.where((c) => _favorites.contains(c.id));
    if (_view == LibraryView.history) { final byId = {for (final c in result) c.id: c}; result = _history.map((id) => byId[id]).whereType<Channel>(); }
    // Filtra por seção do padrão brasileiro (TV ao vivo, Filmes, Séries,
    // Esportes) sem alterar o group-title original de nenhum canal.
    if (_view == LibraryView.channels) {
      result = result.where((c) => LibrarySectionService.sectionOf(c.group) == _activeSection);
    }
    if (_group != null && _view == LibraryView.channels) result = result.where((c) => c.group == _group);
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty) result = result.where((c) => c.name.toLowerCase().contains(q) || (c.group ?? '').toLowerCase().contains(q));
    return result.toList();
  }

  Future<void> _loadM3u(String url, {bool restoring = false}) async {
    setState(() { _loading = true; _error = null; _retryPlaylistUrl = null; _progress = null; _savedCount = null; _skippedLines = null; });

    // Prepara o relatório de diagnóstico (sem credenciais).
    final diag = DiagnosticService.importDiagnostic
      ..sourceType = 'M3U por URL'
      ..sourceDescription = 'lista do provedor'
      ..fileSizeDescription = '-'
      ..analyzedCount = 0
      ..savedCount = 0
      ..skippedLines = 0
      ..detectedSource = 'não detectado'
      ..importTimeSeconds = null
      ..failurePhase = null
      ..errorMessage = null
      ..stackTrace = null;

    final stopwatch = Stopwatch()..start();
    try {
      // Download + inspeção do tipo de fonte + análise, com mensagens
      // específicas por tipo de erro (401, 404, timeout, HTML...). A lista
      // anterior nunca é apagada: a gravação nova é transacional.
      final result = await _playlist.importFromUrl(url, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      stopwatch.stop();
      diag.detectedSource = result.sourceType?.name ?? 'desconhecido';
      diag.importTimeSeconds = stopwatch.elapsedMilliseconds / 1000;

      // Fonte não é uma playlist: mostra a mensagem específica e oferece
      // salvar como canal avulso quando for um stream individual.
      if (!result.isSuccess) {
        if (result.isIndividualStream) {
          if (mounted) _showSaveStreamDialog(url, result.sourceType == SourceType.hlsStream);
        } else {
          throw ImportSourceException(result.message ?? 'Conteúdo não reconhecido.');
        }
        return;
      }

      final data = result.channels;
      diag.analyzedCount = data.length;
      diag.skippedLines = result.skippedLines;
      diag.failurePhase = 'gravação dos canais';

      // Gravação transacional em arquivo (não apaga a lista atual antes de
      // terminar; falha no meio mantém os canais salvos anteriores).
      await _prefs.saveChannels(data);
      await _prefs.savePlaylist(url);
      diag.savedCount = data.length;
      diag.failurePhase = null;

      final summary = ImportSummary.fromChannels(
        channels: data,
        skippedLines: result.skippedLines,
        bytes: result.bytes,
        durationSeconds: stopwatch.elapsedMilliseconds / 1000,
      );
      if (mounted) {
        setState(() {
          _channels = data;
          _memoGroups = _computeGroups();
          _savedCount = data.length;
          _skippedLines = result.skippedLines;
        });
        _showImportSummaryDialog(summary);
      }
    } on ImportSourceException catch (error) {
      diag.failurePhase = 'reconhecimento da fonte';
      diag.errorMessage = '$error';
      if (mounted) {
        setState(() { _error = error.message; });
      }
    } catch (error, stack) {
      diag.failurePhase = diag.failurePhase ?? 'finalização da importação';
      diag.errorMessage = '$error';
      diag.stackTrace = '$stack';
      if (mounted) {
        setState(() {
          _error = restoring && _channels.isNotEmpty
              ? 'Não foi possível atualizar a lista agora. Exibindo os canais salvos.'
              : error.toString();
          _retryPlaylistUrl = url;
        });
      }
    }
    finally {
      if (mounted) setState(() { _loading = false; _progress = null; });
    }
  }

  /// Oferece salvar um stream individual como canal avulso com nome e
  /// categoria escolhidos pelo usuário (não é uma lista M3U).
  Future<void> _showSaveStreamDialog(String url, bool isHls) async {
    final nameController = TextEditingController(text: isHls ? 'Stream HLS' : 'Vídeo direto');
    final groupController = TextEditingController(text: 'Meus streams');
    if (!mounted) {
      nameController.dispose(); groupController.dispose();
      return;
    }
    final saved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Endereço de stream individual'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(isHls
            ? 'Este endereço é um único stream (HLS), não uma lista com vários canais.'
            : 'Este endereço é um fluxo de vídeo direto, não uma lista com vários canais.'),
        const SizedBox(height: 16),
        TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Nome', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: groupController, decoration: const InputDecoration(labelText: 'Categoria', border: OutlineInputBorder())),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Salvar canal')),
      ],
    ));
    nameController.dispose(); groupController.dispose();
    if (saved == true) {
      final channel = Channel(
        name: nameController.text.trim().isEmpty ? 'Canal avulso' : nameController.text.trim(),
        url: url.trim(),
        group: groupController.text.trim().isEmpty ? 'Meus streams' : groupController.text.trim(),
        sourceKind: SourceKind.individual,
        contentType: isHls ? 'application/x-mpegURL' : null,
      );
      try {
        final existing = await _prefs.cachedChannels();
        final updated = [...existing, channel];
        await _prefs.saveChannels(updated);
        if (mounted) {
          setState(() { _channels = updated; _memoGroups = _computeGroups(); });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Canal salvo com sucesso.')),
          );
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Não foi possível salvar o canal agora.')),
          );
        }
      }
    }
  }

  void _showImportSummaryDialog(ImportSummary summary) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Importação concluída'),
        content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• ${summary.channels} canais importados'),
            Text('• ${summary.liveChannels} canais de TV ao vivo'),
            Text('• ${summary.movies} filmes identificados'),
            Text('• ${summary.series} séries identificadas'),
            Text('• ${summary.sports} conteúdos de esportes'),
            Text('• ${summary.groups} categorias organizadas'),
            if (summary.skippedLines > 0)
              Text('• ${summary.skippedLines} entradas ignoradas por estarem inválidas'),
            Text('• Tamanho da lista: ${summary.sizeDescription}'),
            Text('• Tempo: ${summary.durationDescription}'),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Detalhes da importação'),
                  content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Canais importados: ${summary.channels}'),
                      Text('TV ao vivo: ${summary.liveChannels}'),
                      Text('Filmes identificados: ${summary.movies}'),
                      Text('Séries identificadas: ${summary.series}'),
                      Text('Esportes: ${summary.sports}'),
                      Text('Categorias: ${summary.groups}'),
                      Text('Entradas ignoradas: ${summary.skippedLines}'),
                      Text('Tamanho: ${summary.sizeDescription}'),
                      Text('Duração: ${summary.durationDescription}'),
                      const SizedBox(height: 8),
                      const Text('A classificação por filmes, séries e esportes usa as categorias da própria lista e pode ser ajustada depois em Personalização.'),
                    ],
                  )),
                  actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Entendi'))],
                ),
              );
            },
            child: const Text('Ver detalhes'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportDiagnosticReport() async {
    final result = await DiagnosticService.shareReport();
    if (mounted && result.contains('Relatório pronto')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Relatório de diagnóstico pronto para envio.')),
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Relatório gravado na pasta de dados do aplicativo.')),
      );
    }
  }

  Future<void> _loadXtream(String server, String user, String password) async {
    setState(() { _loading = true; _error = null; });
    try { final data = await _xtream.load(server: server, username: user, password: password); if (mounted) setState(() => _channels = data); }
    catch (_) { if (mounted) setState(() => _error = 'Não foi possível entrar. Confira os dados e sua conexão.'); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _importEpg() async {
    final controller = TextEditingController(text: await _prefs.epgUrl());
    if (!mounted) {
      controller.dispose();
      return;
    }
    final url = await showDialog<String>(context: context, builder: (context) => AlertDialog(title: const Text('Guia de programação (XMLTV)'), content: TextField(controller: controller, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'URL do EPG', border: OutlineInputBorder())), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Importar'))]));
    controller.dispose(); if (url == null || url.trim().isEmpty) return;
    setState(() => _loading = true);
    try { final epg = EpgService(); final now = await epg.loadNow(url); await _prefs.saveEpg(url); if (mounted) setState(() => _channels = epg.apply(_channels, now)); }
    catch (_) { if (mounted) setState(() => _error = 'Não foi possível atualizar o guia agora. Tente novamente mais tarde.'); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _accessDialog() async {
    final m3u = TextEditingController(text: await _prefs.playlistUrl());
    final server = TextEditingController(), user = TextEditingController(), pass = TextEditingController();
    if (!mounted) {
      m3u.dispose(); server.dispose(); user.dispose(); pass.dispose();
      return;
    }
    var tab = 0;
    await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, setLocal) => AlertDialog(title: const Text('Adicionar acesso'), content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('M3U')), ButtonSegment(value: 1, label: Text('Xtream'))], selected: {tab}, onSelectionChanged: (v) => setLocal(() => tab = v.first)), const SizedBox(height: 16), if (tab == 0) TextField(controller: m3u, decoration: const InputDecoration(labelText: 'URL M3U/M3U8', border: OutlineInputBorder())) else ...[TextField(controller: server, decoration: const InputDecoration(labelText: 'Servidor', border: OutlineInputBorder())), const SizedBox(height: 8), TextField(controller: user, decoration: const InputDecoration(labelText: 'Usuário', border: OutlineInputBorder())), const SizedBox(height: 8), TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Senha', border: OutlineInputBorder()))]])), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancelar')), FilledButton(onPressed: () { Navigator.pop(dialogContext); tab == 0 ? _saveAndLoadM3u(m3u.text) : _saveAndLoadXtream(server.text, user.text, pass.text); }, child: const Text('Entrar'))])));
    m3u.dispose(); server.dispose(); user.dispose(); pass.dispose();
  }

  Future<void> _saveAndLoadM3u(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    try {
      await _prefs.clearXtreamAccess();
      await _prefs.savePlaylist(trimmed);
    } catch (_) {
      // Falha ao salvar preferências não impede a importação.
    }
    await _loadM3u(trimmed);
  }

  Future<void> _saveAndLoadXtream(String server, String user, String pass) async {
    if (server.trim().isEmpty || user.trim().isEmpty) return;
    try {
      await _prefs.saveXtreamAccess(server: server.trim(), username: user.trim(), password: pass.trim());
    } catch (_) {
      // Credenciais nunca são registradas em log.
    }
    await _loadXtream(server.trim(), user.trim(), pass.trim());
  }

  Future<void> _open(Channel channel) async { await _prefs.addHistory(channel.id); _history = await _prefs.history(); if (mounted) { setState(() {}); await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PlayerScreen(channel: channel, channels: _channels))); } }
  Future<void> _favorite(Channel channel) async { final value = !_favorites.contains(channel.id); await _prefs.setFavorite(channel.id, value); _favorites = await _prefs.favorites(); if (mounted) setState(() {}); }

  @override void dispose() {
    _playlist.cancelToken?.cancel();
    _playlist.dispose();
    _xtream.dispose();
    _search.dispose();
    super.dispose();
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('StreamBox'), actions: [IconButton(onPressed: _exportDiagnosticReport, tooltip: 'Exportar relatório de diagnóstico', icon: const Icon(Icons.bug_report_outlined)), IconButton(onPressed: _channels.isEmpty ? null : _importEpg, tooltip: 'Importar EPG', icon: const Icon(Icons.calendar_month)), IconButton(onPressed: _accessDialog, tooltip: 'Adicionar acesso', icon: const Icon(Icons.add_link)), PopupMenuButton<String>(onSelected: (value) { if (value == 'playlists') Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => PlaylistManagerScreen(onReload: _restore))); if (value == 'settings') Navigator.push<void>(context, MaterialPageRoute<void>(builder: (_) => const SettingsScreen())); if (value == 'licenses') showLicensePage(context: context, applicationName: 'StreamBox', applicationVersion: '0.7.0', applicationLegalese: 'Player independente. Nenhum canal ou conteúdo é fornecido.'); if (value == 'premium') showDialog<void>(context: context, builder: (context) => AlertDialog(title: const Text('StreamBox Premium'), content: const Text('A compra será ativada pelo Google Play Billing após o cadastro dos produtos na Play Console. Nenhum pagamento externo será usado no aplicativo.'), actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Entendi'))])); }, itemBuilder: (_) => const [PopupMenuItem(value: 'playlists', child: ListTile(leading: Icon(Icons.playlist_play), title: Text('Gerenciar Playlists'))), PopupMenuItem(value: 'settings', child: ListTile(leading: Icon(Icons.settings), title: Text('Configurações'))), PopupMenuItem(value: 'premium', child: ListTile(leading: Icon(Icons.workspace_premium), title: Text('Premium'))), PopupMenuItem(value: 'licenses', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Licenças')))] )]),
    bottomNavigationBar: NavigationBar(selectedIndex: _view.index, onDestinationSelected: (i) => setState(() { _view = LibraryView.values[i]; _group = null; _tab = HomeTab.home; }), destinations: const [NavigationDestination(icon: Icon(Icons.live_tv_outlined), selectedIcon: Icon(Icons.live_tv), label: 'Canais'), NavigationDestination(icon: Icon(Icons.star_outline), selectedIcon: Icon(Icons.star), label: 'Favoritos'), NavigationDestination(icon: Icon(Icons.history), label: 'Histórico')]),
    body: SafeArea(child: Column(children: [
      if (_view == LibraryView.channels) SizedBox(height: 48, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [...HomeTab.values.map<Widget>((t) => Padding(padding: const EdgeInsets.only(right: 10), child: ChoiceChip(label: Text(_tabLabel(t)), avatar: Icon(_tabIcon(t), size: 16), selected: _tab == t, onSelected: (_) => setState(() { _tab = _tab == t ? HomeTab.home : t; _group = null; }))))])),
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 6), child: SearchBar(controller: _search, hintText: 'Buscar canal ou categoria', leading: const Icon(Icons.search), trailing: [if (_search.text.isNotEmpty) IconButton(onPressed: () { _search.clear(); setState(() {}); }, icon: const Icon(Icons.close))], onChanged: (_) => setState(() {}))),
      if (_loading)
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const LinearProgressIndicator(),
          if (_progress != null) Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('Analisando a lista… ${( _progress! * 100).round()}%'),
          ),
          if (_savedCount != null) Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('$_savedCount canais salvos${_skippedLines != null && _skippedLines! > 0 ? ' ($_skippedLines linhas ignoradas)' : ''}.'),
          ),
        ]),
      if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Row(children: [Expanded(child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))), if (_retryPlaylistUrl != null) TextButton.icon(onPressed: _loading ? null : () => _loadM3u(_retryPlaylistUrl!), icon: const Icon(Icons.refresh), label: const Text('Tentar novamente'))])),
      if (_view == LibraryView.channels && _channels.isNotEmpty)
        SizedBox(height: 44, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          if (_tab == HomeTab.home) ...[ChoiceChip(label: const Text('Todos'), selected: _section == null, onSelected: (_) => setState(() { _section = null; _group = null; })), ...LibrarySection.values.where((s) => (_sectionCounts[s] ?? 0) > 0).map<Widget>((s) => Padding(padding: const EdgeInsets.only(left: 8), child: ChoiceChip(label: Text('${s.label} (${_sectionCounts[s]})'), avatar: Icon(s.icon, size: 16), selected: _section == s, onSelected: (_) => setState(() { _section = _section == s ? null : s; _group = null; }))))],
          if (_tab != HomeTab.home) _SubtopicsOf(_activeSection, _channels),
        ])),
      if (_view == LibraryView.channels && _memoGroups.isNotEmpty) SizedBox(height: 52, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [FilterChip(label: const Text('Todos'), selected: _group == null, onSelected: (_) => setState(() { _group = null; _section = null; })), const SizedBox(width: 8), ..._memoGroups.map<Widget>((g) => Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(label: Text(g), selected: _group == g, onSelected: (_) => setState(() { _group = _group == g ? null : g; }))))])),
      Expanded(child: _channels.isEmpty ? _Welcome(onAdd: _accessDialog) : _visible.isEmpty ? const Center(child: Text('Nenhum canal encontrado.')) : ListView.builder(key: ValueKey('${_view.index}-${_group ?? ""}-${_search.text}'), itemCount: _visible.length, itemBuilder: (context, index) { final c = _visible[index]; return ChannelListTile(channel: c, isFavorite: _favorites.contains(c.id), onToggleFavorite: () => _favorite(c), onOpen: () => _open(c)); }))
    ])));
}

String _tabLabel(HomeTab tab) {
  switch (tab) {
    case HomeTab.home:
      return 'Início';
    case HomeTab.tv:
      return 'TV ao vivo';
    case HomeTab.movies:
      return 'Filmes';
    case HomeTab.series:
      return 'Séries';
    case HomeTab.sports:
      return 'Esportes';
  }
}

IconData _tabIcon(HomeTab tab) {
  switch (tab) {
    case HomeTab.home:
      return Icons.home_outlined;
    case HomeTab.tv:
      return Icons.live_tv_outlined;
    case HomeTab.movies:
      return Icons.movie_outlined;
    case HomeTab.series:
      return Icons.video_library_outlined;
    case HomeTab.sports:
      return Icons.sports_soccer_outlined;
  }
}

/// Chips de subtemas (Notícias, Infantil, Música, Religioso) dentro de uma
/// seção fixa (TV ao vivo, Filmes, Séries ou Esportes).
class _SubtopicsOf extends StatefulWidget {
  const _SubtopicsOf(this.section, this.channels);
  final LibrarySection section;
  final List<Channel> channels;
  @override
  State<_SubtopicsOf> createState() => _SubtopicsOfState();
}

class _SubtopicsOfState extends State<_SubtopicsOf> {
  String? _active;
  List<String> _memoized() {
    final topics = <String>[];
    for (final channel in widget.channels) {
      if (LibrarySectionService.sectionOf(channel.group) != widget.section) continue;
      final topic = LibrarySectionService.subtopicOf(channel.group);
      if (!topics.contains(topic)) topics.add(topic);
    }
    topics.sort();
    return topics;
  }

  @override
  Widget build(BuildContext context) {
    final topics = _memoized();
    if (topics.isEmpty) {
      return const Center(child: Text('Nenhum subtema.'));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      FilterChip(label: const Text('Todos'), selected: _active == null, onSelected: (_) => setState(() => _active = null)),
      ...topics.map<Widget>((topic) => Padding(padding: const EdgeInsets.only(left: 8), child: FilterChip(label: Text(topic), selected: _active == topic, onSelected: (_) => setState(() => _active = _active == topic ? null : topic)))),
    ]);
  }
}

class _Welcome extends StatelessWidget { const _Welcome({required this.onAdd}); final VoidCallback onAdd; @override Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.live_tv, size: 76, color: Theme.of(context).colorScheme.primary), const SizedBox(height: 16), Text('Seu conteúdo, em uma tela simples', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center), const SizedBox(height: 8), const Text('Adicione uma lista M3U ou um acesso Xtream autorizado. O StreamBox não fornece canais.' , textAlign: TextAlign.center), const SizedBox(height: 20), FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Adicionar acesso'))]))); }
