import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Содержимое окна «Прошивка ESP32», загружаемое из assets/flash_info.json.
class FlashInfo {
  final String title;
  final String url;
  final List<String> intro;
  final String stepsTitle;
  final List<String> steps;
  final String notesTitle;
  final List<String> notes;

  const FlashInfo({
    required this.title,
    required this.url,
    required this.intro,
    required this.stepsTitle,
    required this.steps,
    required this.notesTitle,
    required this.notes,
  });

  factory FlashInfo.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) =>
        (json[key] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();
    return FlashInfo(
      title: json['title'] as String? ?? 'Прошивка ESP32',
      url: json['url'] as String? ?? '',
      intro: strings('intro'),
      stepsTitle: json['stepsTitle'] as String? ?? '',
      steps: strings('steps'),
      notesTitle: json['notesTitle'] as String? ?? '',
      notes: strings('notes'),
    );
  }

  static Future<FlashInfo> load(
      {String asset = 'assets/flash_info.json'}) async {
    final raw = await rootBundle.loadString(asset);
    return FlashInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }
}

/// Кнопка с микросхемой для leading в AppBar.
class FlashButton extends StatelessWidget {
  final Color color;

  const FlashButton({super.key, this.color = const Color(0x99FFFFFF)});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Прошивка ESP32',
      onPressed: () => showFlashDialog(context),
      icon: Icon(Icons.memory, color: color),
    );
  }
}

Future<void> showFlashDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const FlashDialog(),
  );
}

class FlashDialog extends StatelessWidget {
  const FlashDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: FutureBuilder<FlashInfo>(
          future: FlashInfo.load(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text(
                    'Не удалось загрузить flash_info.json:\n${snapshot.error}'),
              );
            }
            final info = snapshot.data;
            if (info == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return _FlashText(info: info);
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

class _FlashText extends StatefulWidget {
  final FlashInfo info;

  const _FlashText({required this.info});

  @override
  State<_FlashText> createState() => _FlashTextState();
}

class _FlashTextState extends State<_FlashText> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _paragraphs(List<String> lines, TextStyle? style) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(line, style: style),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final theme = Theme.of(context).textTheme;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: PointerDeviceKind.values.toSet(),
      ),
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(info.title, style: theme.titleLarge),
              const SizedBox(height: 12),
              if (info.url.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SelectableText(
                    info.url,
                    style: theme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              _paragraphs(info.intro, theme.bodyMedium),
              const SizedBox(height: 6),
              Text(info.stepsTitle, style: theme.titleMedium),
              const SizedBox(height: 8),
              _paragraphs(info.steps, theme.bodyMedium),
              const SizedBox(height: 6),
              Text(info.notesTitle, style: theme.titleMedium),
              const SizedBox(height: 8),
              _paragraphs(info.notes, theme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
