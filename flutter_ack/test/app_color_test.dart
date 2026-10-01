import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:radio_bridge_dual/app_color.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppColor.current.value = AppColor.defaultColor;
  });

  test('seven rainbow colors plus white and black, default green', () {
    expect(AppColor.values.length, 9);
    expect(AppColor.white.barColor, Colors.white);
    expect(AppColor.white.onBar, Colors.black);
    expect(AppColor.white.themeMode, ThemeMode.light);
    expect(AppColor.black.barColor, Colors.black);
    expect(AppColor.black.onBar, Colors.white);
    expect(AppColor.black.themeMode, ThemeMode.dark);
    expect(AppColor.green.barColor, Colors.green[900]);
    expect(AppColor.green.themeMode, ThemeMode.system);
    expect(AppColor.defaultColor, AppColor.green);
    expect(AppColor.fromName('violet'), AppColor.violet);
    expect(AppColor.fromName('nonsense'), AppColor.green);
    expect(AppColor.fromName(null), AppColor.green);
  });

  test('select persists and load restores', () async {
    await AppColor.select(AppColor.red);
    expect(AppColor.current.value, AppColor.red);
    AppColor.current.value = AppColor.green;
    await AppColor.load();
    expect(AppColor.current.value, AppColor.red);
  });

  testWidgets('color dialog shows 9 swatches and applies choice',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showColorDialog(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Цвет приложения'), findsOneWidget);
    for (final c in AppColor.values) {
      expect(find.byKey(ValueKey(c)), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey(AppColor.blue)));
    await tester.pumpAndSettle();
    expect(AppColor.current.value, AppColor.blue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_color'), 'blue');

    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('Цвет приложения'), findsNothing);
  });
}
