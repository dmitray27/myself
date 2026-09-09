import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Содержимое окна «О приложении», загружаемое из assets/info.json.
class AppInfo {
  final String title;
  final List<String> credits;
  final String manualTitle;
  final List<String> manual;

  const AppInfo({
    required this.title,
    required this.credits,
    required this.manualTitle,
    required this.manual,
  });

  factory AppInfo.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) =>
        (json[key] as List<dynamic>? ?? const []).map((e) => e.toString()).toList();
    return AppInfo(
      title: json['title'] as String? ?? 'О приложении',
      credits: strings('credits'),
      manualTitle: json['manualTitle'] as String? ?? '',
      manual: strings('manual'),
    );
  }

  static Future<AppInfo> load({String asset = 'assets/info.json'}) async {
    final raw = await rootBundle.loadString(asset);
    return AppInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }
}

/// Кнопка «i» (жирный курсив) для leading в AppBar.
class InfoButton extends StatelessWidget {
  final Color color;

  const InfoButton({super.key, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'О приложении',
      onPressed: () => showInfoDialog(context),
      icon: Text(
        'i',
        style: TextStyle(
          color: color,
          fontSize: 24,
          fontWeight: FontWeight.bold,
          fontStyle: FontStyle.italic,
          fontFamily: 'serif',
          height: 1,
        ),
      ),
    );
  }
}

Future<void> showInfoDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const InfoDialog(),
  );
}

class InfoDialog extends StatelessWidget {
  const InfoDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: FutureBuilder<AppInfo>(
          future: AppInfo.load(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text('Не удалось загрузить info.json:\n${snapshot.error}'),
              );
            }
            final info = snapshot.data;
            if (info == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return _InfoText(info: info);
          },
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

class _InfoText extends StatelessWidget {
  final AppInfo info;

  const _InfoText({required this.info});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    // Scrollbar + SingleChildScrollView: прокрутка пальцем в обе стороны,
    // на десктопе — колесом и перетаскиванием полосы
    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(info.title, style: theme.titleLarge),
            const SizedBox(height: 12),
            for (final line in info.credits)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(line, style: theme.bodyMedium),
              ),
            const SizedBox(height: 16),
            Text(info.manualTitle, style: theme.titleMedium),
            const SizedBox(height: 8),
            for (final paragraph in info.manual)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(paragraph, style: theme.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }
}
