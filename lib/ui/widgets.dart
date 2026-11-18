import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/dictation.dart';
import 'i18n.dart';
import 'theme.dart';

/// Compact dropdown that sizes itself to the selected item (up to
/// [maxWidth]). The trigger looks like the app's outlined buttons and the
/// menu is the shared rounded menu (same as [OsMoreMenu]); the current item
/// is ticked. Meant to sit at the end of a [SettingRow].
class OsDropdown<T> extends StatelessWidget {
  const OsDropdown({super.key, required this.value, required this.items, required this.onChanged, this.maxWidth = 320});

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = items.where((i) => i.value == value).firstOrNull;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        for (final item in items)
          MenuItemButton(
            onPressed: () => onChanged(item.value),
            leadingIcon: SizedBox(
              width: 18,
              child: item.value == value ? Icon(Icons.check_rounded, size: 18, color: scheme.primary) : null,
            ),
            child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth + 40), child: item.child),
          ),
      ],
      builder: (context, controller, _) => ConstrainedBox(
        constraints: BoxConstraints(minWidth: 120, maxWidth: maxWidth),
        child: IntrinsicWidth(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.onSurface,
              padding: const EdgeInsets.only(left: 14, right: 8),
              minimumSize: const Size(0, kControlHeight),
              alignment: Alignment.centerLeft,
            ),
            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
            child: Row(children: [
              Expanded(
                child: DefaultTextStyle.merge(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                  child: current?.child ?? const SizedBox.shrink(),
                ),
              ),
              const SizedBox(width: 6),
              AnimatedRotation(
                turns: controller.isOpen ? 0.5 : 0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more_rounded, size: 20, color: scheme.onSurfaceVariant),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One entry of an [OsMoreMenu].
class OsMenuAction {
  const OsMenuAction(this.icon, this.label, this.onSelected, {this.destructive = false});
  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool destructive;
}

/// The "⋮" button with the shared rounded menu.
class OsMoreMenu extends StatelessWidget {
  const OsMoreMenu({super.key, required this.actions, this.tooltip});

  final List<OsMenuAction> actions;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      alignmentOffset: const Offset(-120, 4),
      menuChildren: [
        for (final a in actions)
          MenuItemButton(
            onPressed: a.onSelected,
            leadingIcon: Icon(a.icon, size: 18, color: a.destructive ? scheme.error : scheme.onSurfaceVariant),
            child: Text(a.label, style: TextStyle(color: a.destructive ? scheme.error : null)),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: tooltip,
        style: IconButton.styleFrom(shape: kControlShape),
        icon: const Icon(Icons.more_vert_rounded),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Progress of a model / GPU pack download with pause, resume and cancel.
/// [total] may be 0 when unknown (a download paused in an earlier session).
class DownloadPanel extends StatelessWidget {
  const DownloadPanel({
    super.key,
    required this.received,
    required this.total,
    required this.paused,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    this.source,
    this.extracting = false,
  });

  final int received;
  final int total;
  final bool paused;
  final bool extracting;
  final String? source;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final amount = total > 0 ? '${formatBytes(received)} / ${formatBytes(total)}' : formatBytes(received);
    final label = extracting
        ? t('正在解压…', 'Extracting…')
        : paused
            ? '${t('已暂停', 'Paused')} · $amount'
            : '$amount${source != null ? ' · $source' : ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LinearProgressIndicator(
        value: extracting ? null : (total > 0 ? (received / total).clamp(0.0, 1.0) : 0),
        minHeight: 6,
        color: paused ? scheme.outline : null,
        borderRadius: BorderRadius.circular(3),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
        if (!extracting) ...[
          if (paused)
            FilledButton.tonalIcon(
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(t('继续', 'Resume')),
              onPressed: onResume,
            )
          else
            OutlinedButton.icon(
              icon: const Icon(Icons.pause_rounded, size: 18),
              label: Text(t('暂停', 'Pause')),
              onPressed: onPause,
            ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: const Icon(Icons.close_rounded, size: 18),
            label: Text(t('取消', 'Cancel')),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () async {
              if (received < 20 * 1024 * 1024 || await confirmDiscard(context)) onCancel();
            },
          ),
        ],
      ]),
    ]);
  }
}

/// Asks before deleting a partially downloaded file.
Future<bool> confirmDiscard(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('取消下载？', 'Cancel download?')),
        content: Text(t('已下载的部分会被删除，下次需要重新下载。只想稍后继续请点“暂停”。',
            'The downloaded part will be deleted. Use “Pause” to continue later instead.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('保留', 'Keep'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t('删除并取消', 'Delete'))),
        ],
      ),
    ) ??
    false;

/// Cards in two columns when the page is wide enough, otherwise one column
/// in [narrow] order (defaults to [left] then [right]).
class TwoColumn extends StatelessWidget {
  const TwoColumn({super.key, required this.left, required this.right, this.narrow, this.minWidth = 820});

