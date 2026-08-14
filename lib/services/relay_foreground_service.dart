import 'dart:async';
import 'package:flutter/services.dart';

/// Controle do foreground service Android do relay DLNA a partir do Dart.
/// O service nativo ([StreamBoxRelayService] no Android) mantém o servidor
/// HTTP local elevado em prioridade enquanto houver transmissão DLNA
/// ativa, evitando que o Android suspenda o socket em segundo plano.
class RelayForegroundService {
  static const MethodChannel _channel =
      MethodChannel('relay_service');

  static Future<void> start({String? channelName}) async {
    try {
      await _channel.invokeMethod<void>(
        'start',
        channelName != null && channelName.isNotEmpty
            ? <String, String>{'channel_name': channelName}
            : null,
      );
    } catch (_) {
      // Falha no service nunca deve travar o app: o relay continua
      // funcionando em processos normais (sem prioridade elevada).
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Ignora — a parada é opportunistica.
    }
  }
}
