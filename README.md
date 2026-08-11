# StreamBox 0.4

Player Flutter comercial para conteúdo fornecido e autorizado pelo próprio usuário. O aplicativo não contém canais, listas, filmes ou séries.

## Recursos implementados

- Entrada por URL M3U/M3U8.
- Entrada por servidor, usuário e senha Xtream Codes para canais ao vivo.
- Categorias, busca, logos e programa atual via EPG XMLTV.
- Favoritos e histórico salvos no aparelho.
- Media3/ExoPlayer principal com fallback automático para LibVLC.
- Escolha manual do motor, reconexão, velocidade, proporção e tela cheia.
- Interface Material 3 adaptável a celular, tablet e Android TV.
- Página de licenças de código aberto.
- Estrutura visual Premium pronta para receber Google Play Billing.
- GitHub Actions gerando APK de teste e AAB para Google Play.
- Google Cast/Chromecast com busca de TVs, transmissão direta e controles remotos.
- Atalho para o espelhamento de tela nativo do Android.

## Ainda depende de configuração externa

- Produtos e assinaturas no Google Play Billing.
- Chave de assinatura privada do AAB de produção.
- Logo, ícone, identidade visual e package id definitivos.
- Filmes, séries, catch-up, gravação, multiview e Picture-in-Picture ficam para as próximas versões.

## Observações do Google Cast

- Celular e TV precisam estar na mesma rede Wi-Fi.
- A TV precisa acessar diretamente a URL do vídeo; endereços locais ou protegidos por cabeçalhos privados podem exigir um receptor Cast personalizado.
- Alguns formatos aceitos pela LibVLC no celular podem não ser aceitos pelo Chromecast. Nesses casos, use o espelhamento nativo.

## Compilar localmente

```bash
flutter create --platforms=android --org com.streambox --project-name streambox .
python3 tool/configure_android.py
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter build appbundle --release
```

## Compilar pelo GitHub

Envie o conteúdo do projeto para um repositório. Em **Actions > Build Android APK**, execute o workflow. Ele entrega dois artefatos:

- `streambox-android-apk`: instalação para testes;
- `streambox-google-play-aab`: pacote para a Play Console (a assinatura definitiva ainda deve ser configurada antes da publicação).

## Uso responsável

O usuário deve possuir autorização para todo conteúdo carregado. Não use o nome, logotipo ou ícone do VLC na marca do StreamBox. As licenças das dependências aparecem na tela **Licenças** do aplicativo.
