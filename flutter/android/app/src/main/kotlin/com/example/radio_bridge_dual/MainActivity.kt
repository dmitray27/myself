package com.example.radio_bridge_dual

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "esp32/network"

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        ChatForegroundService.clearExitState()
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindToWifi" -> bindToWifi(result)
                    "unbind" -> {
                        unbind()
                        result.success(true)
                    }
                    "startService" -> {
                        startChatService()
                        result.success(true)
                    }
                    "stopService" -> {
                        stopService(Intent(this, ChatForegroundService::class.java))
                        result.success(true)
                    }
                    "setServiceConnected" -> {
                        val connected = call.argument<Boolean>("connected") ?: false
                        ChatForegroundService.setConnected(connected)
                        result.success(true)
                    }
                    "closeApp" -> {
                        // Та же цепочка, что и «Выйти» из уведомления:
                        // снимаем Wi-Fi, останавливаем foreground-сервис с удалением
                        // уведомления и закрываем активность полностью.
                        unbind()
                        startService(
                            Intent(this, ChatForegroundService::class.java)
                                .setAction(ChatForegroundService.ACTION_EXIT)
                        )
                        closeApp()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Сервис держит процесс живым при погашенном экране, иначе ОС
    // замораживает его и WebSocket к плате перестаёт читать кадры
    private fun startChatService() {
        val intent = Intent(this, ChatForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun bindToWifi(result: MethodChannel.Result) {
        val cm = connectivityManager
        if (cm == null) {
            result.success(false)
            return
        }

        // Снимаем предыдущую привязку/колбэк, чтобы они не накапливались
        // при периодическом вызове раз в 5 с из _checkConnection()
        unbind()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // НЕ добавляем NET_CAPABILITY_INTERNET: сеть ESP32 без интернета,
            // иначе система откажет в выдаче сети
            .build()

        var reported = false

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    cm.bindProcessToNetwork(network)
                } else {
                    @Suppress("DEPRECATION")
                    ConnectivityManager.setProcessDefaultNetwork(network)
                }
                if (!reported) {
                    reported = true
                    // Колбэк приходит в фоновом потоке, а MethodChannel.Result
                    // обязан вызываться в главном потоке
                    runOnUiThread { result.success(ok) }
                }
            }

            override fun onUnavailable() {
                if (!reported) {
                    reported = true
                    runOnUiThread { result.success(false) }
                }
            }
        }

        networkCallback = callback
        // requestNetwork с таймаутом, чтобы onUnavailable точно пришёл (API 26+)
        cm.requestNetwork(request, callback, 8000)
    }

    private fun unbind() {
        val cm = connectivityManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            cm.bindProcessToNetwork(null)
        } else {
            @Suppress("DEPRECATION")
            ConnectivityManager.setProcessDefaultNetwork(null)
        }
        networkCallback?.let {
            try {
                cm.unregisterNetworkCallback(it)
            } catch (e: Exception) {
                // колбэк мог быть уже снят — игнорируем
            }
        }
        networkCallback = null
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        unbind()
        super.onDestroy()
    }

    companion object {
        private var instance: MainActivity? = null

        // «Выйти» в уведомлении гасит и приложение: иначе экран остался бы
        // жив, а его опрос платы через пару секунд поднял бы сервис заново
        fun closeApp() {
            instance?.finishAndRemoveTask()
        }
    }
}