import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'chat_protocol.dart';
import 'dart:io';
// Состояния подключения
enum ConnectionStatus { disconnected, connecting, connected, error }

// Своё сообщение считается доставленным, когда ESP32 вернёт его
// широковещательно: прошивка рассылает кадр только после того, как
// поставила текст в очередь на передачу в эфир
enum MessageStatus { sending, delivered, failed }

class Message {
  final String from;
  final String text;
  final bool isMe;
  final DateTime timestamp;
  MessageStatus status;

  Message(
    this.from,
    this.text,
    this.isMe, {
    DateTime? timestamp,
    this.status = MessageStatus.delivered,
  }) : timestamp = timestamp ?? DateTime.now();
}

// Отправленный кадр, ждущий эха от ESP32
class _PendingEcho {
  final String frame;
  final Message message;
  Timer? timeout;

  _PendingEcho(this.frame, this.message);
}

class ChatScreen extends StatefulWidget {
  final bool isLinux;

  const ChatScreen({super.key, required this.isLinux});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final List<Message> _messages = [];
  String _myName = "User";
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  WebSocketChannel? _webSocketChannel;
  StreamSubscription? _webSocketSubscription;

  // Загружается асинхронно: до этого диалог смены имени открывать нельзя
  SharedPreferences? _prefs;

  final AudioPlayer _notificationPlayer = AudioPlayer();
  bool _soundEnabled = true;

  // Системные уведомления: со свёрнутым приложением AudioPlayer может молчать,
  // а канал уведомлений ОС звучит и при погашенном экране
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _notificationsReady = false;

  // На переднем плане звучит AudioPlayer, в фоне — канал уведомлений:
  // иначе на одно сообщение слышны два звука
  bool _isForeground = true;

  ConnectionStatus _connectionState = ConnectionStatus.disconnected;
  String _currentWifiName = 'Не подключено';
  String _lastError = '';
  bool _isConnecting = false;
  bool _isDisconnecting = false;
  Timer? _connectionTimer;

  // Эхо собственных сообщений, пришедшее обратно с ESP32, показывать не нужно:
  // оно уже добавлено в список локально при отправке.
  final List<_PendingEcho> _pendingEcho = [];

  static const String _esp32Address = '192.168.4.1';
  static const Duration _pollInterval = Duration(seconds: 5);
  static const int _maxPendingEcho = 16;
  static const Duration _echoTimeout = Duration(seconds: 6);
  // Ограничение поля ввода в символах; фактический лимит прошивки —
  // kMaxFrameBytes байт на весь кадр, он проверяется при отправке
  static const int _maxMessageLength = 300;
  static const int _maxNameLength = 15;
  static const String _notificationAsset = '73g_assets/sounds/notify.mp3';
  // Каналы Android неизменяемы после создания, поэтому звук переключается
  // сменой канала, а не флагом playSound
  static const String _notificationChannelId = 'chat_messages';
  static const String _silentNotificationChannelId = 'chat_messages_silent';
  static const int _messageNotificationId = 1001;
  static const String _soundPrefKey = 'sound_enabled';
  static const MethodChannel _networkChannel =
  MethodChannel('esp32/network');
  String _deviceIp = '';

