import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:radiochat/info_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('info dialog text is selectable and copyable', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(const MaterialApp(home: InfoDialog()));
    await tester
        .runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    final area = find.byType(SelectionArea);
    expect(area, findsOneWidget);
    expect(
        find.descendant(of: area, matching: find.byType(Text)), findsWidgets);

    final title = tester.widget<Text>(
        find.descendant(of: area, matching: find.byType(Text)).first);
    final titleText = title.data!;

    // Выделить всё через клавиатуру и скопировать — как делает контекстное меню
    await tester.tap(find.text(titleText));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(copied, hasLength(1));
    expect(copied.single, contains(titleText));
  });
}
