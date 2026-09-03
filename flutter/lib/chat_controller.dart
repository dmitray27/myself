import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Message;
import 'package:http/http.dart' as http;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_connection.dart';
import 'chat_protocol.dart';
import 'message_store.dart';

export 'message_store.dart';
export 'chat_connection.dart';

/// Бизнес-логика радиочата: соединение, список сообщений, уведомления,
/// звук, Wi-Fi опрос и сверка эха.
///
/// Вынесена из [ChatScreen] ([screen_pro.dart]), чтобы UI отвечал только
/// за отрисовку, а состояние можно было тестировать и переиспользовать.
class ChatController extends ChangeNotifier {
  ChatController({
    this.esp32Address = '192.168.4.1',
    this.handshakeTimeout = const Duration(seconds: 8),
    this.closeTimeout = const Duration(seconds: 8),
    this.cancelTimeout = const Duration(seconds: 2),
    this.echoTimeout = const Duration(seconds: 6),
    this.maxMessages = 500,
    this.maxPendingEcho = 16,
    this.maxMessageLength = 300,
    this.maxNameLength = 15,
    this.notificationAsset = '73g_assets/sounds/notify.mp3',
    this.notificationChannelId = 'chat_messages',
    this.silentNotificationChannelId = 'chat_messages_silent',
    this.messageNotificationId = 1001,
    this.soundPrefKey = 'sound_enabled',
  });

  // ---------------- Config ----------------
  final String esp32Address;
  final Duration handshakeTimeout;
  final Duration closeTimeout;
  final Duration cancelTimeout;
  final Duration echoTimeout;
  final int maxMessages;
  final int maxPendingEcho;
  final int maxMessageLength;
  final int maxNameLength;
  final String notificationAsset;
  final String notificationChannelId;
  final String silentNotificationChannelId;
  final int messageNotificationId;
  final String soundPrefKey;

  // ---------------- Subsystems ----------------
  late final ChatConnection _connection;
  late final MessageStore _store;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final AudioPlayer _notificationPlayer = AudioPlayer();

  SharedPreferences? _prefs;

  // ---------------- State ----------------
  String _myName = 'User';
  bool _soundEnabled = true;
  bool _notificationsReady = false;
  bool _notificationsDenied = false;
  bool _isForeground = true;
  String _currentWifiName = 'Не подключено';
  String _networkHint = '';
  String _deviceIp = '';
  bool _isConnectAttemptRunning = false;

  Timer? _connectionTimer;
  final PollBackoff _pollBackoff = PollBackoff();

  bool _disposed = false;

  /// Колбэк, который вызывается при появлении нового сообщения в списке.
  /// UI использует его, чтобы прокрутить список вниз.
  VoidCallback? onMessageAdded;

  /// Транзиентные сообщения для SnackBar. UI слушает через [snackBar].
  final ValueNotifier<String?> snackBar = ValueNotifier(null);

  // ---------------- Public getters ----------------
  ConnectionStatus get connectionStatus => _connection.status;
  String get connectionError => _connection.lastError;
  bool get isConnected => _connection.isConnected;
  bool get isConnecting => _connection.isConnecting || _isConnectAttemptRunning;
  bool get isBusy => _connection.isBusy || _isConnectAttemptRunning;

  UnmodifiableListView<Message> get messages => _store.messages;
  bool get hasPendingEcho => _store.hasPendingEcho;

  String get myName => _myName;
  bool get soundEnabled => _soundEnabled;
  String get currentWifiName => _currentWifiName;
  String get deviceIp => _deviceIp;
  String get networkHint => _networkHint;
  bool get notificationsDenied => _notificationsDenied;

  // ---------------- Internal platform channels ----------------
  static const MethodChannel _networkChannel =
      MethodChannel('esp32/network');

  // ---------------- Init / dispose ----------------

  Future<void> init() async {
    _store = MessageStore(
      maxMessages: maxMessages,
      maxPendingEcho: maxPendingEcho,
      echoTimeout: echoTimeout,
    );

    _connection = ChatConnection(
      socketFactory: () => WebSocketChatSocket('ws://$esp32Address:81'),
      handshakeTimeout: handshakeTimeout,
      closeTimeout: closeTimeout,
      cancelTimeout: cancelTimeout,
    )
      ..onFrame = _onFrame
      ..onChanged = _onConnectionChanged
      ..onConnected = _onConnectionEstablished
      ..onDisconnected = _onConnectionClosed;

    await _initPreferences();
    await _initNotifications();

    // Первый опрос — после того, как виджет подпишется на уведомления.
    scheduleMicrotask(_startConnectionMonitoring);
  }

