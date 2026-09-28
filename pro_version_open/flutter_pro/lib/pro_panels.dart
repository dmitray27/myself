import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_controller.dart';
import 'history_store.dart' show writeHistoryFile;

/// Подпись статуса своего сообщения. Только «принято абонентом» означает,
/// что удалённая станция подтвердила приём по эфиру.
String statusLabel(Message m) {
  switch (m.status) {
    case MessageStatus.sending:
      return 'Отправляется на УПТС-РК1';
    case MessageStatus.accepted:
      return 'Принято УПТС-РК1, ждёт эфира';
    case MessageStatus.aired:
      return 'Передано в эфир, ждём подтверждения';
    case MessageStatus.delivered:
      return m.ackStation.isEmpty
          ? 'Принято абонентом'
          : 'Принято абонентом ${m.ackStation}';
    case MessageStatus.noack:
      return 'Нет подтверждения из эфира';
    case MessageStatus.failed:
      return 'Не доставлено';
  }
}

/// Иконка статуса: одна галочка — ушло в эфир, две — подтверждено абонентом.
Widget statusIcon(Message m, bool isDark, {double size = 12}) {
  final dim = isDark ? Colors.white70 : Colors.black54;
  final IconData icon;
  Color color = dim;
  switch (m.status) {
    case MessageStatus.sending:
      icon = Icons.schedule;
      break;
    case MessageStatus.accepted:
      icon = Icons.hourglass_bottom;
      break;
    case MessageStatus.aired:
      icon = Icons.done;
      break;
    case MessageStatus.delivered:
      icon = Icons.done_all;
      color = isDark ? Colors.lightGreenAccent : Colors.green[800]!;
      break;
    case MessageStatus.noack:
      icon = Icons.hearing_disabled;
      color = isDark ? Colors.orange[300]! : Colors.orange[800]!;
      break;
    case MessageStatus.failed:
      icon = Icons.error_outline;
      color = isDark ? Colors.red[300]! : Colors.red[700]!;
      break;
  }
  return Tooltip(
    message: statusLabel(m),
    child: Icon(icon, size: size, color: color),
  );
}

/// Строка состояния канала под шапкой: занятость эфира, сигнал, абоненты.
class LinkBar extends StatelessWidget {
  final LinkStats stats;
  final List<Peer> peers;
  final bool large;
  final VoidCallback onTap;

  const LinkBar({
    super.key,
    required this.stats,
    required this.peers,
    required this.large,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fontSize = large ? 15.0 : 12.0;
    final iconSize = large ? 20.0 : 16.0;
    final busy = stats.rxBusy || stats.txBusy;
    final busyText = stats.txBusy
        ? 'передача'
        : stats.rxBusy
            ? 'приём'
            : 'свободен';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: large ? 8 : 4),
        child: Row(
          children: [
            Icon(
              busy ? Icons.cell_tower : Icons.radio,
              size: iconSize,
              color: busy ? Colors.orange : null,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Эфир: $busyText • сигнал ${stats.signalDb} дБ • '
                'преамбула ${stats.preamblePct}% • CRC ${stats.crcErrors}',
                style: TextStyle(fontSize: fontSize),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.people, size: iconSize),
            const SizedBox(width: 2),
            Text('${peers.length}', style: TextStyle(fontSize: fontSize)),
          ],
        ),
      ),
    );
  }
}

String _age(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} с';
  if (d.inMinutes < 60) return '${d.inMinutes} мин';
  return '${d.inHours} ч';
}

