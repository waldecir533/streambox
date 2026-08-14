// Testes da Tarefa "reconhecimento da fonte" (v0.7.7+):
// - preview sanitizado do conteúdo recebido entra no relatório
// - detecção de respostas de erro de painéis (SourceType.panelError)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:streambox/services/diagnostic_service.dart';
import 'package:streambox/services/m3u_parser.dart';

class MockPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  Directory? temp;
  @override
  Future<String?> getApplicationDocumentsPath() async => temp!.path;
}

void main() {
  late Directory dir;
  final mock = MockPathProvider();
  setUpAll(() {
    PathProviderPlatform.instance = mock;
  });
  setUp(() {
    dir = Directory.systemTemp.createTempSync('sb_prev_');
    mock.temp = dir;
    DiagnosticService.importDiagnostic = ImportDiagnostic.empty();
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('inspeção reconhece resposta de erro típica de painel Xtream', () {
    final inspection = M3uParser.inspect('User authentication failed.');
    expect(inspection.type, SourceType.panelError);
    expect(inspection.message, contains('get.php'));
  });

  test('inspeção reconhece "Not found" como erro de painel', () {
    expect(
      M3uParser.inspect('Not found').type,
      SourceType.panelError,
    );
  });

  test('conteúdo sem reconhecimento continua unknown', () {
    expect(
      M3uParser.inspect('abcdef1234567890abcdef').type,
      SourceType.unknown,
    );
  });

  test('relatório grava preview sanitizado sem credenciais', () async {
    DiagnosticService.importDiagnostic
      ..failurePhase = 'reconhecimento da fonte'
      ..detectedSource = SourceType.unknown.name
      ..previewContent =
          'User authentication failed.\nSenha expirada http://painel.com:8080 '
          'password=senha123token456';
    final file = await DiagnosticService.writeReport();
    final text = await file.readAsString();
    // O início do conteúdo recebido aparece no relatório.
    expect(text, contains('--- Início do conteúdo recebido (sanitizado) ---'));
    expect(text, contains('User authentication failed'));
    // Credenciais e URLs completas nunca aparecem.
    expect(text.contains('senha123token456'), isFalse);
    expect(text.contains('8080'), isFalse);
    // A versão no relatório confirma o build.
    expect(text, contains('Versão do StreamBox: 0.7.7'));
  });
}
