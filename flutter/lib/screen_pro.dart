import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'chat_controller.dart';

class ChatScreen extends StatefulWidget {
  final bool isLinux;

  const ChatScreen({super.key, required this.isLinux});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final ChatController _controller;
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _controller = ChatController()
      ..onMessageAdded = _scrollToBottom
      ..addListener(_onControllerChanged)
      ..init();

    _controller.snackBar.addListener(_onSnackBar);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _controller.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.snackBar.removeListener(_onSnackBar);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _textController.dispose();
    _nameController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onSnackBar() {
    final message = _controller.snackBar.value;
    if (message == null || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showSnackBar(message);
      _controller.snackBar.value = null;
    });
  }

  // ============================
  // UI helpers
  // ============================

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
  // Actions
  // ============================

  Future<void> _send() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    await _controller.sendMessage(text);
    _textController.clear();
    _inputFocusNode.requestFocus();
  }

  Future<void> _showChangeNameDialog() async {
    _nameController.text = _controller.myName;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Изменить имя'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                maxLength: _controller.maxNameLength,
                decoration: const InputDecoration(
                  labelText: 'Ваше имя в чате',
                  border: OutlineInputBorder(),
                  hintText: 'Введите новое имя',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 10),
              Text(
                'Текущее имя: ${_controller.myName}',
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
                final error = await _controller.setName(newName);
                if (error != null) {
                  _showSnackBar(error);
                  return;
                }
                if (!context.mounted) return;
                Navigator.pop(context);
              },
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmExit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Выйти из радиочата?'),
          content: const Text(
            'Соединение с ESP32 будет закрыто, уведомления сняты, '
            'новые сообщения приходить не будут.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Выйти'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    await _controller.exit();

    if (Platform.isAndroid) {
      await SystemNavigator.pop();
    } else {
      await windowManager.close();
    }
  }

  // ============================
  // Build
  // ============================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isConnected = _controller.isConnected;
    final messages = _controller.messages;

    String statusText = '';
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.wifi_off;

    switch (_controller.connectionStatus) {
      case ConnectionStatus.disconnected:
        statusText = _controller.networkHint.isNotEmpty
            ? _controller.networkHint
            : 'Нет подключения';
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
        statusText = _controller.connectionError;
        statusColor = Colors.red;
        statusIcon = Icons.error;
        break;
    }

    return Column(
      children: [
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

        Expanded(
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Радиочат', style: TextStyle(color: Colors.white)),
              backgroundColor: Colors.green[800],
              actions: [
                IconButton(
                  icon: Icon(_controller.soundEnabled
                      ? Icons.notifications_active
                      : Icons.notifications_off),
                  onPressed: _controller.toggleSound,
                  tooltip: _controller.soundEnabled ? 'Выключить звук' : 'Включить звук',
                  color: Colors.white,
                ),
                IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: _showChangeNameDialog,
                  tooltip: 'Изменить имя',
                  color: Colors.white,
                ),
                IconButton(
                  icon: const Icon(Icons.power_settings_new),
                  onPressed: _confirmExit,
                  tooltip: 'Выйти',
                  color: Colors.white,
                ),
              ],
            ),
            body: Column(
              children: [
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
                              'WiFi: ${_controller.currentWifiName} • IP: ${_controller.deviceIp}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            if (isConnected)
                              Text(
                                'Ваше имя: ${_controller.myName}',
                                style: const TextStyle(fontSize: 11),
                              ),
                            if (_controller.notificationsDenied)
                              const Text(
                                'Уведомления запрещены: в фоне сообщения не видны',
                                style: TextStyle(fontSize: 11),
                              ),
                          ],
                        ),
                      ),
                      if (_controller.connectionStatus == ConnectionStatus.error ||
                          _controller.connectionStatus == ConnectionStatus.disconnected)
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: statusColor,
                            side: BorderSide(color: statusColor),
                          ),
                          onPressed: _controller.isBusy
                              ? null
                              : () => _controller.reconnect(),
                          child: _controller.isBusy
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

                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isConnected ? Icons.chat_bubble_outline : statusIcon,
                                size: 64,
                                color: Colors.grey,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                isConnected
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
                          itemCount: messages.length,
                          itemBuilder: (context, index) {
                            final msg = messages[messages.length - 1 - index];
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
                                      maxWidth: MediaQuery.of(context).size.width * 0.75,
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
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
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
                                          mainAxisAlignment: MainAxisAlignment.end,
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
                          maxLength: _controller.maxMessageLength,
                          buildCounter: (
                            context, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) {
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
                              onPressed: isConnected ? _send : null,
                            ),
                          ),
                          onSubmitted: (_) => _send(),
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
