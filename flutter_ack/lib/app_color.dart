import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Фиксированные цвета, из которых пользователь выбирает основной цвет
/// приложения (шапка, свои сообщения, тема): семь цветов радуги плюс
/// белый (чёрные текст и иконки, светлая тема) и чёрный (белые текст и
/// иконки, тёмная тема).
enum AppColor {
  red('Красный', Colors.red),
  orange('Оранжевый', Colors.orange),
  yellow('Жёлтый', Colors.amber),
  green('Зелёный', Colors.green),
  lightBlue('Голубой', Colors.lightBlue),
  blue('Синий', Colors.indigo),
  violet('Фиолетовый', Colors.purple),
  white('Белый', Colors.grey,
      barColor: Colors.white, onBar: Colors.black, themeMode: ThemeMode.light),
  black('Чёрный', Colors.grey,
      barColor: Colors.black, onBar: Colors.white, themeMode: ThemeMode.dark);

  const AppColor(
    this.label,
    this.swatch, {
    Color? barColor,
    this.onBar = Colors.white,
    this.themeMode = ThemeMode.system,
  }) : _barColor = barColor;

  final String label;
  final MaterialColor swatch;
  final Color? _barColor;

  /// Цвет текста и иконок в шапке.
  final Color onBar;

  /// Тема: по системе для цветов радуги, фиксированная для белого/чёрного.
  final ThemeMode themeMode;

  /// Цвет шапки.
  Color get barColor => _barColor ?? swatch[900]!;

  /// Фон экрана для белого/чёрного; null — по теме.
  Color? get background => _barColor;

  static const AppColor defaultColor = AppColor.green;
  static const _prefKey = 'app_color';

  /// Текущий цвет; MaterialApp и экран чата перестраиваются при изменении.
  static final ValueNotifier<AppColor> current = ValueNotifier(defaultColor);

  static AppColor fromName(String? name) => AppColor.values.firstWhere(
        (c) => c.name == name,
        orElse: () => defaultColor,
      );

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    current.value = fromName(prefs.getString(_prefKey));
  }

  static Future<void> select(AppColor color) async {
    current.value = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, color.name);
  }
}

/// Диалог выбора цвета: кружки цветов, текущий отмечен галочкой.
Future<void> showColorDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Цвет приложения'),
        content: ValueListenableBuilder<AppColor>(
          valueListenable: AppColor.current,
          builder: (context, selected, _) {
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in AppColor.values)
                  Tooltip(
                    message: c.label,
                    child: InkWell(
                      key: ValueKey(c),
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => AppColor.select(c),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: c.barColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected == c
                                ? Theme.of(context).colorScheme.onSurface
                                : Theme.of(context).colorScheme.outlineVariant,
                            width: selected == c ? 3 : 1,
                          ),
                        ),
                        child: selected == c
                            ? Icon(Icons.check, color: c.onBar)
                            : null,
                      ),
                    ),
                  ),
              ],
            );
          },
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
}
