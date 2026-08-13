# StreamBox — Handoff

## Estado desta entrega

- Versão: `0.8.0+13`
- Branch: `agent/streambox-experience-v1`
- Baseline funcional preservado: `520dab8`
- Base recomendada para integração: `agent/visible-dlna-test-screen` (PR #9)

## Implementado

- teste adicional de regressão para cache, grupo original, URL e cabeçalhos;
- navegação principal em português do Brasil;
- barra inferior em celulares com destinos secundários em **Mais**;
- `NavigationRail` adaptável em tablets e telas largas;
- destinos Início, TV ao vivo, Filmes, Séries, Esportes, Favoritos,
  Histórico, Pesquisa e Configurações;
- estados vazios com orientação e ação, sem carregamento infinito;
- tela funcional de TV ao vivo integrada sem modificar o importador ou player.

## Núcleo preservado

Nesta etapa não foram alterados:

- `lib/services/m3u_parser.dart`;
- `lib/services/playlist_service.dart`;
- `lib/services/xtream_service.dart`;
- `lib/services/preferences_service.dart`;
- `lib/screens/player_screen.dart`;
- serviços Google Cast e DLNA.

## Validação executada

GitHub Actions run `31652672290`:

- `flutter analyze`: aprovado;
- `flutter test`: aprovado;
- APK release: aprovado;
- AAB release: aprovado.

O teste manual obrigatório em Android físico não foi executado porque nenhum
aparelho/emulador foi disponibilizado nesta sessão. Não considerar essa etapa
concluída até executar o roteiro informado pelo proprietário.

## Pendências reais

Esta é a primeira entrega incremental. Permanecem pendentes, nesta ordem:

1. gerenciamento isolado de múltiplas playlists;
2. personalização persistente de grupos e canais;
3. pesquisa global com normalização de acentos e debounce;
4. catálogos progressivos de TV, filmes, séries e esportes;
5. configurações e diagnóstico;
6. extensões seguras do player e EPG;
7. gravações/downloads atrás de feature flag;
8. TMDB opcional;
9. auditoria de acessibilidade e desempenho;
10. roteiro manual completo em Android.

Cada item deve permanecer em commit/PR reversível e só avançar com testes de
importação e reprodução aprovados.
