import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import 'package:window_manager/window_manager.dart';
import 'screen_pro.dart';
import 'dart:async';

void main() {
  // Всё, что трогает биндинги, должно жить внутри той же зоны, что и runApp,
  // иначе Flutter ругается на несовпадение зон
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Глобальная обработка ошибок Flutter
    FlutterError.onError = (details) {
      debugPrint('❌ Flutter Error: ${details.exception}');
      if (details.stack != null) {
        debugPrint('Stack: ${details.stack}');
      }
    };

    // Инициализация window_manager ТОЛЬКО для Linux
    if (Platform.isLinux) {
      try {
        await windowManager.ensureInitialized();

        const windowOptions = WindowOptions(
          size: Size(400, 800),
          center: true,
          minimumSize: Size(400, 800),
          maximumSize: Size(400, 800),
          titleBarStyle: TitleBarStyle.hidden,
        );

        await windowManager.waitUntilReadyToShow(windowOptions, () async {
          await windowManager.show();
          await windowManager.focus();
        });

      } catch (e) {
        // Ошибка window_manager не критична – приложение всё равно запустится
        debugPrint('⚠️ WindowManager error (non-critical): $e');
      }
    }

    runApp(const MyApp());
  }, (error, stack) {
    debugPrint('❌ Unhandled error: $error');
    debugPrint('Stack: $stack');
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final isLinux = Platform.isLinux;

    return MaterialApp(
      title: 'UV-82 Chat',
      debugShowCheckedModeBanner: false,
      home: ChatScreen(isLinux: isLinux),

      // Светлая тема
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 2,
        ),
      ),

      // Тёмная тема
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 2,
        ),
      ),

      // Автоматически переключается в зависимости от системы
      themeMode: ThemeMode.system,

      // Для десктопа – стильные скроллбары
      builder: (context, child) {
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: Platform.isLinux || Platform.isWindows || Platform.isMacOS,
          ),
          child: child!,
        );
      },
    );
  }
}