  // ============================
  // Жизненный цикл
  // ============================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPreferences();
    _initNotifications();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopForegroundService();
    _unbindWifi();
    _connectionTimer?.cancel();
    for (final pending in _pendingEcho) {
      pending.timeout?.cancel();
    }
    _disconnect();
    _textController.dispose();
    _nameController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    _notificationPlayer.dispose();
    super.dispose();
  }

  // ============================
  // Инициализация настроек
  // ============================
  Future<bool> _bindToWifi() async {
    if (!Platform.isAndroid) return true; // на Linux/desktop не трогаем
    try {
      final ok = await _networkChannel.invokeMethod<bool>('bindToWifi');
      debugPrint('bindToWifi -> $ok');
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

  // Foreground-сервис держит процесс живым и удерживает WifiLock: иначе при
  // погашенном экране ОС замораживает процесс и WebSocket перестаёт читаться
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

  Future<void> _initNotifications() async {
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _notifications.initialize(settings);

      if (Platform.isAndroid) {
        // Android 13+: без явного разрешения уведомления не показываются
        await _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }

      _notificationsReady = true;
    } catch (e) {
      debugPrint('Не удалось инициализировать уведомления: $e');
    }
  }

  Future<void> _showMessageNotification(String from, String text) async {
    if (!_notificationsReady) return;

    try {
      final details = AndroidNotificationDetails(
        _soundEnabled ? _notificationChannelId : _silentNotificationChannelId,
        _soundEnabled ? 'Сообщения чата' : 'Сообщения чата (без звука)',
        channelDescription: 'Входящие сообщения из эфира',
        importance: Importance.high,
        priority: Priority.high,
        playSound: _soundEnabled,
      );
      await _notifications.show(
        _messageNotificationId,
        from,
        text,
        NotificationDetails(android: details),
      );
    } catch (e) {
      debugPrint('Не удалось показать уведомление: $e');
    }
  }
  Future<void> _initPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    _soundEnabled = prefs.getBool(_soundPrefKey) ?? true;

    final savedName = prefs.getString('user_name');
    if (savedName != null && savedName.isNotEmpty) {
      _myName = savedName;
    } else {
      _myName = "User_${DateTime.now().millisecondsSinceEpoch % 1000}";
      await prefs.setString('user_name', _myName);
    }

    if (!mounted) return;
    setState(() {});
    _startConnectionMonitoring();
  }

  // ============================
  // Мониторинг WiFi
  // ============================

  void _startConnectionMonitoring() {
    _connectionTimer = Timer.periodic(_pollInterval, (timer) {
      _checkConnection();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkConnection();
    });
  }

  Future<void> _checkConnection() async {
    if (_isConnecting || _isDisconnecting) return;

    try {
      final deviceIp = await _wifiIp();
      final ipChanged = deviceIp != _deviceIp;

      // Присваиваем вне setState: иначе при !mounted проверка сети
      // пошла бы по устаревшему значению
      _deviceIp = deviceIp;
      // Перерисовка только при фактическом изменении: тик раз в 5 секунд
      // иначе перестраивал всё дерево вхолостую
      if (ipChanged && mounted) {
        setState(() {});
      }
      if (deviceIp.startsWith('192.168.4.')) {
        await _bindToWifi();
      }
      // Признак связи — ответ самой платы, а не IP из плагина: на десктопе
      // и на части Android getWifiIP() не отдаёт адрес подсети ESP32, хотя
      // плата доступна, и подключение по кнопке сносилось этой же проверкой
      // на следующем тике
      final reachable = _connectionState == ConnectionStatus.connected ||
          await _pingEsp32();

      if (!reachable) {
        if (_connectionState != ConnectionStatus.disconnected) {
          await _disconnect();
        }
        if (mounted) {
          setState(() {
            _currentWifiName = 'Не подключено';
            _connectionState = ConnectionStatus.disconnected;
            _lastError = 'Подключитесь к WiFi ESP32';
          });
        }
        return;
      }

      // Имя сети спрашиваем у самой платы: при смене IP и после того,
      // как плата впервые ответила
      if (ipChanged || _currentWifiName == 'Не подключено') {
        await _updateWifiInfo();
      }

      // Повтор попытки после разрыва идёт по этому же таймеру,
      // отдельный _reconnectTimer не нужен
      if (_connectionState == ConnectionStatus.disconnected ||
          _connectionState == ConnectionStatus.error) {
        _connectToEsp32();
      }
    } catch (e) {
      debugPrint('Ошибка проверки WiFi: $e');
      if (mounted) {
        setState(() {
          _currentWifiName = 'Ошибка получения WiFi';
        });
      }
    }
  }

  // Адрес нужен только для того, чтобы заметить смену сети. Плагин бросает
  // там, где спросить некого (десктоп без NetworkManager, Android без
  // разрешений), и это не повод пропускать опрос платы, поэтому исключение
  // гасится здесь, а не в _checkConnection().
  Future<String> _wifiIp() async {
    try {
      return await NetworkInfo().getWifiIP() ?? '';
    } catch (e) {
      debugPrint('Локальный IP недоступен: $e');
      return '';
    }
  }

  // Плата ответила на /ping — значит связь есть, независимо от того,
  // что вернул плагин Wi-Fi
  Future<bool> _pingEsp32() async {
    try {
      final response = await http
          .get(Uri.parse('http://$_esp32Address/ping'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('ESP32 не ответил на ping: $e');
      return false;
    }
  }

  // SSID берём у самой платы по HTTP: getWifiName() на Android требует
  // разрешения геолокации, а /info отдаёт то же имя без него
  Future<void> _updateWifiInfo() async {
    try {
      final response = await http
          .get(Uri.parse('http://$_esp32Address/info'))
          .timeout(const Duration(seconds: 3));

      String? ssid;
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['ssid'] is String) {
          final value = decoded['ssid'] as String;
          if (value.isNotEmpty) ssid = value;
        }
      }

      if (mounted) {
        setState(() {
          _currentWifiName = ssid ?? 'Сеть ESP32';
        });
      }
    } catch (e) {
      debugPrint('Ошибка получения имени сети от ESP32: $e');
      if (mounted) {
        setState(() {
          _currentWifiName = 'Сеть ESP32';
        });
      }
    }
  }

  Future<void> _playNotificationSound() async {
    if (!_soundEnabled) return;
    try {
      await _notificationPlayer.stop();
      await _notificationPlayer.play(AssetSource(_notificationAsset));
    } catch (e) {
      debugPrint('Не удалось проиграть звук уведомления: $e');
    }
  }

  Future<void> _toggleSound() async {
    final enabled = !_soundEnabled;
    setState(() {
      _soundEnabled = enabled;
    });
    await _prefs?.setBool(_soundPrefKey, enabled);
  }

  // ============================
  // Подключение / отключение
  // ============================

  Future<void> _connectToEsp32() async {
    if (_isConnecting) {
      debugPrint('⚠️ Уже подключаюсь, пропускаю');
      return;
    }

    _isConnecting = true;
    // Заставляем ОС гнать трафик через Wi-Fi ESP32 (сеть без интернета)
    await _bindToWifi();
    if (mounted) {
      setState(() {
        _connectionState = ConnectionStatus.connecting;
        _lastError = 'Подключение...';
      });
    }

    debugPrint('Подключаюсь к ESP32 на $_esp32Address...');

    try {
      await _disconnect();

      debugPrint('Проверяю ping ESP32...');
      if (!await _pingEsp32()) {
        throw Exception('ESP32 не отвечает на ping');
      }

      debugPrint('ESP32 доступен, подключаю WebSocket...');

      _webSocketChannel = IOWebSocketChannel.connect(
        'ws://$_esp32Address:81',
        pingInterval: const Duration(seconds: 15),
      );

      _webSocketSubscription = _webSocketChannel!.stream.listen(
            (message) {
          debugPrint('📥 WebSocket: $message');
          _processIncomingMessage(message.toString());
        },
        onError: (error) {
          debugPrint('❌ WebSocket ошибка: $error');
          if (_connectionState != ConnectionStatus.disconnected) {
            _handleConnectionError('WebSocket ошибка');
          }
        },
        onDone: () {
          debugPrint('🔌 WebSocket закрыт');
          if (_connectionState != ConnectionStatus.disconnected) {
            _handleConnectionError('Соединение закрыто сервером');
          }
        },
        cancelOnError: true,
      );

      // Ждём рукопожатия, но не дольше 8 с: на мёртвой сети .ready
      // может висеть до системного TCP-таймаута и держать _isConnecting
      await _webSocketChannel!.ready.timeout(const Duration(seconds: 8));

      if (_webSocketChannel == null) {
        throw Exception('WebSocket не создан');
      }

      if (mounted) {
        setState(() {
          _connectionState = ConnectionStatus.connected;
          _lastError = '';
        });
      }

      debugPrint('✅ Успешно подключено к ESP32');

      await _startForegroundService();

      // Имя отправляем на каждом подключении: ESP32 не хранит его между сессиями
      _sendUserName();
    } catch (e) {
      debugPrint('❌ Ошибка подключения: $e');
      _handleConnectionError('Не удалось подключиться');
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _disconnect() async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;

    await _stopForegroundService();

    _failPendingEcho();

    // Снимаем ссылки ДО ожиданий, чтобы новая попытка подключения
    // не зацепилась за мёртвый канал
    final subscription = _webSocketSubscription;
    final channel = _webSocketChannel;
    _webSocketSubscription = null;
    _webSocketChannel = null;

    try {
      if (subscription != null) {
        try {
          await subscription.cancel().timeout(const Duration(seconds: 3));
        } catch (e) {
          debugPrint('Ошибка/таймаут отписки: $e');
        }
      }

      if (channel != null) {
        try {
          await channel.sink.close().timeout(const Duration(seconds: 8));
        } catch (e) {
          debugPrint('Ошибка/таймаут при закрытии канала: $e');
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _connectionState = ConnectionStatus.disconnected;
          _lastError = '';
        });
      }
      _isDisconnecting = false;
    }
  }

  void _handleConnectionError(String error) {
    if (_connectionState == ConnectionStatus.disconnected || _isDisconnecting) return;

    if (mounted) {
      setState(() {
        _connectionState = ConnectionStatus.error;
        _lastError = error;
      });
    }

    // Повторную попытку сделает _checkConnection по своему таймеру
  }

  // Подтверждения по оборванному соединению уже не придут
  void _failPendingEcho() {
    if (_pendingEcho.isEmpty) return;

    for (final pending in _pendingEcho) {
      pending.timeout?.cancel();
      pending.message.status = MessageStatus.failed;
    }
    _pendingEcho.clear();

    if (mounted) {
      setState(() {});
    }
  }

  void _sendUserName() {
    if (_webSocketChannel != null && _connectionState == ConnectionStatus.connected) {
      try {
        _webSocketChannel!.sink.add(buildSetNameFrame(_myName));
        debugPrint('Отправлено имя: $_myName');
      } catch (e) {
        debugPrint('Ошибка отправки имени: $e');
      }
    }
  }

  // ============================
  // Обработка сообщений
  // ============================

  void _processIncomingMessage(String message) {
    if (!mounted) return;

    final frame = parseIncomingFrame(message);

    switch (frame.kind) {
      case IncomingKind.ignore:
        return;
      case IncomingKind.ping:
        if (_webSocketChannel != null &&
            _connectionState == ConnectionStatus.connected) {
          _webSocketChannel!.sink.add("pong");
        }
        return;
      case IncomingKind.system:
        _showSnackBar(frame.text);
        return;
      case IncomingKind.chat:
        break;
    }

    // Своё сообщение, вернувшееся широковещательно. Сверяем с очередью
    // отправленных, а не с именем: у собеседника имя может совпадать
    final echoIndex = _pendingEcho.indexWhere((p) => p.frame == frame.echoKey);
    if (echoIndex >= 0) {
      final pending = _pendingEcho.removeAt(echoIndex);
      pending.timeout?.cancel();
      setState(() {
        pending.message.status = MessageStatus.delivered;
      });
      return;
    }

    // В истории собственные сообщения не отличить по очереди эха (она очищена
    // при разрыве), поэтому опираемся на имя
    final isMine = frame.isHistory && frame.from == _myName;

    // Прошивка отдаёт последние 20 кадров при каждом рукопожатии: после
    // переподключения те же сообщения приходят повторно
    if (frame.isHistory && _alreadyShown(frame.from, frame.text, isMine)) {
      return;
    }

    setState(() {
      _messages.add(Message(frame.from, frame.text, isMine));
      if (_messages.length > 500) {
        _messages.removeAt(0);
      }
    });
    _scrollToBottom();

    // История из буфера прошивки доезжает после переподключения: сообщение
    // уже не новое, звук и уведомление по нему только мешают
    if (frame.isHistory) return;

    // Только чужие сообщения: ping, System: и собственное эхо ушли по return выше
    if (_isForeground || !Platform.isAndroid) {
      _playNotificationSound();
    } else {
      _showMessageNotification(frame.from, frame.text);
    }
  }

  bool _alreadyShown(String from, String text, bool isMe) {
    for (final message in _messages.reversed) {
      if (message.from == from && message.text == text && message.isMe == isMe) {
        return true;
      }
    }
    return false;
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _connectionState != ConnectionStatus.connected) return;

    // Прошивка режет кадр по байтам, а не по символам: 300 символов
    // кириллицы вместе с "msg:<имя>:" уже близко к её лимиту
    if (!messageFitsFrame(_myName, text)) {
      _showSnackBar('Сообщение слишком длинное для передачи');
      return;
    }

    // Добавляем в UI мгновенно, но помечаем как неподтверждённое
    final message = Message(_myName, text, true, status: MessageStatus.sending);
    setState(() {
      _messages.add(message);
      if (_messages.length > 500) {
        _messages.removeAt(0);
      }
    });

    _textController.clear();
    _scrollToBottom();
    // После отправки поле остаётся активным, иначе следующий ввод
    // требует повторного тапа
    _inputFocusNode.requestFocus();

    if (_webSocketChannel == null) {
      setState(() {
        message.status = MessageStatus.failed;
      });
      _showSnackBar('Нет подключения к WebSocket');
      return;
    }

    // Формат кадра: msg:<имя>:<текст>
    final outgoing = buildMessageFrame(_myName, text);
    try {
      _webSocketChannel!.sink.add(outgoing);
      debugPrint('Отправлено через WS: $outgoing');
    } catch (e) {
      // sink.add обычно не бросает: ошибка мёртвого сокета приходит
      // асинхронно в onError, поэтому подтверждением служит только эхо
      debugPrint('Ошибка отправки WS: $e');
      setState(() {
        message.status = MessageStatus.failed;
      });
      _showSnackBar('Не удалось отправить');
      return;
    }

    final pending = _PendingEcho(echoKeyFor(_myName, text), message);
    pending.timeout = Timer(_echoTimeout, () {
      _pendingEcho.remove(pending);
      if (!mounted) return;
      setState(() {
        message.status = MessageStatus.failed;
      });
    });
    _pendingEcho.add(pending);

    if (_pendingEcho.length > _maxPendingEcho) {
      final evicted = _pendingEcho.removeAt(0);
      evicted.timeout?.cancel();
      // Через setState: иначе галочка "отправляется" висела до следующей
      // перерисовки по другому поводу
      setState(() {
        evicted.message.status = MessageStatus.failed;
      });
    }
  }

  String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _buildStatusIcon(Message msg, bool isDark) {
    switch (msg.status) {
      case MessageStatus.sending:
        return Icon(
          Icons.schedule,
          size: 12,
          color: isDark ? Colors.white70 : Colors.black54,
        );
      case MessageStatus.delivered:
        return Icon(
          Icons.done,
          size: 12,
          color: isDark ? Colors.white70 : Colors.black54,
        );
      case MessageStatus.failed:
        return Tooltip(
          message: 'ESP32 не подтвердил приём',
          child: Icon(
            Icons.error_outline,
            size: 12,
            color: isDark ? Colors.red[300] : Colors.red[700],
          ),
        );
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // Список перевёрнут (reverse: true), поэтому низ — это смещение 0.
  // Прокрутка к maxScrollExtent давала промах: у ListView.builder он
  // оценочный, пока не измерены все элементы
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ============================
  // Диалоги
  // ============================

  void _showChangeNameDialog() {
    final prefs = _prefs;
    if (prefs == null) {
      _showSnackBar('Настройки ещё загружаются');
      return;
    }

    _nameController.text = _myName;

    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Изменить имя'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                maxLength: _maxNameLength,
                decoration: const InputDecoration(
                  labelText: 'Ваше имя в чате',
                  border: OutlineInputBorder(),
                  hintText: 'Введите новое имя',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 10),
              Text(
                'Текущее имя: $_myName',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: () async {
                final newName = _nameController.text.trim();
                // Прошивка отделяет имя от текста первым двоеточием:
                // с ним имя дойдёт до собеседников обрезанным
                if (newName.contains(':')) {
                  _showSnackBar('Имя не может содержать двоеточие');
                  return;
                }
                if (newName.isNotEmpty && newName != _myName) {
                  await prefs.setString('user_name', newName);
                  setState(() {
                    _myName = newName;
                  });
                  if (_connectionState == ConnectionStatus.connected) {
                    _sendUserName();
                  }
                  if (!context.mounted) return;
                  Navigator.pop(context);
                } else if (newName.isEmpty) {
                  _showSnackBar('Имя не может быть пустым');
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    );
  }

  // ============================
  // UI
  // ============================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isConnected = _connectionState == ConnectionStatus.connected;

    String statusText = '';
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.wifi_off;

    switch (_connectionState) {
      case ConnectionStatus.disconnected:
        statusText = _lastError.isNotEmpty ? _lastError : 'Нет подключения';
        statusColor = Colors.red;
        statusIcon = Icons.wifi_off;
        break;
      case ConnectionStatus.connecting:
        statusText = 'Подключение к ESP32...';
        statusColor = Colors.orange;
        statusIcon = Icons.wifi_find;
        break;
      case ConnectionStatus.connected:
        statusText = 'Подключено к ESP32';
        statusColor = Colors.green;
        statusIcon = Icons.wifi;
        break;
      case ConnectionStatus.error:
        statusText = _lastError;
        statusColor = Colors.red;
        statusIcon = Icons.error;
        break;
    }

    return Column(
      children: [
        // Кастомный Title Bar для Linux
        if (widget.isLinux)
          Container(
            height: 32,
            color: Colors.grey[300],
            child: Row(
              children: [
                Expanded(
                  child: DragToMoveArea(
                    child: Container(
                      padding: const EdgeInsets.only(left: 12),
                      alignment: Alignment.centerLeft,
                      child: const Text(
                        'UV-82 Chat',
                        style: TextStyle(color: Colors.black, fontSize: 14),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.minimize, size: 16),
                  onPressed: () => windowManager.minimize(),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => windowManager.close(),
                ),
              ],
            ),
          ),

        // Основной Scaffold
        Expanded(
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Радиочат', style: TextStyle(color: Colors.white)),
              backgroundColor: Colors.green[800],
              actions: [
                IconButton(
                  icon: Icon(_soundEnabled
                      ? Icons.notifications_active
                      : Icons.notifications_off),
                  onPressed: _toggleSound,
                  tooltip: _soundEnabled ? 'Выключить звук' : 'Включить звук',
                  color: Colors.white,
                ),
                IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: _prefs == null ? null : _showChangeNameDialog,
                  tooltip: 'Изменить имя',
                  color: Colors.white,
                ),
              ],
            ),
            body: Column(
              children: [
                // Панель статуса
                Container(
                  padding: const EdgeInsets.all(12),
                  color: statusColor.withAlpha(26),
                  child: Row(
                    children: [
                      Icon(statusIcon, color: statusColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              statusText,
                              style: TextStyle(
                                color: statusColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'WiFi: $_currentWifiName • IP: $_deviceIp',
                              style: const TextStyle(fontSize: 12),
                            ),
                            if (_connectionState == ConnectionStatus.connected)
                              Text(
                                'Ваше имя: $_myName',
                                style: const TextStyle(fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                      if (_connectionState == ConnectionStatus.error ||
                          _connectionState == ConnectionStatus.disconnected)
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: statusColor,
                            side: BorderSide(color: statusColor),
                          ),
                          onPressed: _isConnecting || _isDisconnecting
                              ? null
                              : () async {
                            await _disconnect();
                            await Future.delayed(const Duration(milliseconds: 100));
                            _connectToEsp32();
                          },
                          child: _isConnecting || _isDisconnecting
                              ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: statusColor,
                            ),
                          )
                              : const Text('Подключить'),
                        ),
                    ],
                  ),
                ),

                // Список сообщений
                Expanded(
                  child: _messages.isEmpty
                      ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _connectionState == ConnectionStatus.connected
                              ? Icons.chat_bubble_outline
                              : statusIcon,
                          size: 64,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _connectionState == ConnectionStatus.connected
                              ? 'Нет сообщений\nОтправьте первое сообщение'
                              : 'Подключитесь к ESP32',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                      : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[_messages.length - 1 - index];
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                        alignment: msg.isMe
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: msg.isMe
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            Text(
                              msg.from,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: msg.isMe
                                    ? (isDark
                                        ? Colors.green[200]
                                        : Colors.green[900])
                                    : (isDark
                                        ? Colors.blue[200]
                                        : Colors.blue[700]),
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.of(context)
                                    .size
                                    .width *
                                    0.75,
                              ),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: msg.isMe
                                    ? (isDark
                                        ? Colors.green[800]
                                        : Colors.green[100])
                                    : (isDark
                                        ? Colors.grey[800]
                                        : Colors.grey[200]),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              // Цвет текста задаём явно: пузыри не следуют
                              // за темой, поэтому наследованный белый
                              // на светлом фоне не читался
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    msg.text,
                                    style: TextStyle(
                                      color: isDark
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.end,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _formatTime(msg.timestamp),
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isDark
                                              ? Colors.white70
                                              : Colors.black54,
                                        ),
                                      ),
                                      if (msg.isMe) ...[
                                        const SizedBox(width: 4),
                                        _buildStatusIcon(msg, isDark),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // Поле ввода. Не убираем из дерева при потере связи, а
                // блокируем: пересоздание TextField теряло подключение к
                // клавиатуре, из-за чего первый ввод не доходил до поля
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          focusNode: _inputFocusNode,
                          enabled: isConnected,
                          minLines: 1,
                          maxLines: 4,
                          // Кадр длиннее килобайта прошивка не принимает
                          maxLength: _maxMessageLength,
                          buildCounter: (
                            context, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) {
                            // Счётчик показываем только когда лимит близко
                            if (maxLength == null ||
                                currentLength < maxLength - 50) {
                              return null;
                            }
                            return Text(
                              '$currentLength/$maxLength',
                              style: const TextStyle(fontSize: 11),
                            );
                          },
                          textInputAction: TextInputAction.send,
                          keyboardType: TextInputType.text,
                          decoration: InputDecoration(
                            hintText: isConnected
                                ? 'Введите сообщение...'
                                : 'Нет связи с ESP32',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.send),
                              onPressed: isConnected ? _sendMessage : null,
                            ),
                          ),
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}