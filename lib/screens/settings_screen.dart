// Tela de Configurações (Fase 3).
//
// Preferências pequenas persistidas no SharedPreferences (nunca a lista de
// canais). O serviço de transmissão (DLNA/Google Cast) não inicializa
// automaticamente: só quando o usuário solicitar envio para a TV.
import 'package:flutter/material.dart';
import '../services/preferences_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _prefs = PreferencesService();
  String _engine = 'automatic';
  bool _castingEnabled = false;
  bool _landscape = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _engine = await _prefs.playerEnginePreference();
      _castingEnabled = await _prefs.castingEnabled();
      _landscape = await _prefs.fullscreenLandscape();
    } catch (_) {
      // Falha ao ler preferências não fecha o app: usa os padrões.
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _setEngine(String value) async {
    setState(() => _engine = value);
    try {
      await _prefs.savePlayerEnginePreference(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível salvar esta configuração.')),
        );
      }
    }
  }

  Future<void> _toggleCasting(bool value) async {
    setState(() => _castingEnabled = value);
    try {
      await _prefs.saveCastingEnabled(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível salvar esta configuração.')),
        );
      }
    }
  }

  Future<void> _toggleLandscape(bool value) async {
    setState(() => _landscape = value);
    try {
      await _prefs.saveFullscreenLandscape(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível salvar esta configuração.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Configurações')),
    body: !_loaded
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: [
              const _SectionTitle('Reprodução'),
              _Subtitle('Preferência de reprodução de canais', subtitle:
                  'O modo automático tenta o player do Android e, se não funcionar, usa o motor de compatibilidade.'),
              ...(['automatic', 'media3', 'libvlc']).map<Widget>((value) => ListTile(
                    title: Text({'automatic': 'Automático (recomendado)', 'media3': 'Player do Android', 'libvlc': 'Compatibilidade (VLC)'}[value]!),
                    leading: CircleAvatar(
                      radius: 10,
                      backgroundColor: _engine == value ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline,
                    ),
                    trailing: const Icon(Icons.play_circle_outline),
                    selected: _engine == value,
                    onTap: () => _setEngine(value),
                  )),
              _Divider(),
              const _SectionTitle('Transmissão para a TV'),
              SwitchListTile(
                title: const Text('Transmitir para TV (DLNA e Cast)'),
                subtitle: const Text('O serviço só inicia quando você pedir envio para uma TV. A TV precisa estar na mesma rede Wi-Fi.'),
                secondary: const Icon(Icons.cast),
                value: _castingEnabled,
                onChanged: _toggleCasting,
              ),
              _Divider(),
              const _SectionTitle('Tela cheia'),
              SwitchListTile(
                title: const Text('Modo paisagem na tela cheia'),
                subtitle: const Text('Ao ampliar o vídeo, a tela gira para o lado.'),
                secondary: const Icon(Icons.screen_rotation),
                value: _landscape,
                onChanged: _toggleLandscape,
              ),
              _Divider(),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text('Sobre o StreamBox', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('Player independente de IPTV. O StreamBox não fornece canais, listas ou conteúdo: tudo é adicionado pelo usuário, que deve usar apenas conteúdo autorizado.'),
              ),
              const SizedBox(height: 8),
            ],
          ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _Subtitle extends StatelessWidget {
  const _Subtitle(this.text, {this.subtitle});
  final String text;
  final String? subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
      if (subtitle != null) const SizedBox(height: 2),
      if (subtitle != null) Text(subtitle!, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
    ]),
  );
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => const Divider(indent: 16, endIndent: 16);
}
