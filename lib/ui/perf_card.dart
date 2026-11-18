import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import 'i18n.dart';
import 'theme.dart';
import 'widgets.dart';

/// Compact row of stat tiles: OpenSpeak's CPU and memory, GPU memory/load
/// (NVIDIA) and how fast the last utterance was recognized.
class PerfCard extends StatelessWidget {
  const PerfCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([perf, dictation]),
      builder: (context, _) {
        final tiles = [
          _cpuTile(),
          _StatTile(
            label: t('内存', 'Memory'),
            value: perf.rssBytes == null ? '—' : formatBytes(perf.rssBytes!),
            detail: t('本进程（含已加载模型）', 'This process, incl. the model'),
          ),
          if (gpu.available) _gpuTile(),
          _speedTile(),
        ];
        return SectionCard(
          title: t('性能', 'Performance'),
          icon: Icons.speed_rounded,
          children: [
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth >= 640 ? tiles.length : 2;
              const gap = 10.0;
              final w = (c.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(spacing: gap, runSpacing: gap, children: [
                for (final tile in tiles) SizedBox(width: w, child: tile),
              ]);
            }),
          ],
        );
      },
    );
  }

  Widget _cpuTile() {
    final cpu = perf.cpuPercent;
    return _StatTile(
      label: 'CPU',
      value: cpu == null ? '—' : '${cpu.toStringAsFixed(cpu < 10 ? 1 : 0)}%',
      detail: t('本进程 · ${Platform.numberOfProcessors} 线程', 'This process · ${Platform.numberOfProcessors} threads'),
      meter: cpu == null ? null : cpu / 100,
    );
  }

  Widget _gpuTile() {
    final used = perf.gpuMemUsedMB;
    final total = perf.gpuMemTotalMB ?? gpu.memoryTotalMB;
    String gb(int mb) => (mb / 1024).toStringAsFixed(1);
    return _StatTile(
      label: t('GPU 显存（全卡）', 'GPU memory (whole card)'),
      value: used == null || total == null ? '—' : '${gb(used)} / ${gb(total)} GB',
      detail: [
        if (perf.gpuUtil != null) t('负载 ${perf.gpuUtil}%', 'Load ${perf.gpuUtil}%'),
        dictation.loadedProvider == 'cuda' ? t('识别在 GPU', 'Recognizing on GPU') : t('识别在 CPU', 'Recognizing on CPU'),
      ].join(' · '),
      meter: used == null || total == null || total == 0 ? null : used / total,
    );
  }

  Widget _speedTile() {
    final audio = dictation.lastAudioMs;
    final decode = dictation.lastDecodeMs;
    if (audio == null || decode == null) {
      return _StatTile(label: t('识别耗时', 'Recognition'), value: '—', detail: t('说一句话后显示', 'Shown after you dictate'));
    }
    final speed = decode > 0 ? audio / decode : null;
    return _StatTile(
      label: t('识别耗时', 'Recognition'),
      value: decode < 1000 ? '$decode ms' : '${(decode / 1000).toStringAsFixed(1)} s',
      detail: [
        t('${(audio / 1000).toStringAsFixed(1)} 秒语音', '${(audio / 1000).toStringAsFixed(1)} s audio'),
        if (speed != null) t('${speed.toStringAsFixed(speed < 10 ? 1 : 0)}× 实时', '${speed.toStringAsFixed(speed < 10 ? 1 : 0)}× real time'),
      ].join(' · '),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, required this.detail, this.meter});

  final String label;
  final String value;
  final String detail;

  /// 0..1 share of a limit; drawn as a thin bar when set.
  final double? meter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m = meter?.clamp(0.0, 1.0);
    // Fill carries severity; the track is a lighter step of the same hue.
    final fill = m == null
        ? scheme.primary
        : m >= 0.9
            ? scheme.error
            : m >= 0.7
                ? kProcessing
                : scheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: theme.inputDecorationTheme.fillColor,
        borderRadius: BorderRadius.circular(kRadius - 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SizedBox(
          height: 4,
          child: m == null
              ? null
              : ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: m,
                    color: fill,
                    backgroundColor: fill.withValues(alpha: 0.16),
                  ),
                ),
        ),
        const SizedBox(height: 6),
        Text(detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: scheme.outline)),
      ]),
    );
  }
}
