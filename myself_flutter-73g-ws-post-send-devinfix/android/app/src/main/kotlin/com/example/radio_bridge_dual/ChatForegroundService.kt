package com.example.radio_bridge_dual

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder

// Пока сервис на переднем плане, ОС не замораживает процесс при погашенном
// экране: WebSocket к ESP32 продолжает читать кадры, а WifiLock не даёт
// уснуть самому радиомодулю Wi-Fi
class ChatForegroundService : Service() {

    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()

        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifiManager.createWifiLock(
            WifiManager.WIFI_MODE_FULL_HIGH_PERF,
            WIFI_LOCK_TAG,
        )
        lock.setReferenceCounted(false)
        lock.acquire()
        wifiLock = lock
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannel()

        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setContentTitle("Радиочат активен")
            .setContentText("Соединение с ESP32 поддерживается")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Если систему всё же заставят убить процесс, сервис поднимется снова
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        wifiLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        wifiLock = null
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Соединение с ESP32",
            // Постоянное уведомление сервиса не должно звучать: звук идёт
            // по каналу входящих сообщений
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "Держит соединение с платой при погашенном экране"
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "chat_connection"
        private const val NOTIFICATION_ID = 1
        private const val WIFI_LOCK_TAG = "radio_bridge_dual:wifi"
    }
}
