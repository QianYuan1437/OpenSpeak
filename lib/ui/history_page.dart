import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'home_shell.dart';
import 'i18n.dart';
import 'widgets.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: dictation,
      builder: (context, _) {
        final items = dictation.history;
        final scheme = Theme.of(context).colorScheme;
        return PageFrame(
          title: t('历史', 'History'),
          actions: [
            if (items.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(t('全部清除', 'Clear all')),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text(t('清除全部历史？', 'Clear all history?')),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('取消', 'Cancel'))),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('清除', 'Clear'))),
                      ],
                    ),
                  );
                  if (ok == true) dictation.clearHistory();
                },
              ),
          ],
          children: [
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Column(children: [
                  Icon(Icons.history_toggle_off_rounded, size: 56, color: scheme.outline),
                  const SizedBox(height: 12),
                  Text(t('还没有听写记录', 'No dictations yet'), style: TextStyle(color: scheme.outline)),
                ]),
              ),
            for (final h in items)
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
                  title: Text(h.text, style: const TextStyle(height: 1.5)),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${_fmt(h.time)} · ${formatDuration(h.audioMs)}',
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                  ),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: t('复制', 'Copy'),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: h.text));
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(t('已复制', 'Copied'))));
                      },
                    ),
                    IconButton(
                      tooltip: t('删除', 'Delete'),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => dictation.removeHistory(h),
                    ),
                  ]),
                ),
              ),
          ],
        );
      },
    );
  }

  static String _fmt(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
