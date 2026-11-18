import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/dictation.dart';
import 'theme.dart';

/// Compact rounded dropdown that sizes itself to its widest item (up to
/// [maxWidth]); long items are ellipsized. Meant to sit at the end of a
/// [SettingRow] rather than stretch across the card.
class OsDropdown<T> extends StatelessWidget {
  const OsDropdown({super.key, required this.value, required this.items, required this.onChanged, this.maxWidth = 320});

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: 120, maxWidth: maxWidth),
      child: IntrinsicWidth(
        child: Container(
          height: 42,
          padding: const EdgeInsets.only(left: 14, right: 8),
          decoration: BoxDecoration(
            color: theme.inputDecorationTheme.fillColor ?? theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(kRadius),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isExpanded: true,
              borderRadius: BorderRadius.circular(kRadius),
              dropdownColor: theme.cardTheme.color,
              focusColor: Colors.transparent,
              icon: Icon(Icons.expand_more_rounded, color: theme.colorScheme.onSurfaceVariant),
              menuMaxHeight: 420,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    );
  }
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
