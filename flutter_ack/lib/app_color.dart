import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Семь фиксированных цветов радуги, из которых пользователь выбирает
/// основной цвет приложения (шапка, свои сообщения, тема).
enum AppColor {
  red('Красный', Colors.red),
  orange('Оранжевый', Colors.orange),
  yellow('Жёлтый', Colors.amber),
  green('Зелёный', Colors.green),
  lightBlue('Голубой', Colors.lightBlue),
  blue('Синий', Colors.indigo),
  violet('Фиолетовый', Colors.purple);

  const AppColor(this.label, this.swatch);

  final String label;
  final MaterialColor swatch;

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

/// Диалог выбора цвета: семь кружков, текущий отмечен галочкой.
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
                          color: c.swatch,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected == c
                                ? Theme.of(context).colorScheme.onSurface
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child: selected == c
                            ? const Icon(Icons.check, color: Colors.white)
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
