import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:radio_bridge_dual/flash_dialog.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Подмена url_launcher: запоминает URL, которые пытались открыть.
/// Method-channel мок не подходит — в `flutter test` на Linux регистрируется
/// UrlLauncherLinux (dart_plugin_registrant), а не MethodChannelUrlLauncher.
class _LaunchSpy extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final List<String> launched = [];
  bool result = true;

  void install() => UrlLauncherPlatform.instance = this;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return result;
  }
}

/// Открывает диалог и даёт FutureBuilder дочитать asset (реальный I/O,
/// поэтому через runAsync, а не pumpAndSettle — спиннер крутится бесконечно).
Future<void> _openAndLoad(WidgetTester tester, Finder button) async {
  await tester.tap(button);
  await tester.pump();
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pump();
}

Widget _host(Widget dialogOpener) => MaterialApp(
      home: Scaffold(body: Builder(builder: (context) => dialogOpener)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlashInfo', () {
    test('loads real assets/flash_info.json', () async {
      final info = await FlashInfo.load();
      expect(info.title, contains('УПТС-РК1'));
      expect(info.url, 'https://espressif.github.io/esp-launchpad/');
      expect(info.steps, isNotEmpty);
      expect(info.steps.first, contains('Скачайте образ'));
      expect(info.downloads.map((d) => d.chip), ['ESP32-WROOM', 'ESP32-S3']);
      for (final d in info.downloads) {
        expect(Uri.tryParse(d.url)?.hasScheme, isTrue, reason: d.url);
        expect(d.url, endsWith('.bin'));
      }
    });

    test('fromJson tolerates missing fields', () {
      final info = FlashInfo.fromJson(jsonDecode('{}') as Map<String, dynamic>);
      expect(info.title, 'Прошивка УПТС-РК1');
      expect(info.steps, isEmpty);
      expect(info.downloads, isEmpty);
    });
  });

  group('FlashButton / FlashDialog', () {
    testWidgets('opens instruction with steps, links and Закрыть',
        (tester) async {
      await tester.pumpWidget(_host(const FlashButton()));
      expect(find.byIcon(Icons.developer_board), findsOneWidget);

      await _openAndLoad(tester, find.byType(FlashButton));

      expect(find.byType(FlashDialog), findsOneWidget);
      expect(find.textContaining('Порядок прошивки'), findsOneWidget);
      expect(find.textContaining('esp-launchpad'), findsWidgets);
      expect(find.textContaining('ESP32-WROOM:'), findsOneWidget);
      expect(find.textContaining('ESP32-S3:'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(FlashDialog), findsNothing);
    });
  });

  group('DownloadButton / DownloadDialog', () {
    testWidgets('lists both chips and opens the matching URL', (tester) async {
      final spy = _LaunchSpy()..install();
      final info = (await tester.runAsync(FlashInfo.load))!;
      await tester.pumpWidget(_host(const DownloadButton()));
      expect(find.byIcon(Icons.download), findsOneWidget);

      await _openAndLoad(tester, find.byType(DownloadButton));

      expect(find.byType(DownloadDialog), findsOneWidget);
      expect(find.text('ESP32-WROOM'), findsOneWidget);
      expect(find.text('ESP32-S3'), findsOneWidget);

      await tester.tap(find.text('ESP32-S3'));
      await tester.pumpAndSettle();
      expect(spy.launched, [info.downloads[1].url]);

      await tester.tap(find.text('ESP32-WROOM'));
      await tester.pumpAndSettle();
      expect(spy.launched, [info.downloads[1].url, info.downloads[0].url]);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadDialog), findsNothing);
    });

    testWidgets('shows snackbar when the link cannot be opened',
        (tester) async {
      final spy = _LaunchSpy()
        ..result = false
        ..install();
      await tester.pumpWidget(_host(const DownloadButton()));
      await _openAndLoad(tester, find.byType(DownloadButton));

      await tester.tap(find.text('ESP32-WROOM'));
      await tester.pumpAndSettle();

      expect(spy.launched, hasLength(1));
      expect(find.textContaining('Не удалось открыть ссылку'), findsOneWidget);
    });
  });
}
