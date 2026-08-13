import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:streambox/services/diagnostic_service.dart';

/// Garante que o relatório de diagnóstico pode ser lido como texto
/// (para exibição na tela com botão Copiar), sem nunca conter credenciais.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('streambox_diag_');
    PathProviderPlatform.instance = _MockPathProvider(tempDir);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('reportText devolve o conteúdo completo sanitizado', () async {
    DiagnosticService.importDiagnostic = ImportDiagnostic.empty()
      ..failurePhase = 'download da lista'
      ..errorMessage =
          'SocketException: failed host lookup: servidor.exemplo.com'
      ..httpStatusCode = 404
      ..networkError = 'DNS não resolveu';

    final text = await DiagnosticService.reportText();

    expect(text, contains('=== StreamBox — Relatório de Diagnóstico ==='));
    expect(text, contains('Versão do StreamBox: 0.7.6'));
    expect(text, contains('Código HTTP: 404'));
    expect(text, contains('Erro de rede: DNS não resolveu'));
    expect(text, contains('Fase da falha: download da lista'));
    expect(text, contains('Exceção (sanitizada)'));
    // O sanitize remove credenciais de URLs completas (com schema http://);
    // a exceção sanitizada não pode conter senha nem credenciais.
    expect(text, isNot(contains('password')));
    expect(text, isNot(contains('http://')));
  });

  test('reportText não depende do canal nativo do Android', () async {
    // Sem registrar o channel share_report: o compartilhamento falharia,
    // mas o texto deve continuar disponível na tela.
    final text = await DiagnosticService.reportText();
    expect(text, isNotEmpty);
    expect(text, contains('StreamBox'));
  });
}

class _MockPathProvider extends PathProviderPlatform {
  _MockPathProvider(this.directory);
  final Directory directory;

  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;
}
