import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'message_store.dart';

/// Постоянное хранилище истории чата: переживает «Выйти» и перезапуск.
abstract class HistoryStore {
  Future<List<Message>> load();
  Future<void> save(Iterable<Message> messages);
}

/// История в SharedPreferences одной JSON-строкой. 500 сообщений по
/// 300 символов — до ~400 КБ, для prefs приемлемо; SQLite не нужен.
class PrefsHistoryStore implements HistoryStore {
  PrefsHistoryStore({this.key = 'history_v1'});

  final String key;

  @override
  Future<List<Message>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    return decodeHistory(raw);
  }

  @override
  Future<void> save(Iterable<Message> messages) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, encodeHistory(messages));
  }
}

/// Хранилище в памяти для тестов.
class MemoryHistoryStore implements HistoryStore {
  List<Message> saved = [];

  @override
  Future<List<Message>> load() async => List.of(saved);

  @override
  Future<void> save(Iterable<Message> messages) async {
    saved = List.of(messages);
  }
}

String encodeHistory(Iterable<Message> messages) =>
    jsonEncode(messages.map((m) => m.toJson()).toList());

/// Повреждённые записи пропускаются, а не роняют загрузку.
List<Message> decodeHistory(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return [];
  }
  if (decoded is! List) return [];
  return decoded.map(Message.fromJson).whereType<Message>().toList();
}

String _two(int v) => v.toString().padLeft(2, '0');

String _stamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String exportStatusLabel(MessageStatus s) {
  switch (s) {
    case MessageStatus.sending:
      return 'отправляется';
    case MessageStatus.accepted:
      return 'принято УПТС-РК1';
    case MessageStatus.aired:
      return 'в эфире';
    case MessageStatus.delivered:
      return 'доставлено';
    case MessageStatus.noack:
      return 'нет подтверждения';
    case MessageStatus.failed:
      return 'не отправлено';
  }
}

/// Текстовый экспорт: по строке на сообщение, свои — со статусом доставки.
String formatHistory(Iterable<Message> messages, {required String myName}) {
  final buf = StringBuffer()
    ..writeln('Радиочат УПТС-РК1 PRO — история ($myName)')
    ..writeln('Экспорт: ${_stamp(DateTime.now())}')
    ..writeln();
  for (final m in messages) {
    buf.write('[${_stamp(m.timestamp)}] ${m.from}: ${m.text}');
    if (m.isMe) {
      buf.write(' — ${exportStatusLabel(m.status)}');
      if (m.ackStation.isNotEmpty) buf.write(' (${m.ackStation})');
    }
    buf.writeln();
  }
  return buf.toString();
}

/// Пишет экспорт в файл и возвращает путь. Android: каталог загрузок
/// приложения (виден через «Файлы»), остальные ОС — документы.
Future<String> writeHistoryFile(String text) async {
  Directory? dir;
  if (Platform.isAndroid) {
    dir = await getDownloadsDirectory();
  }
  dir ??= await getApplicationDocumentsDirectory();
  final name =
      'radiochat_${DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}.txt';
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(text);
  return file.path;
}
