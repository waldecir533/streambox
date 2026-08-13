package com.example.streambox

import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Controle do foreground service do relay DLNA pelo app Flutter:
    // 'start' mantém o servidor HTTP local vivo em prioridade elevada
    // enquanto uma TV estiver reproduzindo; 'stop' encerra o service quando
    // não há mais nenhuma sessão ativa.
    private val relayChannel: MethodChannel by lazy {
        MethodChannel(
            requireNotNull(flutterEngine).dartExecutor.binaryMessenger,
            "relay_service",
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val channelName =
                            call.argument<String>("channel_name")
                        StreamBoxRelayService.start(
                            this@MainActivity,
                            channelName,
                        )
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

    // Compartilhamento do relatório de diagnóstico via menu nativo do
    // Android (Intent.ACTION_SEND): o FileProvider expõe o arquivo da pasta
    // de dados do app com permissão temporária, permitindo envio por
    // WhatsApp, e-mail e outros aplicativos.
    private val shareChannel: MethodChannel by lazy {
        MethodChannel(
            requireNotNull(flutterEngine).dartExecutor.binaryMessenger,
            "share_report",
        ).apply {
            setMethodCallHandler { call, result ->
                if (call.method != "share") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("file_path")
                if (path.isNullOrBlank()) {
                    result.error("invalid_path", "Caminho do arquivo ausente", null)
                    return@setMethodCallHandler
                }
                try {
                    val file = java.io.File(path)
                    if (!file.exists()) {
                        result.error("missing_file", "Arquivo não encontrado", null)
                        return@setMethodCallHandler
                    }
                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        this@MainActivity,
                        "$packageName.fileprovider",
                        file,
                    )
                    val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(android.content.Intent.EXTRA_STREAM, uri)
                        putExtra(
                            android.content.Intent.EXTRA_SUBJECT,
                            "Relatório de diagnóstico StreamBox",
                        )
                        addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    startActivity(
                        android.content.Intent.createChooser(intent, "Enviar relatório de diagnóstico"),
                    )
                    result.success(true)
                } catch (error: Throwable) {
                    result.error("share_failed", error.toString(), null)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Registra os canais quando o engine é criado — assim eles existem
        // mesmo antes de qualquer chamada do Dart.
        relayChannel
        shareChannel
    }
}
