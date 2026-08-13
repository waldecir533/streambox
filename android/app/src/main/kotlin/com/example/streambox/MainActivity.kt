package com.example.streambox

import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Controle do foreground service do relay DLNA pelo app Flutter:
    // 'start' mantém o servidor HTTP local vivo em prioridade elevada
    // enquanto uma TV estiver reproduzindo; 'stop' encerra o service quando
    // não há mais nenhuma sessão ativa.
    private val relayChannel: MethodChannel by lazy {
        MethodChannel(binaryMessenger, "relay_service").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val channelName = call.argument<String>("channel_name")
                        StreamBoxRelayService.start(this@MainActivity, channelName)
                        result.success(null)
                    }
                    "stop" -> {
                        StreamBoxRelayService.stop(this@MainActivity)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
