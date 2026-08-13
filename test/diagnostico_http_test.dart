import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:streambox/services/diagnostic_service.dart';
import 'package:streambox/services/playlist_service.dart';

/// Verifica que a falha de rede alimenta o relatório de diagnóstico com o
/// código HTTP e a classificação do erro — para análise remota sem
/// credenciais.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
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

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..statusCode = 404
        ..close();
    });
  });

  tearDown(() async {
    await server.close();
  });

  test('importação com HTTP 404 registra o código no diagnóstico',
      () async {
    DiagnosticService.importDiagnostic = ImportDiagnostic.empty();

    final service = PlaylistService(timeout: const Duration(seconds: 10));
    final result = await service.importFromUrl(
      'http://${server.address.address}:${server.port}/lista.m3u',
    );

    expect(result.message, contains('404'));
    expect(DiagnosticService.importDiagnostic.httpStatusCode, 404);
    expect(DiagnosticService.importDiagnostic.networkError, 'HTTP 404');

    final report = await DiagnosticService.writeReport();
    final text = await report.readAsString();
    expect(text, contains('Código HTTP: 404'));
    expect(text, contains('Erro de rede: HTTP 404'));

    service.dispose();
  });

  test('falha de conexão classifica o erro no diagnóstico', () async {
    DiagnosticService.importDiagnostic = ImportDiagnostic.empty();

    final service = PlaylistService(timeout: const Duration(seconds: 2));
    final result = await service.importFromUrl(
      'http://127.0.0.1:1/lista.m3u',
    );

    expect(result.message, contains('conectar'));
    expect(DiagnosticService.importDiagnostic.httpStatusCode, isNull);
    expect(DiagnosticService.importDiagnostic.networkError, isNotNull);

    final report = await DiagnosticService.writeReport();
    final text = await report.readAsString();
    expect(text, contains('Erro de rede:'));
    // O relatório nunca registra a URL completa nem credenciais.
    expect(text.toLowerCase(), isNot(contains('/lista.m3u')));

    service.dispose();
  });
}

class _MockPathProvider extends PathProviderPlatform {
  _MockPathProvider(this.directory);
  final Directory directory;

  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;
}