  final List<Widget> left;
  final List<Widget> right;
  final List<Widget>? narrow;
  final double minWidth;

  static const _gap = 14.0;

  Widget _column(List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: _gap), children[i]],
        ],
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => c.maxWidth >= minWidth
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _column(left)),
                const SizedBox(width: _gap),
                Expanded(child: _column(right)),
              ])
            : _column(narrow ?? [...left, ...right]),
      );
}

/// Settings line in the style of a [SwitchListTile]: title and optional
/// subtitle on the left, a control on the right.
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.title, this.subtitle, required this.trailing});

  final String title;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyLarge),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          trailing,
        ],
      ),
    );
  }
}

Color stateColor(BuildContext context, DictationState s) => switch (s) {
      DictationState.listening => kListening,
      DictationState.processing => kProcessing,
      DictationState.error => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.primary,
    };

/// Large round record button with a halo that follows the input level.
class MicButton extends StatelessWidget {
  const MicButton({super.key, this.size = 128, this.onTap, this.onLongPressStart, this.onLongPressEnd});

  final double size;
  final VoidCallback? onTap;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;

  @override
  Widget build(BuildContext context) {
    final s = dictation.state;
    final color = stateColor(context, s);
    // Accent colours are light in dark mode; pick the matching foreground.
    final fg = s == DictationState.listening || s == DictationState.processing
        ? Colors.white
        : Theme.of(context).colorScheme.onPrimary;
    final icon = switch (s) {
      DictationState.listening => Icons.stop_rounded,
      DictationState.processing => Icons.more_horiz_rounded,
      DictationState.loading => Icons.hourglass_top_rounded,
      _ => Icons.mic_rounded,
    };
    return SizedBox(
      width: size * 1.7,
      height: size * 1.7,
      child: StreamBuilder<double>(
        stream: dictation.levels,
        builder: (context, snap) {
          final lv = s == DictationState.listening ? (snap.data ?? 0) : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: size * (1.0 + 0.6 * lv),
                height: size * (1.0 + 0.6 * lv),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: s == DictationState.listening ? 0.18 : 0.0),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: size * (1.0 + 0.3 * lv),
                height: size * (1.0 + 0.3 * lv),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: s == DictationState.listening ? 0.28 : 0.10),
                ),
              ),
              GestureDetector(
                onLongPressStart: onLongPressStart == null ? null : (_) => onLongPressStart!(),
                onLongPressEnd: onLongPressEnd == null ? null : (_) => onLongPressEnd!(),
                child: Material(
                  color: color,
                  shape: const CircleBorder(),
                  elevation: 6,
                  shadowColor: color.withValues(alpha: 0.5),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onTap,
                    child: SizedBox(
                      width: size * 0.78,
                      height: size * 0.78,
                      child: s == DictationState.processing || s == DictationState.loading
                          ? Padding(
                              padding: EdgeInsets.all(size * 0.24),
                              child: CircularProgressIndicator(strokeWidth: 3, color: fg),
                            )
                          : Icon(icon, color: fg, size: size * 0.38),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Compact bar-style level meter.
class LevelBars extends StatelessWidget {
  const LevelBars({super.key, this.bars = 24, this.height = 28, this.color});

  final int bars;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return _HistoryLevels(
      builder: (levels) => SizedBox(
        height: height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < bars; i++)
              Container(
                width: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                height: math.max(3, height * levels[i % levels.length]),
                decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
              ),
          ],
        ),
      ),
      count: bars,
    );
  }
}

/// Keeps the last [count] level samples for waveform-like rendering.
class _HistoryLevels extends StatefulWidget {
  const _HistoryLevels({required this.builder, required this.count});
  final Widget Function(List<double>) builder;
  final int count;

  @override
  State<_HistoryLevels> createState() => _HistoryLevelsState();
}

class _HistoryLevelsState extends State<_HistoryLevels> {
  late List<double> _levels = List.filled(widget.count, 0.0);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: dictation.levels,
      builder: (context, snap) {
        if (snap.hasData) {
          _levels = [..._levels.skip(1), snap.data!];
        }
        return widget.builder(_levels);
      },
    );
  }
}

/// Rounded section card with a title row.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, this.icon, this.trailing, required this.children});

  final String title;
  final IconData? icon;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
              ],
              Expanded(child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
              ?trailing,
            ]),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Small pill-shaped status chip.
class InfoChip extends StatelessWidget {
  const InfoChip({super.key, required this.icon, required this.label, this.color, this.onTap});

  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    return Material(
      color: (color ?? scheme.surfaceContainerHighest).withValues(alpha: color == null ? 0.6 : 0.12),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: c),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: c, fontWeight: FontWeight.w500)),
            ),
          ]),
        ),
      ),
    );
  }
}

String formatDuration(int ms) {
  final s = (ms / 1000).round();
  if (s < 60) return '${s}s';
  return '${s ~/ 60}m${(s % 60).toString().padLeft(2, '0')}s';
}

String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String get appVersionLabel => 'v$kAppVersion';
