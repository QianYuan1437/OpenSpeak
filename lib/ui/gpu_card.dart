import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/gpu.dart';
import 'i18n.dart';
import 'widgets.dart';

/// GPU acceleration: CUDA pack download and on/off switch (desktop + NVIDIA).
class GpuCard extends StatelessWidget {
  const GpuCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    if (!gpu.available) {
      return SectionCard(
        title: t('GPU 加速', 'GPU acceleration'),
        icon: Icons.bolt_rounded,
        children: [
          Text(t('未检测到 NVIDIA 显卡，将使用 CPU 识别（SenseVoice 在 CPU 上已足够快）。',
              'No NVIDIA GPU detected; using CPU (SenseVoice is already fast on CPU).'), style: muted),
        ],
      );
    }
    final pr = gpu.progress;
    final on = settings.useGpu && gpu.ready;
    final running = dictation.loadedProvider == 'cuda';
    final needsRestart = on && GpuManager.cpuLibLoaded;
    final model = dictation.currentModel;
    return SectionCard(
      title: t('GPU 加速', 'GPU acceleration'),
      icon: Icons.bolt_rounded,
      trailing: Switch(
        value: on,
        onChanged: gpu.ready
            ? (v) async {
                await settings.update((s) => s.useGpu = v);
                await dictation.ensureModel(force: true);
              }
            : null,
      ),
      children: [
        Text('${gpu.gpuName} · ${t('驱动', 'driver')} ${gpu.driverVersion ?? '-'}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        if (gpu.ready)
          Text(
            on && running
                ? t('正在使用 GPU（CUDA）识别。', 'Recognizing on the GPU (CUDA).')
                : needsRestart
                    ? t('已开启，重启 OpenSpeak 后生效。', 'Enabled — restart OpenSpeak to apply.')
                    : on && model != null && !model.gpuRecommended
                        ? t('当前模型在 CPU 上已经很快，仍用 CPU；切换到 FireRed / Qwen3 / SenseVoice FP32 时自动使用 GPU。',
                            'The current model is already fast on the CPU; GPU is used for FireRed / Qwen3 / SenseVoice FP32.')
                        : t('CUDA 加速包已安装。开启后 FireRed / Qwen3 / FP32 等大模型识别更快。',
                            'CUDA pack installed. Turn on to speed up large models (FireRed / Qwen3 / FP32).'),
            style: muted,
          )
        else
          Text(
            t('需要下载 CUDA 加速包（约 1.5 GB，含 cuDNN / cuBLAS，大部分从国内 PyPI 镜像下载），无需安装 CUDA 工具包。',
                'Needs the CUDA pack (~1.5 GB incl. cuDNN / cuBLAS, mostly from PyPI mirrors); no CUDA toolkit install required.'),
            style: muted,
          ),
        if (pr != null) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(value: pr.stage == 'extract' ? null : pr.fraction, borderRadius: BorderRadius.circular(4)),
          const SizedBox(height: 6),
          Text(
            pr.stage == 'extract'
                ? '${t('正在解压', 'Extracting')} ${pr.source ?? ''}'
                : '${formatBytes(pr.received)} / ${formatBytes(pr.total)} · ${pr.source ?? ''}',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        ],
        if (gpu.error != null) ...[
          const SizedBox(height: 8),
          Text(gpu.error!, maxLines: 4, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.error, fontSize: 12)),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (pr != null)
            OutlinedButton(onPressed: gpu.cancel, child: Text(t('取消', 'Cancel')))
          else if (!gpu.ready)
            FilledButton.tonalIcon(
              icon: const Icon(Icons.download_rounded, size: 18),
              label: Text(t('下载 CUDA 加速包', 'Download CUDA pack')),
              onPressed: () => gpu.install(),
            )
          else ...[
            if (needsRestart && !running)
              FilledButton.icon(
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: Text(t('立即重启', 'Restart now')),
                onPressed: _restart,
              ),
            TextButton(
              onPressed: () async {
                await settings.update((s) => s.useGpu = false);
                await gpu.uninstall();
              },
              child: Text(t('删除加速包', 'Remove pack')),
            ),
          ],
        ]),
      ],
    );
  }

  static Future<void> _restart() async {
    await Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
    exit(0);
  }
}
