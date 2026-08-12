import 'package:flutter/material.dart';

import 'home_screen.dart';

enum AppSection {
  home,
  live,
  movies,
  series,
  sports,
  favorites,
  history,
  search,
  settings,
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppSection _section = AppSection.home;

  static const _primary = <AppSection>[
    AppSection.home,
    AppSection.live,
    AppSection.movies,
    AppSection.series,
    AppSection.sports,
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        if (wide) {
          return Scaffold(
            body: Row(
              children: [
                SafeArea(
                  child: NavigationRail(
                    extended: constraints.maxWidth >= 1000,
                    selectedIndex: AppSection.values.indexOf(_section),
                    onDestinationSelected: (index) =>
                        setState(() => _section = AppSection.values[index]),
                    destinations: AppSection.values
                        .map(
                          (section) => NavigationRailDestination(
                            icon: Icon(_icon(section)),
                            selectedIcon: Icon(_icon(section, selected: true)),
                            label: Text(_label(section)),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _content()),
              ],
            ),
          );
        }

        final selectedPrimary = _primary.indexOf(_section);
        return Scaffold(
          body: _content(),
          bottomNavigationBar: NavigationBar(
            selectedIndex: selectedPrimary < 0 ? _primary.length : selectedPrimary,
            onDestinationSelected: (index) {
              if (index < _primary.length) {
                setState(() => _section = _primary[index]);
              } else {
                _showMore();
              }
            },
            destinations: [
              for (final section in _primary)
                NavigationDestination(
                  icon: Icon(_icon(section)),
                  selectedIcon: Icon(_icon(section, selected: true)),
                  label: _label(section),
                ),
              const NavigationDestination(
                icon: Icon(Icons.more_horiz),
                selectedIcon: Icon(Icons.more),
                label: 'Mais',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _content() => switch (_section) {
        AppSection.live => const HomeScreen(embedded: true),
        AppSection.home => _SectionPlaceholder(
            title: 'Início',
            icon: Icons.home_outlined,
            message:
                'Seus favoritos, itens recentes e atalhos aparecerão aqui quando houver conteúdo.',
            actionLabel: 'Ir para TV ao vivo',
            onAction: () => setState(() => _section = AppSection.live),
          ),
        AppSection.movies => const _SectionPlaceholder(
            title: 'Filmes',
            icon: Icons.movie_outlined,
            message: 'Nenhum filme identificado nas fontes ativas.',
          ),
        AppSection.series => const _SectionPlaceholder(
            title: 'Séries',
            icon: Icons.video_library_outlined,
            message: 'Nenhuma série identificada nas fontes ativas.',
          ),
        AppSection.sports => const _SectionPlaceholder(
            title: 'Esportes',
            icon: Icons.sports_soccer,
            message: 'Os eventos da playlist e do EPG aparecerão aqui.',
          ),
        AppSection.favorites => const _SectionPlaceholder(
            title: 'Favoritos',
            icon: Icons.star_outline,
            message: 'Seus conteúdos favoritos aparecerão aqui.',
          ),
        AppSection.history => const _SectionPlaceholder(
            title: 'Histórico',
            icon: Icons.history,
            message: 'Os conteúdos reproduzidos recentemente aparecerão aqui.',
          ),
        AppSection.search => const _SectionPlaceholder(
            title: 'Pesquisa',
            icon: Icons.search,
            message: 'Use a pesquisa para encontrar conteýo em todas as seções.',
          ),
        AppSection.settings => const _SectionPlaceholder(
            title: 'Configurações',
            icon: Icons.settings_outlined,
            message: 'Preferências do StreamBox.',
          ),
      };

  Future<void> _showMore() async {
    final selected = await showModalBottomSheet<AppSection>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final section in const [
              AppSection.favorites,
              AppSection.history,
              AppSection.search,
              AppSection.settings,
            ])
              ListTile(
                leading: Icon(_icon(section)),
                title: Text(_label(section)),
                selected: _section == section,
                onTap: () => Navigator.pop(context, section),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) setState(() => _section = selected);
  }

  static String _label(AppSection section) => switch (section) {
        AppSection.home => 'Início',
        AppSection.live => 'TV ao vivo',
        AppSection.movies => 'Filmes',
        AppSection.series => 'Séries',
        AppSection.sports => 'Esportes',
        AppSection.favorites => 'Favoritos',
        AppSection.history => 'Histórico',
        AppSection.search => 'Pesquisa',
        AppSection.settings => 'Configurações',
      };

  static IconData _icon(AppSection section, {bool selected = false}) =>
      switch (section) {
        AppSection.home => selected ? Icons.home : Icons.home_outlined,
        AppSection.live => selected ? Icons.live_tv : Icons.live_tv_outlined,
        AppSection.movies => selected ? Icons.movie : Icons.movie_outlined,
        AppSection.series =>
          selected ? Icons.video_library : Icons.video_library_outlined,
        AppSection.sports => Icons.sports_soccer,
        AppSection.favorites => selected ? Icons.star : Icons.star_outline,
        AppSection.history => Icons.history,
        AppSection.search => Icons.search,
        AppSection.settings =>
          selected ? Icons.settings : Icons.settings_outlined,
      };
}

class _SectionPlaceholder extends StatelessWidget {
  const _SectionPlaceholder({
    required this.title,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(message, textAlign: TextAlign.center),
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: 20),
                    FilledButton(onPressed: onAction, child: Text(actionLabel!)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
