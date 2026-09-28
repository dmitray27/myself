import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Message;
import 'package:http/http.dart' as http;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_connection.dart';
import 'chat_protocol.dart';
import 'history_store.dart';
import 'message_store.dart';

export 'chat_protocol.dart' show LinkStats, PeerInfo, RadioState;
export 'message_store.dart';
export 'chat_connection.dart';

/// Абонент в эфире с возрастом последнего ACK, пересчитанным на момент запроса.
class Peer {
  final String station;
  final DateTime lastSeen;
  const Peer(this.station, this.lastSeen);

  Duration age([DateTime? now]) => (now ?? DateTime.now()).difference(lastSeen);
}

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
    this.maxAttempts = 3,
    this.retryBackoff = const Duration(seconds: 5),
    this.peerTtl = const Duration(minutes: 15),
    this.nameReplyTimeout = const Duration(milliseconds: 1500),
    this.history,
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

  /// Сколько раз сообщение уходит в сокет (первая попытка + повторы), пока не
  /// придёт ACK. Повтор N ждёт [retryBackoff] * N.
  final int maxAttempts;
  final Duration retryBackoff;

  /// Абонент без ACK дольше этого времени убирается из списка (как PEER_TTL_S в прошивке).
  final Duration peerTtl;

  /// Старая прошивка не отвечает на setName: через это время имя считается принятым.
  final Duration nameReplyTimeout;

  /// Хранилище истории; null — SharedPreferences.
  final HistoryStore? history;

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

  // ---------------- PRO state ----------------
  late final HistoryStore _history;
  bool _fieldMode = false;
  LinkStats _stats = LinkStats.empty;
  final Map<String, Peer> _peers = {};
  Timer? _retryTimer;
  final Map<String, DateTime> _nextAttemptAt = {};
  String? _pendingName;
  Timer? _nameTimer;
  Timer? _saveTimer;

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

  LinkStats get stats => _stats;
  bool get fieldMode => _fieldMode;

  /// Абоненты, от которых плата слышала ACK не позже [peerTtl]; свежие первыми.
  List<Peer> peers([DateTime? now]) {
    final at = now ?? DateTime.now();
    final list = _peers.values.where((p) => p.age(at) <= peerTtl).toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return list;
  }

  // ---------------- Internal platform channels ----------------
  static const MethodChannel _networkChannel = MethodChannel('esp32/network');

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

    _history = history ?? PrefsHistoryStore();
    await _initPreferences();
    _store.restore(await _history.load());
    await _initNotifications();

    // Первый опрос — после того, как виджет подпишется на уведомления.
    scheduleMicrotask(_startConnectionMonitoring);
  }

  /// Общая асинхронная очистка для [exit] и [dispose]: выполняется один раз,
  /// повторный вызов ждёт ту же Future, а не запускает параллельную цепочку.
  Future<void>? _shutdown;

  Future<void> _stopMonitoringAndDisconnect() {
    return _shutdown ??= () async {
      _connectionTimer?.cancel();
      _connectionTimer = null;
      await _connection.disconnect();
    }();
  }

  @override
  void dispose() {
    _disposed = true;
    _connection
      ..onFrame = null
      ..onChanged = null
      ..onConnected = null
      ..onDisconnected = null;
    _retryTimer?.cancel();
    _nameTimer?.cancel();
    _saveTimer?.cancel();
    _notificationPlayer.dispose();
    snackBar.dispose();
    // Платформенные вызовы идут последовательно: одновременные disconnect/unbind/
    // stopService гонялись с цепочкой closeApp из exit()
    unawaited(_stopMonitoringAndDisconnect().then((_) async {
      if (_exitedViaPlatform) return;
      await _stopForegroundService();
      await _unbindWifi();
    }));
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
    _fieldMode = prefs.getBool('field_mode') ?? false;
    fieldModeNotifier.value = _fieldMode;
    _notify();
  }

  /// Полевой режим виден MaterialApp (тема) до создания экрана, поэтому
  /// дублируется в статическом notifier.
  static final ValueNotifier<bool> fieldModeNotifier = ValueNotifier(false);

  Future<void> setFieldMode(bool enabled) async {
    _fieldMode = enabled;
    fieldModeNotifier.value = enabled;
    _notify();
    await _prefs?.setBool('field_mode', enabled);
  }

  // ---------------- History ----------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    if (_shuttingDown) return;
    _saveTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_history.save(_store.messages));
    });
  }

  Future<void> clearHistory() async {
    _store.clear();
    _nextAttemptAt.clear();
    _notify();
    await _history.save(const []);
  }

  String exportHistoryText() => formatHistory(_store.messages, myName: _myName);

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

  /// IP, для которого bind уже выполнен: повторный bind на каждом опросе
  /// пересоздаёт NetworkCallback и может подвесить ожидающий Result.
  String? _boundIp;

  Future<bool> _bindToWifi({bool force = false}) async {
    if (!Platform.isAndroid) return true;
    if (!force && _boundIp != null && _boundIp == _deviceIp) return true;
    try {
      final ok = await _networkChannel
          .invokeMethod<bool>('bindToWifi')
          .timeout(const Duration(seconds: 10));
      if (ok == true) {
        _boundIp = _deviceIp;
        return true;
      }
      _boundIp = null;
      return false;
    } catch (e) {
      debugPrint('bindToWifi error: $e');
      _boundIp = null;
      return false;
    }
  }

  Future<void> _unbindWifi() async {
    if (!Platform.isAndroid) return;
    _boundIp = null;
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

  Future<bool> _closeApp() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _networkChannel.invokeMethod<bool>('closeApp');
      return ok ?? false;
    } catch (e) {
      debugPrint('closeApp error: $e');
      return false;
    }
  }

  /// Сворачивает приложение (как «Домой»): Activity уходит в фон, а Dart,
  /// WebSocket и foreground-сервис продолжают работать.
  Future<void> moveToBackground() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod<bool>('moveToBackground');
    } catch (e) {
      debugPrint('moveToBackground error: $e');
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

  bool get _shuttingDown => _disposed || _shutdown != null;

  void _scheduleConnectionCheck() {
    _connectionTimer?.cancel();
    if (_shuttingDown) return;
    _connectionTimer = Timer(_pollBackoff.interval, _checkConnection);
  }

  Future<void> _checkConnection() async {
    if (_shuttingDown) return;
    if (_isConnectAttemptRunning || _connection.isBusy) {
      _scheduleConnectionCheck();
      return;
    }

    if (_store.expirePending().isNotEmpty) {
      _scheduleRetry();
      _notify();
    }

    try {
      final deviceIp = await _wifiIp();
      if (_shuttingDown) return;
      final ipChanged = deviceIp != _deviceIp;
      _deviceIp = deviceIp;
      if (ipChanged) _notify();

      final onEsp32Network = deviceIp.startsWith('192.168.4.');
      // На Android вне сети платы связи нет, даже если сокет ещё не заметил разрыва
      var bound = !Platform.isAndroid || onEsp32Network;
      if (onEsp32Network) {
        bound = await _bindToWifi(force: ipChanged);
      } else if (_boundIp != null) {
        await _unbindWifi();
      }

      // Без bind запросы уйдут через мобильную сеть и бессмысленно ждут таймаута
      final reachable =
          bound && (_connection.isConnected || await _pingEsp32());
      if (_shuttingDown) return;

      if (!reachable) {
        _pollBackoff.onFailure();
        if (_connection.status != ConnectionStatus.disconnected) {
          await _connection.disconnect();
        }
        _currentWifiName = 'Не подключено';
        _networkHint = 'Подключитесь к WiFi УПТС-РК1';
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
      _currentWifiName = ssid ?? 'Сеть УПТС-РК1';
      _notify();
    } catch (e) {
      debugPrint('Ошибка получения имени сети от ESP32: $e');
      _currentWifiName = 'Сеть УПТС-РК1';
      _notify();
    }
  }

  // ---------------- Connect / disconnect ----------------

  Future<void> _connectToEsp32() async {
    if (_shuttingDown) return;
    if (_isConnectAttemptRunning || _connection.isConnecting) {
      debugPrint('⚠️ Уже подключаюсь, пропускаю');
      return;
    }
    _setConnectAttemptRunning(true);

    try {
      if (!await _bindToWifi()) {
        debugPrint('❌ Не удалось привязаться к Wi-Fi ESP32');
        _networkHint = 'Подключитесь к WiFi УПТС-РК1';
        _notify();
        return;
      }

      debugPrint('Проверяю ping ESP32...');
      if (!await _pingEsp32()) {
        debugPrint('❌ ESP32 не отвечает на ping');
        _boundIp = null;
        return;
      }
      if (_shuttingDown) return;

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
    // ≥100 мс после setName (WS_MIN_MSG_INTERVAL_MS в прошивке)
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(milliseconds: 300), _flushRetries);
  }

  Future<void> _onConnectionClosed() async {
    await _setServiceConnected(false);
    _peers.clear();
    _stats = LinkStats.empty;
    if (_store.requeuePending()) {
      _scheduleRetry();
    }
    _notify();
  }

  void _sendUserName() {
    if (_connection.send(buildSetNameFrame(_myName))) {
      debugPrint('Отправлено имя: $_myName');
    }
  }

  // ---------------- Retry ----------------

  /// Повтор сообщений без ACK и без эха. Запускается по таймеру на ближайшую
  /// попытку; без связи ждёт [_onConnectionEstablished].
  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_shuttingDown) return;
    final now = DateTime.now();
    DateTime? earliest;
    for (final m in _store.unfinished) {
      final at = _nextAttemptAt[m.id] ?? now;
      if (earliest == null || at.isBefore(earliest)) earliest = at;
    }
    if (earliest == null) return;
    var delay = earliest.difference(now);
    if (delay < const Duration(milliseconds: 200)) {
      delay = const Duration(milliseconds: 200);
    }
    _retryTimer = Timer(delay, _flushRetries);
  }

  void _flushRetries() {
    if (_shuttingDown) return;
    final now = DateTime.now();
    var changed = false;
    for (final m in _store.unfinished.toList()) {
      // aired/accepted — плата ещё работает над кадром, итог придёт кадром status:
      if (m.status == MessageStatus.accepted ||
          m.status == MessageStatus.aired) {
        continue;
      }
      if (m.status == MessageStatus.sending && _store.isAwaitingEcho(m)) {
        continue;
      }
      if (m.attempts >= maxAttempts) {
        _store.markFailed(m);
        _nextAttemptAt.remove(m.id);
        changed = true;
        continue;
      }
      final at = _nextAttemptAt[m.id];
      if (at != null && at.isAfter(now)) continue;
      if (!_connection.isConnected) continue;
      _transmit(m);
      changed = true;
    }
    if (changed) {
      _notify();
      _scheduleSave();
    }
    _scheduleRetry();
  }

  /// Отправка кадра в сокет. false — не ушло.
  bool _transmit(Message m) {
    if (!messageFitsFrame(m.from, m.text, id: m.id)) {
      _store.markFailed(m);
      _setSnack('Сообщение слишком длинное для передачи');
      return false;
    }
    final frame = buildMessageFrame(m.from, m.text, id: m.id);
    if (!_connection.send(frame)) {
      return false;
    }
    _store.markSent(m);
    _nextAttemptAt[m.id] =
        DateTime.now().add(retryBackoff * m.attempts + echoTimeout);
    debugPrint('Отправлено через WS (попытка ${m.attempts}): ${m.id}');
    return true;
  }

  /// Ручной повтор сообщения со статусом failed/noack.
  void resend(Message m) {
    if (!m.isMe) return;
    m.attempts = 0;
    m.status = MessageStatus.sending;
    _nextAttemptAt.remove(m.id);
    _notify();
    _scheduleRetry();
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
        _onSystem(frame.text);
        return;
      case IncomingKind.status:
        if (_store.applyStatus(frame.id, frame.radioState,
            detail: frame.detail)) {
          if (frame.radioState == RadioState.noack ||
              frame.radioState == RadioState.failed) {
            final m =
                _store.messages.lastWhere((m) => m.isMe && m.id == frame.id);
            _nextAttemptAt[frame.id] =
                DateTime.now().add(retryBackoff * m.attempts);
            _scheduleRetry();
          }
          _notify();
          _scheduleSave();
        }
        return;
      case IncomingKind.stat:
        _stats = frame.stats ?? LinkStats.empty;
        _notify();
        return;
      case IncomingKind.peers:
        _onPeers(frame.peers);
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
        _scheduleSave();
        onMessageAdded?.call();
        return;
      case IngestOutcome.addedNew:
        _notify();
        _scheduleSave();
        onMessageAdded?.call();
        if (_isForeground || !Platform.isAndroid) {
          _playNotificationSound();
        } else {
          _showMessageNotification(frame.from, frame.text);
        }
        return;
    }
  }

  void _onSystem(String text) {
    if (text == kSystemNameOk) {
      _confirmName();
      return;
    }
    if (text == kSystemNameBusy) {
      final rejected = _pendingName ?? _myName;
      _pendingName = null;
      _nameTimer?.cancel();
      _setSnack('Имя «$rejected» занято другим абонентом — выберите другое');
      if (rejected == _myName) {
        // После переподключения сохранённое имя уже занято: плата оставила
        // нам имя по умолчанию, отправка под старым именем не имеет смысла.
        _nameRejected = true;
      }
      _notify();
      return;
    }
    _setSnack(text);
  }

  bool _nameRejected = false;

  /// Текущее имя отклонено платой: отправка заблокирована до смены имени.
  bool get nameRejected => _nameRejected;

  void _confirmName() {
    _nameTimer?.cancel();
    _nameRejected = false;
    final pending = _pendingName;
    _pendingName = null;
    if (pending != null && pending != _myName) {
      _myName = pending;
      unawaited(_prefs?.setString('user_name', _myName) ?? Future.value());
    }
    _notify();
  }

  void _onPeers(List<PeerInfo> list) {
    final now = DateTime.now();
    for (final p in list) {
      final seen = now.subtract(Duration(seconds: p.ageSeconds));
      final known = _peers[p.station];
      if (known == null || seen.isAfter(known.lastSeen)) {
        _peers[p.station] = Peer(p.station, seen);
      }
    }
    _peers.removeWhere((_, p) => p.age(now) > peerTtl);
    _notify();
  }

  // ---------------- User actions ----------------

  /// true — сообщение принято в отправку (поле ввода можно очищать);
  /// false — отклонено или не ушло, текст остаётся у пользователя.
  Future<bool> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (!_connection.isConnected) {
      _setSnack('Нет соединения с УПТС-РК1');
      return false;
    }
    if (trimmed.characters.length > maxMessageLength) {
      _setSnack('Сообщение не длиннее $maxMessageLength символов');
      return false;
    }

    if (_nameRejected) {
      _setSnack('Имя занято — смените имя перед отправкой');
      return false;
    }

    final id = generateMessageId();
    if (!messageFitsFrame(_myName, trimmed, id: id)) {
      _setSnack('Сообщение слишком длинное для передачи');
      return false;
    }

    final message = _store.addOutgoing(id, _myName, trimmed);
    _notify();
    onMessageAdded?.call();

    if (!_transmit(message)) {
      // Остаётся sending: уйдёт повтором, когда сокет снова примет кадры
      _setSnack('Не удалось отправить, повторю позже');
    }
    _scheduleRetry();
    _scheduleSave();
    return true;
  }

  /// Смена SSID/пароля точки доступа платы (POST /config). Возвращает текст
  /// ошибки или null; при успехе плата перезапускается и связь будет потеряна.
  Future<String?> configureAccessPoint({
    required String ssid,
    required String password,
    bool reset = false,
  }) async {
    if (!reset) {
      final error = validateApConfig(ssid, password);
      if (error != null) return error;
    }
    try {
      final response = await http
          .post(
            Uri.parse('http://$esp32Address/config'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: reset ? {'reset': '1'} : {'ssid': ssid, 'pass': password},
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        return 'УПТС-РК1 отклонил настройки: ${response.body.trim()}';
      }
      return null;
    } catch (e) {
      debugPrint('POST /config: $e');
      return 'Нет ответа от УПТС-РК1';
    }
  }

  /// GET /config → текущий SSID (null, если прошивка не PRO или нет связи).
  Future<String?> fetchAccessPointSsid() async {
    try {
      final response = await http
          .get(Uri.parse('http://$esp32Address/config'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['ssid'] is String) {
        return decoded['ssid'] as String;
      }
    } catch (e) {
      debugPrint('GET /config: $e');
    }
    return null;
  }

  Future<void> toggleSound() async {
    _soundEnabled = !_soundEnabled;
    _notify();
    await _prefs?.setBool(soundPrefKey, _soundEnabled);
  }

  /// Возвращает текст ошибки или null при успехе.
  Future<String?> setName(String newName) async {
    newName = newName.trim();
    if (newName.characters.length > maxNameLength) {
      return 'Имя не длиннее $maxNameLength символов';
    }
    final error = validateName(newName);
    if (error != null) return error;
    if (newName == _myName && !_nameRejected) return null;

    if (!_connection.isConnected) {
      // Проверить занятость некому: принимаем, плата проверит при подключении
      _myName = newName;
      _nameRejected = false;
      await _prefs?.setString('user_name', _myName);
      _notify();
      return null;
    }

    // Имя меняется только после System:name ok; старая прошивка не отвечает —
    // тогда по таймауту считаем принятым
    _pendingName = newName;
    if (!_connection.send(buildSetNameFrame(newName))) {
      _pendingName = null;
      return 'Не удалось отправить имя';
    }
    _nameTimer?.cancel();
    _nameTimer = Timer(nameReplyTimeout, () {
      if (_pendingName == newName) _confirmName();
    });
    return null;
  }

  /// Закрывает соединения, сервисы, уведомления и активность при выходе.
  /// На Android вся остановка (сервис, unbind, Activity, процесс) идёт одной
  /// цепочкой через `closeApp`, чтобы не останавливать и сразу заново
  /// запускать сервис. Возвращает true, если платформа закрывает приложение
  /// сама и вызывающему ничего закрывать не надо.
  bool _exitedViaPlatform = false;

  Future<bool> exit() async {
    await _stopMonitoringAndDisconnect();
    if (Platform.isAndroid) {
      _boundIp = null;
      _exitedViaPlatform = await _closeApp();
      return _exitedViaPlatform;
    }
    return false;
  }
}