/// Диалог статистики канала и списка абонентов.
Future<void> showLinkDialog(BuildContext context, ChatController c) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          final s = c.stats;
          final peers = c.peers();
          Widget row(String k, String v) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(k), Text(v)],
                ),
              );
          return AlertDialog(
            title: Text(
              s.station.isEmpty ? 'Канал' : 'Канал • станция ${s.station}',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  row(
                      'Эфир',
                      s.txBusy
                          ? 'передача'
                          : s.rxBusy
                              ? 'приём'
                              : 'свободен'),
                  row('Сигнал', '${s.signalDb} дБ'),
                  row('Преамбула', '${s.preamblePct}%'),
                  const Divider(),
                  row('Кадров принято', '${s.rxFrames}'),
                  row('Ошибок CRC', '${s.crcErrors}'),
                  row('Кадров прервано', '${s.framesAborted}'),
                  row('Сообщений принято', '${s.rxMessages}'),
                  row('Сообщений неполных', '${s.rxIncomplete}'),
                  const Divider(),
                  row('Передано', '${s.txMessages}'),
                  row('Подтверждено абонентом', '${s.txAcked}'),
                  row('Без подтверждения', '${s.txNoack}'),
                  const Divider(),
                  Text(
                    'В эфире (по подтверждениям)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (peers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('Подтверждений ещё не было'),
                    ),
                  for (final p in peers)
                    row('Станция ${p.station}', '${_age(p.age())} назад'),
                  const SizedBox(height: 8),
                  Text(
                    'Статистика приходит от УПТС-РК1 (кадр stat). Абонент в '
                    'списке — от него недавно был ACK; это не гарантия, что '
                    'он слышит вас сейчас.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Настройки PRO: полевой режим, история, точка доступа.
Future<void> showSettingsDialog(BuildContext context, ChatController c) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          return AlertDialog(
            title: const Text('Настройки PRO'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Полевой режим'),
                    subtitle: const Text('Тёмная тема, крупные кнопки и шрифт'),
                    value: c.fieldMode,
                    onChanged: (v) => c.setFieldMode(v),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history),
                    title: const Text('История'),
                    subtitle:
                        Text('${c.messages.length} сообщений на телефоне'),
                    onTap: () => showHistoryDialog(context, c),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.wifi_password),
                    title: const Text('Точка доступа УПТС-РК1'),
                    subtitle: const Text('Имя сети и пароль платы'),
                    enabled: c.isConnected,
                    onTap: () => showApConfigDialog(context, c),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> showHistoryDialog(BuildContext context, ChatController c) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('История сообщений'),
        content: Text(
          'На телефоне сохранено ${c.messages.length} сообщений. Они '
          'останутся после «Выйти» и перезапуска приложения.',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final nav = Navigator.of(context);
              await c.clearHistory();
              nav.pop();
              messenger.showSnackBar(
                const SnackBar(content: Text('История очищена')),
              );
            },
            child: const Text('Очистить'),
          ),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final nav = Navigator.of(context);
              await Clipboard.setData(
                ClipboardData(text: c.exportHistoryText()),
              );
              nav.pop();
              messenger.showSnackBar(
                const SnackBar(content: Text('История скопирована в буфер')),
              );
            },
            child: const Text('Копировать'),
          ),
          ElevatedButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final nav = Navigator.of(context);
              String result;
              try {
                final path = await writeHistoryFile(c.exportHistoryText());
                result = 'Сохранено: $path';
              } catch (e) {
                result = 'Не удалось сохранить файл: $e';
              }
              nav.pop();
              messenger.showSnackBar(SnackBar(content: Text(result)));
            },
            child: const Text('В файл .txt'),
          ),
        ],
      );
    },
  );
}

Future<void> showApConfigDialog(BuildContext context, ChatController c) async {
  final ssid =
      TextEditingController(text: await c.fetchAccessPointSsid() ?? '');
  final pass = TextEditingController();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) {
      String? error;
      bool busy = false;
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> apply({bool reset = false}) async {
            setState(() {
              busy = true;
              error = null;
            });
            final err = await c.configureAccessPoint(
              ssid: ssid.text.trim(),
              password: pass.text,
              reset: reset,
            );
            if (!context.mounted) return;
            if (err != null) {
              setState(() {
                busy = false;
                error = err;
              });
              return;
            }
            final messenger = ScaffoldMessenger.of(context);
            Navigator.pop(context);
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                  'УПТС-РК1 перезапускается. Подключите телефон к новой сети '
                  'Wi-Fi платы.',
                ),
                duration: Duration(seconds: 6),
              ),
            );
          }

          return AlertDialog(
            title: const Text('Точка доступа УПТС-РК1'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ssid,
                  maxLength: 32,
                  decoration: const InputDecoration(
                    labelText: 'Имя сети (SSID)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: pass,
                  maxLength: 63,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Пароль (8–63 символа)',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'После сохранения плата перезапустится с новыми данными; '
                  'текущее соединение прервётся. Пароль хранится только на плате.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => apply(reset: true),
                child: const Text('Сбросить'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              ElevatedButton(
                onPressed: busy ? null : apply,
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Сохранить'),
              ),
            ],
          );
        },
      );
    },
  );
  ssid.dispose();
  pass.dispose();
}
