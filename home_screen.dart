import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../services/epg_service.dart';
import '../services/playlist_service.dart';
import '../services/preferences_service.dart';
import '../services/xtream_service.dart';
import 'player_screen.dart';

enum LibraryView { channels, favorites, history }

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
  LibraryView _view = LibraryView.channels;

  @override void initState() { super.initState(); _restore(); }
  Future<void> _restore() async {
    _favorites = await _prefs.favorites(); _history = await _prefs.history();
    final url = await _prefs.playlistUrl();
    if (mounted) setState(() {});
    if (url != null && url.isNotEmpty) await _loadM3u(url, quiet: true);
  }

  List<String> get _groups => (_channels.map((c) => c.group).whereType<String>().where((v) => v.isNotEmpty).toSet().toList()..sort());
  List<Channel> get _visible {
    Iterable<Channel> result = _channels;
    if (_view == LibraryView.favorites) result = result.where((c) => _favorites.contains(c.id));
    if (_view == LibraryView.history) { final byId = {for (final c in result) c.id: c}; result = _history.map((id) => byId[id]).whereType<Channel>(); }
    if (_group != null && _view == LibraryView.channels) result = result.where((c) => c.group == _group);
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty) result = result.where((c) => c.name.toLowerCase().contains(q) || (c.group ?? '').toLowerCase().contains(q));
    return result.toList();
  }

  Future<void> _loadM3u(String url, {bool quiet = false}) async {
    setState(() { _loading = true; _error = null; });
    try { final data = await _playlist.loadFromUrl(url); await _prefs.savePlaylist(url); if (mounted) setState(() => _channels = data); }
    catch (e) { if (mounted && !quiet) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _loadXtream(String server, String user, String password) async {
    setState(() { _loading = true; _error = null; });
    try { final data = await _xtream.load(server: server, username: user, password: password); if (mounted) setState(() => _channels = data); }
    catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _importEpg() async {
    final controller = TextEditingController(text: await _prefs.epgUrl());
    final url = await showDialog<String>(context: context, builder: (context) => AlertDialog(title: const Text('Guia de programação (XMLTV)'), content: TextField(controller: controller, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'URL do EPG', border: OutlineInputBorder())), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')), FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Importar'))]));
    controller.dispose(); if (url == null || url.trim().isEmpty) return;
    setState(() => _loading = true);
    try { final epg = EpgService(); final now = await epg.loadNow(url); await _prefs.saveEpg(url); if (mounted) setState(() => _channels = epg.apply(_channels, now)); }
    catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _accessDialog() async {
    final m3u = TextEditingController(text: await _prefs.playlistUrl());
    final server = TextEditingController(), user = TextEditingController(), pass = TextEditingController();
    var tab = 0;
    await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, setLocal) => AlertDialog(title: const Text('Adicionar acesso'), content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('M3U')), ButtonSegment(value: 1, label: Text('Xtream'))], selected: {tab}, onSelectionChanged: (v) => setLocal(() => tab = v.first)), const SizedBox(height: 16), if (tab == 0) TextField(controller: m3u, decoration: const InputDecoration(labelText: 'URL M3U/M3U8', border: OutlineInputBorder())) else ...[TextField(controller: server, decoration: const InputDecoration(labelText: 'Servidor', border: OutlineInputBorder())), const SizedBox(height: 8), TextField(controller: user, decoration: const InputDecoration(labelText: 'Usuário', border: OutlineInputBorder())), const SizedBox(height: 8), TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Senha', border: OutlineInputBorder()))]])), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancelar')), FilledButton(onPressed: () { Navigator.pop(dialogContext); tab == 0 ? _loadM3u(m3u.text) : _loadXtream(server.text, user.text, pass.text); }, child: const Text('Entrar'))])));
    m3u.dispose(); server.dispose(); user.dispose(); pass.dispose();
  }

  Future<void> _open(Channel channel) async { await _prefs.addHistory(channel.id); _history = await _prefs.history(); if (mounted) { setState(() {}); await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PlayerScreen(channel: channel))); } }
  Future<void> _favorite(Channel channel) async { final value = !_favorites.contains(channel.id); await _prefs.setFavorite(channel.id, value); _favorites = await _prefs.favorites(); if (mounted) setState(() {}); }

  @override void dispose() { _playlist.dispose(); _xtream.dispose(); _search.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('StreamBox'), actions: [IconButton(onPressed: _channels.isEmpty ? null : _importEpg, tooltip: 'Importar EPG', icon: const Icon(Icons.calendar_month)), IconButton(onPressed: _accessDialog, tooltip: 'Adicionar acesso', icon: const Icon(Icons.add_link)), PopupMenuButton<String>(onSelected: (value) { if (value == 'licenses') showLicensePage(context: context, applicationName: 'StreamBox', applicationVersion: '0.3.0', applicationLegalese: 'Player independente. Nenhum canal ou conteúdo é fornecido.'); if (value == 'premium') showDialog<void>(context: context, builder: (context) => AlertDialog(title: const Text('StreamBox Premium'), content: const Text('A compra será ativada pelo Google Play Billing após o cadastro dos produtos na Play Console. Nenhum pagamento externo será usado no aplicativo.'), actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Entendi'))])); }, itemBuilder: (_) => const [PopupMenuItem(value: 'premium', child: ListTile(leading: Icon(Icons.workspace_premium), title: Text('Premium'))), PopupMenuItem(value: 'licenses', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Licenças')))] )]),
    bottomNavigationBar: NavigationBar(selectedIndex: _view.index, onDestinationSelected: (i) => setState(() { _view = LibraryView.values[i]; _group = null; }), destinations: const [NavigationDestination(icon: Icon(Icons.live_tv_outlined), selectedIcon: Icon(Icons.live_tv), label: 'Canais'), NavigationDestination(icon: Icon(Icons.star_outline), selectedIcon: Icon(Icons.star), label: 'Favoritos'), NavigationDestination(icon: Icon(Icons.history), label: 'Histórico')]),
    body: SafeArea(child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 6), child: SearchBar(controller: _search, hintText: 'Buscar canal ou categoria', leading: const Icon(Icons.search), trailing: [if (_search.text.isNotEmpty) IconButton(onPressed: () { _search.clear(); setState(() {}); }, icon: const Icon(Icons.close))], onChanged: (_) => setState(() {}))),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (_view == LibraryView.channels && _groups.isNotEmpty) SizedBox(height: 52, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [FilterChip(label: const Text('Todos'), selected: _group == null, onSelected: (_) => setState(() => _group = null)), const SizedBox(width: 8), ..._groups.map((g) => Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(label: Text(g), selected: _group == g, onSelected: (_) => setState(() => _group = g))))])),
      Expanded(child: _channels.isEmpty ? _Welcome(onAdd: _accessDialog) : _visible.isEmpty ? const Center(child: Text('Nenhum canal encontrado.')) : ListView.builder(itemCount: _visible.length, itemBuilder: (context, index) { final c = _visible[index]; return ListTile(leading: _Logo(c.logoUrl), title: Text(c.name), subtitle: Text(c.epgTitle ?? c.group ?? 'Ao vivo', maxLines: 1, overflow: TextOverflow.ellipsis), trailing: IconButton(tooltip: 'Favorito', onPressed: () => _favorite(c), icon: Icon(_favorites.contains(c.id) ? Icons.star : Icons.star_border, color: _favorites.contains(c.id) ? Colors.amber : null)), onTap: () => _open(c)); }))
    ])));
}

class _Logo extends StatelessWidget { const _Logo(this.url); final String? url; @override Widget build(BuildContext context) => SizedBox.square(dimension: 48, child: url == null || url!.isEmpty ? const Icon(Icons.live_tv) : Image.network(url!, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.live_tv))); }
class _Welcome extends StatelessWidget { const _Welcome({required this.onAdd}); final VoidCallback onAdd; @override Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.live_tv, size: 76, color: Theme.of(context).colorScheme.primary), const SizedBox(height: 16), Text('Seu conteúdo, em uma tela simples', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center), const SizedBox(height: 8), const Text('Adicione uma lista M3U ou um acesso Xtream autorizado. O StreamBox não fornece canais.' , textAlign: TextAlign.center), const SizedBox(height: 20), FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Adicionar acesso'))]))); }
