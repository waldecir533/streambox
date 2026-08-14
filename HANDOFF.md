# StreamBox — Documento de Entrega (HANDOFF)

**Versão entregue:** 0.7.0+12 (build 12)
**Branch:** `feat/phase1-stable` (último commit: `4bff56e`)
**Pull Request:** [#13](https://github.com/waldecir533/streambox/pull/13)
**CI (GitHub Actions):** workflow `build-android-apk.yml`
**APK release:** artifact **"StreamBox-atual-12.apk"** no run [31660547431](https://github.com/waldecir533/streambox/actions/runs/31660547431)

---

## 1. Causa comprovada do fechamento (diagnóstico real, não suposição)

O defeito "não carrega a lista → o aplicativo fecha" foi reproduzido em ambiente controlado com um servidor de teste local e um harness que executa o fluxo exato do aplicativo (download → análise → gravação → restauração), medindo memória em cada fase.

| Componente | Problema encontrado | Efeito no aparelho |
|---|---|---|
| `lib/services/m3u_parser.dart` (v10) | `StreamController` nunca era fechado no fluxo feliz → `Future` nunca completava → travamento no fim da análise | Aparece como "Não foi possível carregar a lista" depois de 100% |
| `lib/services/preferences_service.dart` (v10) | Lista inteira serializada como JSON gigante no `SharedPreferences` | Lista grande → **OutOfMemoryError** → Android mata o processo → "StreamBox apresenta falhas contínuas" |
| Memória em teste | 200 mil canais atingiram **~1,1 GB no pico** durante o download | Em celulares de 3–4 GB isso vira OOM e fechamento contínuo |

A correção eliminou as duas causas raiz em vez de contornar o sintoma.

## 2. Fase 1 — Importação estável (v0.6.1+11)

**Detecção do tipo de entrada** (`lib/services/m3u_parser.dart`, `lib/services/playlist_service.dart`): playlist M3U (`#EXTM3U` + `#EXTINF`), stream HLS individual (`#EXT-X-TARGETDURATION` / `#EXT-X-STREAM-INF` — stream com `#EXTINF` de segmento não é confundido com playlist), Xtream e resposta inválida. Conteúdo não reconhecível nunca abre exceção bruta: o aplicativo mostra a mensagem correspondente e permanece aberto.

**Downloader robusto**: timeout de 45 s, gzip e codificação automática (UTF-8 com `malformedReplacement`), `User-Agent` configurável, cancelamento por `CancelToken`, e mensagens específicas por causa (DNS, TLS, timeout, 401/403, 404, 429, 5xx, HTML de bloqueio/Cloudflare, corpo vazio, redirecionamento). Nenhuma credencial, token ou URL completa aparece em log ou relatório.

**Parser M3U Plus completo**: além do anterior, lê `tvg-name`, `tvg-language`, `tvg-country`, `tvg-url`/`x-tvg-url`, `catchup`/`catchup-source`, aceita aspas simples e duplas, e processa em lote incremental com progresso por chunk — a lista nunca é duplicada na memória nem dividida em mapas intermediários. Linhas malformadas são **ignoradas individualmente** e o contador de entradas ignoradas vai para o resumo; o aplicativo nunca fecha por isso.

**Banco seguro** (`lib/services/channels_store.dart`): gravação **transacional** — os canais novos são escritos em arquivo temporário e só substituem o arquivo atual quando tudo terminou; se algo falhar no meio, a lista anterior permanece intacta. Favoritos, histórico e grupos ocultos não são apagados. A leitura é incremental em lotes de 1000 canais, sem `readAsString` + `split` + `toList`.

**Resumo de importação** (`lib/models/import_summary.dart` e `home_screen.dart`): ao concluir, o aplicativo mostra canais importados, filmes, séries, esportes, TV ao vivo, subtemas, grupos criados, linhas ignoradas, tipo detectado e tempo — com botão **"Ver detalhes"**.

**Diagnóstico sanitizado** (`lib/services/diagnostic_service.dart`): "Exportar relatório de diagnóstico" grava localmente fase da falha, contagem analisada/salva, tipo detectado, stack trace e versão — com remoção automática de usuário, senha, tokens e URLs completas.

## 3. Fase 2 — Padrão brasileiro

**`lib/services/library_section_service.dart`**: deriva automaticamente as seções **TV ao vivo, Filmes, Séries e Esportes** a partir do `group-title` original de cada canal, respeitando sempre a categoria da lista (nunca renomeia nada). Reconhece palavras-chave em português e inglês (abertos, filmes, cinema, séries, esportes, futebol, kids, infantil etc.). O `ImportSummary` usa o mesmo classificador, então o resumo da importação já mostra as contagens por seção.

## 4. Fase 3 — Telas e preferências em português

| Tela | Conteúdo |
|---|---|
| **Início** | Barra de abas Início / TV ao vivo / Filmes / Séries / Esportes, chips de seção com contagens, subtemas (Notícias, Infantil, Música, Religioso), busca e pesquisa, favoritos e histórico |
| **Reprodução** | Player Media3 com fallback automático para VLC (12 s de timeout), tela cheia com rotação opcional, velocidade, seleção de enquadramento, Cast/DLNA sob demanda |
| **Gerenciar Playlists** | Lista e acesso Xtream salvos (credenciais mascaradas), atualizar lista e remover acesso sem perder favoritos/histórico |
| **Configurações** | Motor do player (Automático / Android / VLC), transmissão para TV (só inicia quando pedida), rotação na tela cheia, sobre |

O player agora respeita a preferência do usuário e a opção de rotação em `lib/services/preferences_service.dart`. Nenhum serviço (proxy, DLNA, Cast) inicializa automaticamente.

## 5. Qualidade e evidência

O pipeline completo foi executado com sucesso: `flutter analyze` com **zero issues**, **40 testes** (incluindo estabilidade com listas de 25 mil e 200 mil canais, HLS, Cloudflare, erros HTTP 401/404/429/503, timeout, cancelamento, transação do banco e restauração incremental) e compilação release (`flutter build apk --release`). A reprodução em memória comprovou o teto de ~1,1 GB para listas de 200 mil canais — com o novo fluxo, a lista não precisa mais ser mantida duplicada.

**Testes manuais recomendados no aparelho:** importar uma lista real por URL (pequena e grande), navegar pelas abas e seções, abrir um canal autorizado, voltar, fechar e reabrir o aplicativo (canais permanecem salvos), exportar o relatório de diagnóstico e remover/re-importar a lista (a anterior continua funcionando até a nova terminar).

## 6. Arquivos alterados (principais)

| Arquivo | Mudança |
|---|---|
| `lib/services/m3u_parser.dart` | Parser M3U Plus completo, detecção de tipo, lotes incrementais, `SourceInspection` |
| `lib/services/playlist_service.dart` | `importFromUrl`/`importFromFile` com `ImportResult`, erros por causa, nunca sobe exceção bruta |
| `lib/services/channels_store.dart` | Gravação transacional + leitura incremental em lotes |
| `lib/services/preferences_service.dart` | Usa `ChannelsStore`; preferências de player, transmissão, rotação e Xtream |
| `lib/services/library_section_service.dart` | Classificação TV ao vivo / Filmes / Séries / Esportes |
| `lib/services/diagnostic_service.dart` | Campos de tipo detectado e tempo de importação |
| `lib/models/channel.dart`, `lib/models/import_summary.dart` | Campos M3U Plus e estatísticas do resumo |
| `lib/screens/home_screen.dart` | Abas por seção, chips com contagens, resumo com "Ver detalhes" |
| `lib/screens/player_screen.dart` | Preferência de motor e rotação configuráveis |
| `lib/screens/playlist_manager_screen.dart`, `lib/screens/settings_screen.dart` (novos) | Gerenciar Playlists e Configurações |
| `lib/widgets/channel_list_tile.dart` (novo) | Linha de canal reutilizável |
| `lib/main.dart` | Bootstrap protegido (v10) |
| `test/*.dart` (novos/atualizados) | 40 testes unitários e de estabilidade |
| `.github/workflows/build-android-apk.yml` | CI com APK/AAB via `--android-skip-build-dependency-validation` |

## 7. Privacidade

Nenhuma credencial do usuário foi usada em testes ou registros. O aplicativo mascara credenciais nas telas e o relatório de diagnóstico remove automaticamente usuário, senha, tokens e URLs completas antes de gravar.