  @override
  void dispose() {
    _disposed = true;
    _connectionTimer?.cancel();
    _connection.disconnect();
    _stopForegroundService();
    _unbindWifi();
    _notificationPlayer.dispose();
    snackBar.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _setSnack(String message) {
    snackBar.value = message;
  }

  // ---------------- Preferences ----------------

  Future<void> _initPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    _soundEnabled = prefs.getBool(soundPrefKey) ?? true;

    final savedName = prefs.getString('user_name');
    if (savedName != null && savedName.isNotEmpty) {
      _myName = savedName;
    } else {
      _myName = 'User_${DateTime.now().millisecondsSinceEpoch % 1000}';
      await prefs.setString('user_name', _myName);
    }
    _notify();
  }

  // ---------------- Notifications ----------------

  Future<void> _initNotifications() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _notifications.initialize(settings);

      if (Platform.isAndroid) {
        final granted = await _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        _notificationsDenied = granted == false;
      }

      _notificationsReady = true;
      _notify();
    } catch (e) {
      debugPrint('Не удалось инициализировать уведомления: $e');
    }
  }

  Future<void> _showMessageNotification(String from, String text) async {
    if (!_notificationsReady) return;
    try {
      final details = AndroidNotificationDetails(
        soundEnabled ? notificationChannelId : silentNotificationChannelId,
        soundEnabled ? 'Сообщения чата' : 'Сообщения чата (без звука)',
        channelDescription: 'Входящие сообщения из эфира',
        importance: Importance.high,
        priority: Priority.high,
        playSound: soundEnabled,
      );
      await _notifications.show(
        messageNotificationId,
        from,
        text,
        NotificationDetails(android: details),
      );
    } catch (e) {
      debugPrint('Не удалось показать уведомление: $e');
    }
  }

  Future<void> _playNotificationSound() async {
    if (!_soundEnabled) return;
    try {
      await _notificationPlayer.stop();
      await _notificationPlayer.play(AssetSource(notificationAsset));
    } catch (e) {
      debugPrint('Не удалось проиграть звук уведомления: $e');
    }
  }

  // ---------------- Foreground service / Wi-Fi binding ----------------

  Future<bool> _bindToWifi() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _networkChannel.invokeMethod<bool>('bindToWifi');
      return ok ?? false;
    } catch (e) {
      debugPrint('bindToWifi error: $e');
      return false;
    }
  }

  Future<void> _unbindWifi() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('unbind');
    } catch (e) {
      debugPrint('unbind error: $e');
    }
  }

  Future<void> _startForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('startService');
    } catch (e) {
      debugPrint('startService error: $e');
    }
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('stopService');
    } catch (e) {
      debugPrint('stopService error: $e');
    }
  }

  Future<void> _setServiceConnected(bool connected) async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('setServiceConnected', {
        'connected': connected,
      });
    } catch (e) {
      debugPrint('setServiceConnected error: $e');
    }
  }

  // ---------------- Lifecycle ----------------

  void setForeground(bool isForeground) {
    _isForeground = isForeground;
  }

  // ---------------- Connection monitoring ----------------

  void _startConnectionMonitoring() {
    _scheduleConnectionCheck();
    _checkConnection();
  }

  void _scheduleConnectionCheck() {
    _connectionTimer?.cancel();
    _connectionTimer = Timer(_pollBackoff.interval, _checkConnection);
  }

  Future<void> _checkConnection() async {
    if (_isConnectAttemptRunning || _connection.isBusy) {
      _scheduleConnectionCheck();
      return;
    }

    if (_store.expirePending()) {
      _notify();
    }

    try {
      final deviceIp = await _wifiIp();
      final ipChanged = deviceIp != _deviceIp;
      _deviceIp = deviceIp;
      if (ipChanged) _notify();

      if (deviceIp.startsWith('192.168.4.')) {
        await _bindToWifi();
      }

      final reachable = _connection.isConnected || await _pingEsp32();

      if (!reachable) {
        _pollBackoff.onFailure();
        if (_connection.status != ConnectionStatus.disconnected) {
          await _connection.disconnect();
        }
        _currentWifiName = 'Не подключено';
        _networkHint = 'Подключитесь к WiFi ESP32';
        _notify();
        return;
      }

      _pollBackoff.onSuccess();
      _networkHint = '';

      if (ipChanged || _currentWifiName == 'Не подключено') {
        await _updateWifiInfo();
      }

      if (_connection.status == ConnectionStatus.disconnected ||
          _connection.status == ConnectionStatus.error) {
        await _connectToEsp32();
      }
    } catch (e) {
      debugPrint('Ошибка проверки WiFi: $e');
      _currentWifiName = 'Ошибка получения WiFi';
      _notify();
    } finally {
      _scheduleConnectionCheck();
    }
  }

  Future<String> _wifiIp() async {
    try {
      return await NetworkInfo().getWifiIP() ?? '';
    } catch (e) {
      debugPrint('Локальный IP недоступен: $e');
      return '';
    }
  }

  Future<bool> _pingEsp32() async {
    try {
      final response = await http
          .get(Uri.parse('http://$esp32Address/ping'))
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('ESP32 не ответил на ping: $e');
      return false;
    }
  }

  Future<void> _updateWifiInfo() async {
    try {
      final response = await http
          .get(Uri.parse('http://$esp32Address/info'))
          .timeout(const Duration(seconds: 2));

      String? ssid;
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['ssid'] is String) {
          final value = decoded['ssid'] as String;
          if (value.isNotEmpty) ssid = value;
        }
      }
      _currentWifiName = ssid ?? 'Сеть ESP32';
      _notify();
    } catch (e) {
      debugPrint('Ошибка получения имени сети от ESP32: $e');
      _currentWifiName = 'Сеть ESP32';
      _notify();
    }
  }

  // ---------------- Connect / disconnect ----------------

  Future<void> _connectToEsp32() async {
    if (_isConnectAttemptRunning || _connection.isConnecting) {
      debugPrint('⚠️ Уже подключаюсь, пропускаю');
      return;
    }
    _setConnectAttemptRunning(true);

    try {
      await _bindToWifi();

      debugPrint('Проверяю ping ESP32...');
      if (!await _pingEsp32()) {
        debugPrint('❌ ESP32 не отвечает на ping');
        return;
      }

      debugPrint('ESP32 доступен, подключаю WebSocket...');
      await _connection.connect();
    } finally {
      _setConnectAttemptRunning(false);
    }
  }

  void _setConnectAttemptRunning(bool running) {
    _isConnectAttemptRunning = running;
    _notify();
  }

  Future<void> connect() => _connectToEsp32();

  Future<void> disconnect() => _connection.disconnect();

  Future<void> reconnect() async {
    await _connection.disconnect();
    await Future.delayed(const Duration(milliseconds: 100));
    await _connectToEsp32();
  }

  void _onConnectionChanged() {
    _notify();
  }

  Future<void> _onConnectionEstablished() async {
    debugPrint('✅ Успешно подключено к ESP32');
    await _startForegroundService();
    await _setServiceConnected(true);
    _sendUserName();
  }

  Future<void> _onConnectionClosed() async {
    await _setServiceConnected(false);
    if (_store.failAllPending()) {
      _notify();
    }
  }

  void _sendUserName() {
    if (_connection.send(buildSetNameFrame(_myName))) {
      debugPrint('Отправлено имя: $_myName');
    }
  }

  // ---------------- Incoming messages ----------------

  void _onFrame(String message) {
    if (_disposed) return;
    debugPrint('📥 WebSocket: $message');

    final frame = parseIncomingFrame(message);

    switch (frame.kind) {
      case IncomingKind.ignore:
        return;
      case IncomingKind.ping:
        _connection.send('pong');
        return;
      case IncomingKind.system:
        _setSnack(frame.text);
        return;
      case IncomingKind.chat:
        break;
    }

    final outcome = _store.ingest(frame, myName: _myName);

    switch (outcome) {
      case IngestOutcome.duplicateIgnored:
        return;
      case IngestOutcome.echoConfirmed:
        _notify();
        return;
      case IngestOutcome.addedHistory:
        _notify();
        onMessageAdded?.call();
        return;
      case IngestOutcome.addedNew:
        _notify();
        onMessageAdded?.call();
        if (_isForeground || !Platform.isAndroid) {
          _playNotificationSound();
        } else {
          _showMessageNotification(frame.from, frame.text);
        }
        return;
    }
  }

  // ---------------- User actions ----------------

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || !_connection.isConnected) return;

    final id = generateMessageId();

    if (!messageFitsFrame(_myName, trimmed, id: id)) {
      _setSnack('Сообщение слишком длинное для передачи');
      return;
    }

    final message = _store.addOutgoing(id, _myName, trimmed);
    _notify();
    onMessageAdded?.call();

    final outgoing = buildMessageFrame(_myName, trimmed, id: id);
    if (!_connection.send(outgoing)) {
      _store.markFailed(message);
      _notify();
      _setSnack('Не удалось отправить');
      return;
    }

    debugPrint('Отправлено через WS: $outgoing');
  }

  Future<void> toggleSound() async {
    _soundEnabled = !_soundEnabled;
    _notify();
    await _prefs?.setBool(soundPrefKey, _soundEnabled);
  }

  /// Возвращает текст ошибки или null при успехе.
  Future<String?> setName(String newName) async {
    newName = newName.trim();
    if (newName.contains(':')) return 'Имя не может содержать двоеточие';
    if (newName.isEmpty) return 'Имя не может быть пустым';
    if (newName == _myName) return null;

    _myName = newName;
    await _prefs?.setString('user_name', _myName);
    _notify();

    if (_connection.isConnected) {
      _sendUserName();
    }
    return null;
  }

  /// Закрывает соединения и сервисы перед выходом из приложения.
  Future<void> exit() async {
    _connectionTimer?.cancel();
    await _connection.disconnect();
    await _stopForegroundService();
    await _unbindWifi();
  }
}
