package com.example.radio_bridge_dual

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "esp32/network"
    private val BIND_TIMEOUT_MS = 8000

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    // Result текущего bindToWifi, ещё не получившего ответа от ConnectivityManager
    private var pendingBindResult: MethodChannel.Result? = null
    private val bindTimeoutHandler = Handler(Looper.getMainLooper())

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
                        // Та же цепочка, что и «Выйти» из уведомления. Ответ Dart уходит
                        // до начала остановки: дальше процесс будет убит и отвечать
                        // будет некому.
                        result.success(true)
                        unbind()
                        ChatForegroundService.requestExit(this)
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
        // при повторном bind (смена IP или новая попытка подключения).
        // Предыдущий ожидающий Result завершаем, иначе Dart ждал бы его вечно
        unbind()
        pendingBindResult = result

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // НЕ добавляем NET_CAPABILITY_INTERNET: сеть ESP32 без интернета,
            // иначе система откажет в выдаче сети
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    cm.bindProcessToNetwork(network)
                } else {
                    @Suppress("DEPRECATION")
                    ConnectivityManager.setProcessDefaultNetwork(network)
                }
                // Колбэк приходит в фоновом потоке, а MethodChannel.Result
                // обязан вызываться в главном потоке
                runOnUiThread { completeBind(this, ok) }
            }

            override fun onUnavailable() {
                runOnUiThread { completeBind(this, false) }
            }

            override fun onLost(network: Network) {
                runOnUiThread { completeBind(this, false) }
            }
        }

        networkCallback = callback
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // С таймаутом система сама вызовет onUnavailable
            cm.requestNetwork(request, callback, BIND_TIMEOUT_MS)
        } else {
            // До API 26 перегрузки с таймаутом нет — считаем сами
            cm.requestNetwork(request, callback)
            bindTimeoutHandler.postDelayed({ completeBind(callback, false) }, BIND_TIMEOUT_MS.toLong())
        }
    }

    // Отвечаем Dart только если колбэк всё ещё актуальный: после unbind()
    // система может ещё доставить события старому колбэку
    private fun completeBind(callback: ConnectivityManager.NetworkCallback, ok: Boolean) {
        if (networkCallback !== callback) return
        bindTimeoutHandler.removeCallbacksAndMessages(null)
        pendingBindResult?.success(ok)
        pendingBindResult = null
    }

    private fun unbind() {
        bindTimeoutHandler.removeCallbacksAndMessages(null)
        pendingBindResult?.success(false)
        pendingBindResult = null
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