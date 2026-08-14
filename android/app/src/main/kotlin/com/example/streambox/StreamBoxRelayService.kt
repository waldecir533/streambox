package com.example.streambox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service dedicado ao servidor HTTP do relay DLNA/proxy do
 * StreamBox. Enquanto uma transmissão DLNA (ou gravação via proxy) estiver
 * ativa, este service mantém o processo elevado em prioridade, evitando que
 * o Android suspenda o socket do servidor local em segundo plano — a causa
 * provável do erro "servidor não responde nem à própria URL".
 *
 * Ciclo de vida controlado pelo app Flutter via método de canal
 * "relay_service": start (foreground) quando a TV/relay entra em uso e
 * stopSelf quando não há mais nenhuma sessão ativa.
 */
class StreamBoxRelayService : Service() {

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME)
        val text = if (!channelName.isNullOrBlank()) {
            "Transmitindo: $channelName"
        } else {
            "Relay de mídia ativo"
        }

        val notification: Notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("StreamBox")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("StreamBox")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setOngoing(true)
                .build()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            if (manager?.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                )
                channel.description =
                    "Mantém o servidor local do relay DLNA ativo enquanto " +
                        "uma TV estiver reproduzindo."
                channel.setShowBadge(false)
                manager?.createNotificationChannel(channel)
            }
        }
    }

    companion object {
        const val CHANNEL_ID = "streambox_relay"
        private const val CHANNEL_NAME = "Relay de mídia (StreamBox)"
        private const val NOTIFICATION_ID = 47100
        const val ACTION_START = "com.example.streambox.relay.START"
        const val ACTION_STOP = "com.example.streambox.relay.STOP"
        const val EXTRA_CHANNEL_NAME = "channel_name"

        private var running: Boolean = false

        /** Verdadeiro enquanto o service estiver em foreground (para testes). */
        @JvmStatic
        fun isRunning(): Boolean = running

        @JvmStatic
        fun start(context: Context, channelName: String? = null) {
            val intent = Intent(context, StreamBoxRelayService::class.java)
            intent.action = ACTION_START
            if (!channelName.isNullOrBlank()) {
                intent.putExtra(EXTRA_CHANNEL_NAME, channelName)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        @JvmStatic
        fun stop(context: Context) {
            val intent = Intent(context, StreamBoxRelayService::class.java)
            intent.action = ACTION_STOP
            context.startService(intent)
        }
    }
}
