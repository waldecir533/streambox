import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Relatório de diagnóstico do aplicativo, exportável para análise.
///
/// Grava localmente: tipo e tamanho da lista, fase em que a operação falhou,
/// quantidade de canais analisados e salvos, stack trace, memória aproximada,
/// versão do aplicativo e do Android — **removendo automaticamente** usuário,
/// senha, tokens e URLs completas (mantém apenas o domínio).
class DiagnosticService {
  /// Estado da importação para o relatório (números, sem credenciais).
  static ImportDiagnostic importDiagnostic = ImportDiagnostic.empty();

  /// Sanitiza um texto removendo usuário/senha/tokens e URLs completas
  /// (mantém apenas o domínio) — aplicado a stack traces e mensagens.
  static String sanitize(String text) {
    String result = text;
    // Credenciais em URLs: http://user:pass@host -> http://***@host
    result = result.replaceAllMapped(
      RegExp(r'(https?://)[^@/\s]+@', caseSensitive: false),
      (match) => '${match.group(1)}***@',
    );
    // Tokens/senhas em parâmetros e cabeçalhos: token=..., password=..., key=...
    result = result.replaceAllMapped(
      RegExp('((password|passwd|pass|token|secret|key|auth|credential)[=:])([^&\\s"\\u0027=]{3,})', caseSensitive: false),
      (match) => '${match.group(1)}***',
    );
    // URLs completas -> apenas o domínio
    result = result.replaceAllMapped(
      RegExp('https?://[A-Za-z0-9.\\-]+(:\\d+)?(/[^\\s"\\u0027=)]*)?', caseSensitive: false),
      (match) {
        final full = match.group(0)!;
        final hostMatch = RegExp(r'https?://([A-Za-z0-9.\-]+)(:\d+)?').firstMatch(full);
        final host = hostMatch?.group(1) ?? 'servidor';
        return 'http://$host***';
      },
    );
    // Padrões comuns de token base64/UUID isolados
    result = result.replaceAllMapped(
      RegExp(r'\b[A-Za-z0-9_\-]{40,}\b'),
      (_) => '***',
    );
    return result;
  }

  /// Grava o relatório de diagnóstico na pasta de dados do aplicativo,
  /// acumulando entradas recentes e removendo qualquer credencial.
  static Future<File> writeReport() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/diagnostic_report.txt');

    final sb = StringBuffer();
    sb.writeln('=== StreamBox — Relatório de Diagnóstico ===');
    sb.writeln('Data: ${DateTime.now().toIso8601String()}');
    sb.writeln('Plataforma: ${defaultTargetPlatform.name} (Android)');
    try {
      sb.writeln('Versão Android: ${Platform.operatingSystemVersion}');
    } catch (_) {
      sb.writeln('Versão Android: indisponível');
    }
    sb.writeln('Versão do StreamBox: 0.6.0+10');

    // Memória aproximada em uso.
    try {
      final vmStats = ProcessInfo.currentRss;
      sb.writeln('Memória do processo (RSS): ${(vmStats / (1024 * 1024)).toStringAsFixed(1)} MB');
    } catch (_) {
      sb.writeln('Memória do processo: indisponível');
    }

    final diag = importDiagnostic;
    sb.writeln('--- Importação da lista ---');
    sb.writeln('Fonte: ${sanitize(diag.sourceDescription)}');
    sb.writeln('Tipo: ${diag.sourceType}');
    sb.writeln('Tamanho do arquivo: ${diag.fileSizeDescription}');
    sb.writeln('Fase da falha: ${diag.failurePhase ?? 'nenhuma (ok)'}');
    sb.writeln('Canais analisados: ${diag.analyzedCount}');
    sb.writeln('Canais salvos: ${diag.savedCount}');
    sb.writeln('Linhas ignoradas (inválidas): ${diag.skippedLines}');

    if (diag.errorMessage != null) {
      sb.writeln('--- Exceção (sanitizada) ---');
      sb.writeln(sanitize(diag.errorMessage!));
    }
    if (diag.stackTrace != null) {
      sb.writeln('--- Stack trace (sanitizado) ---');
      sb.writeln(sanitize(diag.stackTrace!));
    }

    final report = sb.toString();
    await file.writeAsString(report);
    return file;
  }

  /// Compartilha o relatório por e-mail/aplicativos de arquivos, se
  /// disponível na plataforma. Retorna a descrição do resultado.
  static Future<String> shareReport() async {
    final file = await writeReport();
    if (!Platform.isAndroid) {
      return 'Relatório gravado em: ${file.path}';
    }
    try {
      final result = await Process.run(
        'am',
        [
          'start',
          '-a', 'android.intent.action.SEND',
          '-t', 'text/plain',
          '--es', 'android.intent.extra.STREAM', 'file://${file.path}',
        ],
      );
      if (result.exitCode == 0) {
        return 'Relatório pronto para envio.';
      }
    } catch (_) {
      // Fallback: apenas informar o caminho.
    }
    return 'Relatório gravado em: ${file.path}';
  }
}

/// Números da importação em andamento (sem nenhuma credencial).
class ImportDiagnostic {
  ImportDiagnostic.empty()
      : sourceType = 'não iniciada',
        sourceDescription = '-',
        fileSizeDescription = '-',
        analyzedCount = 0,
        savedCount = 0,
        skippedLines = 0,
        failurePhase = null,
        errorMessage = null,
        stackTrace = null;

  factory ImportDiagnostic({
    required String sourceType,
    required String sourceDescription,
    required String fileSizeDescription,
    required int analyzedCount,
    required int savedCount,
    required int skippedLines,
    String? failurePhase,
    String? errorMessage,
    String? stackTrace,
  }) => ImportDiagnostic.empty()
    ..sourceType = sourceType
    ..sourceDescription = sourceDescription
    ..fileSizeDescription = fileSizeDescription
    ..analyzedCount = analyzedCount
    ..savedCount = savedCount
    ..skippedLines = skippedLines
    ..failurePhase = failurePhase
    ..errorMessage = errorMessage
    ..stackTrace = stackTrace;

  String sourceType;
  String sourceDescription;
  String fileSizeDescription;
  int analyzedCount;
  int savedCount;
  int skippedLines;
  String? failurePhase;
  String? errorMessage;
  String? stackTrace;

  factory ImportDiagnostic.fromJson(Map<String, dynamic> json) => ImportDiagnostic.empty();
  Map<String, dynamic> toJson() => const {};
}
