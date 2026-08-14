import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/home_screen.dart';

/// Caminho do relatório de erros local. Nenhum dado sensível (URLs completas
/// de playlist, usuário ou senha) é gravado — apenas tipo, mensagem e pilha
/// das exceções, com carimbos de hora.
const String _crashLogFileName = 'crash_report.txt';

void _bootstrapErrors() {
  FlutterError.onError = (FlutterErrorDetails details) async {
    await _appendCrashLog(
      'flutter_error',
      details.exception,
      details.stack,
      details.context?.toString(),
    );
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    // _onPlatformError é async, mas onError espera retorno imediato; a
    // gravação do relatório roda em background sem bloquear a UI.
    unawaited(_appendCrashLog('platform_error', error, stack, null));
    return true; // não fecha o aplicativo
  };

  runZonedGuarded<void>(
    () => runApp(const StreamBoxApp()),
    (error, stack) => unawaited(
      _appendCrashLog('uncaught_zone', error, stack, null),
    ),
  );
}

Future<void> _appendCrashLog(
  String kind,
  Object error,
  StackTrace? stack,
  String? context,
) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_crashLogFileName');
    final buffer = StringBuffer()
      ..writeln('--- ${DateTime.now().toIso8601String()} [$kind] '
          '${context ?? ''}')
      ..writeln('type: ${error.runtimeType}')
      ..writeln('message: $error');
    if (stack != null) buffer.writeln('stack: $stack');
    // Guarda apenas os últimos relatórios para não crescer indefinidamente.
    final existing = file.existsSync() ? await file.readAsString() : '';
    final parts = existing.split('--- ').where((p) => p.trim().isNotEmpty);
    final recent = parts.length > 20 ? parts.skip(parts.length - 20) : parts;
    await file.writeAsString(
      '${recent.map((p) => '--- $p').join('')}${buffer.toString()}\n',
    );
  } catch (_) {
    // Falha ao gravar o relatório não deve gerar outra exceção.
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _bootstrapErrors();

  if (Platform.isAndroid || Platform.isIOS) {
    // Inicialização do Google Cast protegida: em aparelhos sem Google Play
    // Services (a maioria dos Samsung), a chamada nativa lança exceção.
    // O app continua funcionando normalmente sem transmissão Cast, em vez
    // de fechar sozinho na abertura.
    try {
      const appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
      final GoogleCastOptions options = Platform.isIOS
          ? IOSGoogleCastOptions(
              GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(
                appId,
              ),
              stopCastingOnAppTerminated: false,
            )
          : GoogleCastOptionsAndroid(
              appId: appId,
              stopCastingOnAppTerminated: false,
            );
      await GoogleCastContext.instance.setSharedInstanceWithOptions(options);
    } catch (error, stack) {
      await _appendCrashLog('cast_bootstrap', error, stack, null);
      // Segue sem Google Cast: o usuário pode navegar e assistir normalmente.
    }
  }
}

class StreamBoxApp extends StatelessWidget {
  const StreamBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'StreamBox',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
