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
    // Связь подтверждает только Dart-движок через setServiceConnected():
    // до этого уведомление не имеет права обещать работающий чат
    private var connected = false

    override fun onCreate() {
        super.onCreate()
        instance = this

        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        // WIFI_MODE_FULL_HIGH_PERF устарел с API 29 и там игнорируется
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        val lock = wifiManager.createWifiLock(mode, WIFI_LOCK_TAG)
        lock.setReferenceCounted(false)
        lock.acquire()
        wifiLock = lock
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_EXIT) {
            exiting = true
            stopWithNotifications()
            return START_NOT_STICKY
        }

        createNotificationChannel()
        createAlertChannel()

        // Умирающий Dart-движок (опрос платы раз в 2 с) успевает поднять сервис
        // уже после «Выйти» — тогда сразу гасим его снова. startForeground
        // обязателен: иначе система убьёт процесс за неответ на
        // startForegroundService()
        if (exiting) {
            startForegroundNotification(false)
            stopWithNotifications()
            return START_NOT_STICKY
        }

        // intent == null — сервис поднят системой после убийства процесса:
        // Dart-движка нет, значит и связи нет
        if (intent == null) {
            desiredConnected = false
        }

        // Создание сервиса асинхронно: setConnected() мог прийти до onCreate,
        // когда instance ещё пуст
        connected = desiredConnected

        startForegroundNotification(connected)

        // Если систему всё же заставят убить процесс, сервис поднимется снова
        return START_STICKY
    }

    private fun startForegroundNotification(isConnected: Boolean) {
        val notification = buildNotification(isConnected)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // Смахнули из недавних: Dart-движок уничтожен вместе с активностью,
    // а вместе с ним и WebSocket — уведомление не должно врать о связи
    override fun onTaskRemoved(rootIntent: Intent?) {
        // Задача снимается и по кнопке «Выйти» — там пользователь ушёл
        // сознательно; heads-up без связи тоже был бы ложной тревогой
        if (connected && !exiting) {
            updateNotification(false)
            showAlert()
        }
        super.onTaskRemoved(rootIntent)
    }

    // Постоянное уведомление тихое: о разрыве после смахивания сообщаем
    // отдельным heads-up по каналу с высокой важностью
    private fun showAlert() {
        createAlertChannel()

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, ALERT_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_SOUND or Notification.DEFAULT_VIBRATE)
        }

        builder
            .setContentTitle("Радиочат прерван")
            .setContentText("Приложение закрыто, связь приостановлена")
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setAutoCancel(true)

        // Статус в шторке несёт постоянное уведомление, поэтому heads-up
        // снимается сам, успев показаться и прозвенеть
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setTimeoutAfter(ALERT_TIMEOUT_MS)
        }

        val notification = builder.build()

        notificationManager().notify(ALERT_NOTIFICATION_ID, notification)
    }

    private fun cancelAlert() {
        notificationManager().cancel(ALERT_NOTIFICATION_ID)
    }

    private fun stopWithNotifications() {
        desiredConnected = false
        // Сначала гасим экран приложения: живой Dart-движок продолжал бы
        // опрос платы и поднял бы сервис обратно
        MainActivity.closeApp()
        val manager = notificationManager()
        manager.cancel(ALERT_NOTIFICATION_ID)
        manager.cancel(NOTIFICATION_ID)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun openIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun updateNotification(isConnected: Boolean) {
        // После «Выйти» уведомление возвращать нельзя: закрываемый Dart-движок
        // ещё присылает setServiceConnected(false) из своего dispose()
        if (exiting) return
        connected = isConnected
        desiredConnected = isConnected
        if (isConnected) {
            cancelAlert()
        }
        notificationManager().notify(NOTIFICATION_ID, buildNotification(isConnected))
    }

    private fun buildNotification(isConnected: Boolean): Notification {
        val contentIntent = openIntent()

        val exitIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, ChatForegroundService::class.java).setAction(ACTION_EXIT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val text = if (isConnected) {
            "Соединение с ESP32 поддерживается"
        } else {
            "Соединение с ESP32 отсутствует — откройте приложение"
        }

        val title = if (isConnected) "Радиочат активен" else "Радиочат приостановлен"

        builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(contentIntent)
            .setOngoing(true)

        @Suppress("DEPRECATION")
        builder
            .addAction(android.R.drawable.ic_menu_view, "Открыть", contentIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Выйти", exitIntent)

        return builder.build()
    }

    override fun onDestroy() {
        instance = null
        cancelAlert()
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

    private fun createAlertChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = notificationManager()
        if (manager.getNotificationChannel(ALERT_CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            ALERT_CHANNEL_ID,
            "Прерывание радиочата",
            NotificationManager.IMPORTANCE_HIGH,
        )
        channel.description = "Сообщает, что чат перестал принимать сообщения"
        channel.enableVibration(true)
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "chat_connection"
        private const val ALERT_CHANNEL_ID = "chat_alert"
        private const val NOTIFICATION_ID = 1
        private const val ALERT_NOTIFICATION_ID = 2
        private const val ALERT_TIMEOUT_MS = 7_000L
        const val ACTION_EXIT = "com.example.radio_bridge_dual.ACTION_EXIT"
        private const val WIFI_LOCK_TAG = "radio_bridge_dual:wifi"

        // Сервис живёт в том же процессе, что и активность: текст уведомления
        // обновляем напрямую, а не через startService — из фона его не вызвать
        private var instance: ChatForegroundService? = null

        // Последнее состояние, о котором сообщил Dart-движок: сервис может
        // ещё не существовать, а после запуска уведомление должно совпадать
        // с реальной связью
        private var desiredConnected = false

        // Выход по кнопке «Выйти» уже начат
        private var exiting = false

        // Новый запуск приложения отменяет режим выхода
        fun clearExitState() {
            exiting = false
        }

        fun setConnected(isConnected: Boolean) {
            if (exiting) return
            desiredConnected = isConnected
            instance?.updateNotification(isConnected)
        }
    }
}
