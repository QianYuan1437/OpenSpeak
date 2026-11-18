import 'package:flutter/material.dart';

import '../app_state.dart';
import 'i18n.dart';
import 'widgets.dart';

/// GPU acceleration status and toggle (desktop with NVIDIA GPU).
class GpuCard extends StatelessWidget {
  const GpuCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!gpu.available) {
      return SectionCard(
        title: t('GPU 加速', 'GPU acceleration'),
        icon: Icons.bolt_rounded,
        children: [
          Text(t('未检测到 NVIDIA 显卡，将使用 CPU 识别（SenseVoice 在 CPU 上已足够快）。',
              'No NVIDIA GPU detected; using CPU (SenseVoice is already fast on CPU).'),
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      );
    }
    return SectionCard(
      title: t('GPU 加速', 'GPU acceleration'),
      icon: Icons.bolt_rounded,
      trailing: Switch(
        value: settings.useGpu && gpu.ready,
        onChanged: gpu.ready
            ? (v) async {
                await settings.update((s) => s.useGpu = v);
                await dictation.ensureModel(force: true);
              }
            : null,
      ),
      children: [
        Text('${gpu.gpuName} · ${t('驱动', 'driver')} ${gpu.driverVersion ?? '-'}',
            style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Text(
          gpu.ready
              ? t('CUDA 加速包已就绪，开启后大模型（FireRed / Qwen3 / FP32）识别更快。',
                  'CUDA pack ready. Turn on to speed up large models (FireRed / Qwen3 / FP32).')
              : t('需要先下载 CUDA 加速包。', 'Download the CUDA pack first.'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
