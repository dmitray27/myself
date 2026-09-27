import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Содержимое окна «Прошивка УПТС-РК1», загружаемое из assets/flash_info.json.
class FlashInfo {
  final String title;
  final String url;
  final List<String> intro;
  final String stepsTitle;
  final List<String> steps;
  final String notesTitle;
  final List<String> notes;
  final String downloadTitle;
  final String downloadIntro;
  final List<FirmwareDownload> downloads;

  const FlashInfo({
    required this.title,
    required this.url,
    required this.intro,
    required this.stepsTitle,
    required this.steps,
    required this.notesTitle,
    required this.notes,
    required this.downloadTitle,
    required this.downloadIntro,
    required this.downloads,
  });

  factory FlashInfo.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) =>
        (json[key] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList();
    return FlashInfo(
      title: json['title'] as String? ?? 'Прошивка УПТС-РК1',
      url: json['url'] as String? ?? '',
      intro: strings('intro'),
      stepsTitle: json['stepsTitle'] as String? ?? '',
      steps: strings('steps'),
      notesTitle: json['notesTitle'] as String? ?? '',
      notes: strings('notes'),
      downloadTitle: json['downloadTitle'] as String? ?? 'Скачать образ',
      downloadIntro: json['downloadIntro'] as String? ?? '',
      downloads: (json['downloads'] as List<dynamic>? ?? const [])
          .map((e) => FirmwareDownload.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static Future<FlashInfo> load(
      {String asset = 'assets/flash_info.json'}) async {
    final raw = await rootBundle.loadString(asset);
    return FlashInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }
}

/// Ссылка на образ merge.bin для одного типа платы.
class FirmwareDownload {
  final String chip;
  final String note;
  final String url;

  const FirmwareDownload({
    required this.chip,
    required this.note,
    required this.url,
  });

  factory FirmwareDownload.fromJson(Map<String, dynamic> json) =>
      FirmwareDownload(
        chip: json['chip'] as String? ?? '',
        note: json['note'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );
}

/// Кнопка с платой для leading в AppBar: инструкция по прошивке.
class FlashButton extends StatelessWidget {
  final Color color;

  const FlashButton({super.key, this.color = const Color(0x99FFFFFF)});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Прошивка УПТС-РК1',
      onPressed: () => showFlashDialog(context),
      icon: Icon(Icons.developer_board, color: color),
    );
  }
}

/// Кнопка со стрелкой вниз для leading в AppBar: скачать merge.bin.
class DownloadButton extends StatelessWidget {
  final Color color;

  const DownloadButton({super.key, this.color = const Color(0x99FFFFFF)});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Скачать образ прошивки',
      onPressed: () => showDownloadDialog(context),
      icon: Icon(Icons.download, color: color),
    );
  }
}

Future<void> showDownloadDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const DownloadDialog(),
  );
}

class DownloadDialog extends StatelessWidget {
  const DownloadDialog({super.key});

  Future<void> _open(BuildContext context, FirmwareDownload d) async {
    final uri = Uri.tryParse(d.url);
    final ok = uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть ссылку: ${d.url}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: FutureBuilder<FlashInfo>(
          future: FlashInfo.load(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text(
                  'Не удалось загрузить flash_info.json:\n${snapshot.error}');
            }
            final info = snapshot.data;
            if (info == null) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.downloadTitle, style: theme.titleLarge),
                const SizedBox(height: 12),
                Text(info.downloadIntro, style: theme.bodyMedium),
                const SizedBox(height: 12),
                for (final d in info.downloads)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.download),
                    title: Text(d.chip),
                    subtitle: Text(d.note),
                    onTap: () => _open(context, d),
                  ),
              ],
            );
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
              if (info.downloads.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(info.downloadTitle, style: theme.titleMedium),
                const SizedBox(height: 8),
                for (final d in info.downloads)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SelectableText(
                      '${d.chip}: ${d.url}',
                      style: theme.bodyMedium,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
