import 'package:flutter_test/flutter_test.dart';
import 'package:radio_bridge_dual/chat_protocol.dart';

void main() {
  group('parseIncomingFrame', () {
    test('пустой и невалидный кадр игнорируются', () {
      expect(parseIncomingFrame('').kind, IncomingKind.ignore);
      expect(parseIncomingFrame('   ').kind, IncomingKind.ignore);
      expect(parseIncomingFrame('без двоеточия').kind, IncomingKind.ignore);
      expect(parseIncomingFrame(':текст').kind, IncomingKind.ignore);
      expect(parseIncomingFrame('Vasya:   ').kind, IncomingKind.ignore);
    });

    test('ping распознаётся отдельно от сообщений', () {
      expect(parseIncomingFrame('ping').kind, IncomingKind.ping);
      expect(parseIncomingFrame(' ping ').kind, IncomingKind.ping);
    });

    test('System: отдаёт только текст уведомления', () {
      final frame = parseIncomingFrame('System: TX очередь заполнена');
      expect(frame.kind, IncomingKind.system);
      expect(frame.text, ' TX очередь заполнена');
    });

    test('сообщение делится по первому двоеточию', () {
      final frame = parseIncomingFrame('Vasya:привет: как дела');
      expect(frame.kind, IncomingKind.chat);
      expect(frame.from, 'Vasya');
      expect(frame.text, 'привет: как дела');
    });

    test('эхо своего сообщения совпадает с ключом отправки', () {
      const name = 'Дмитрий';
      const text = 'проверка связи';
      final echoed = parseIncomingFrame('$name:$text');
      expect(echoed.echoKey, echoKeyFor(name, text));
    });

    test('кадр истории разбирается как чат с флагом isHistory', () {
      final frame = parseIncomingFrame('hist:Вася:привет');
      expect(frame.kind, IncomingKind.chat);
      expect(frame.from, 'Вася');
      expect(frame.text, 'привет');
      expect(frame.isHistory, isTrue);
    });

    test('обычный кадр не помечается историей', () {
      expect(parseIncomingFrame('Вася:привет').isHistory, isFalse);
    });
  });

  group('исходящие кадры', () {
    test('формат кадров совпадает с ожидаемым прошивкой', () {
      expect(buildMessageFrame('Vasya', 'hi'), 'msg:Vasya:hi');
      expect(buildSetNameFrame('Vasya'), 'setName:Vasya');
    });

    test('длина считается в байтах UTF-8, а не в символах', () {
      expect(frameByteLength('msg:a:abc'), 9);
      expect(frameByteLength('щ'), 2);

      // 300 символов кириллицы — 600 байт, в кадр помещаются
      expect(messageFitsFrame('Дмитрий', 'я' * 300), isTrue);

      // а вот 600 символов кириллицы уже нет, хотя maxLength поля ввода
      // такую строку пропустил бы при вставке из буфера
      expect(messageFitsFrame('Дмитрий', 'я' * 600), isFalse);
    });
  });
}
