import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/model_catalog.dart';
import 'gpu_card.dart';
import 'home_shell.dart';
import 'i18n.dart';
import 'theme.dart';
import 'widgets.dart';

class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([models, settings, dictation, gpu]),
      builder: (context, _) => PageFrame(
        title: t('模型', 'Models'),
        children: [
          Text(
            t('所有识别都在本机离线完成，不会上传任何音频。模型从 HuggingFace（自动回退到镜像和 GitHub）下载。',
                'Recognition runs fully offline on this device; no audio leaves it. Models download from HuggingFace (falling back to a mirror and GitHub).'),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          if (gpu.supported) const GpuCard(),
          for (final m in platformModels) _ModelTile(m),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile(this.m);
  final ModelSpec m;

  Future<void> _download() async {
    await models.download(m);
    if (models.isInstalled(m) && !models.isInstalled(modelById(settings.modelId) ?? m)) {
      await settings.update((s) => s.modelId = m.id);
    }
    await dictation.ensureModel();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final installed = models.isInstalled(m);
    final selected = settings.modelId == m.id;
    final busy = models.progress[m.id];
    final partial = busy == null ? models.partialBytes(m) : 0;
    final err = models.errors[m.id];
    final meta = TextStyle(color: scheme.outline, fontSize: 12);
    return Card(
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kCardRadius),
              side: BorderSide(color: scheme.primary, width: 1.6))
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(m.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  if (selected) _tag(context, t('使用中', 'In use'), scheme.primary),
                  if (m.gpuRecommended) _tag(context, t('建议 GPU', 'GPU'), Colors.green),
                  if (!m.punctuation) _tag(context, t('无标点', 'No punct.'), scheme.outline),
                ]),
                const SizedBox(height: 6),
                Text(L.zh ? m.descZh : m.descEn, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
                const SizedBox(height: 8),
                Wrap(spacing: 14, runSpacing: 4, children: [
                  _meta(Icons.translate_rounded, m.langs, meta),
                  _meta(Icons.save_alt_rounded, '${m.sizeMB} MB', meta),
                  if (gpu.available) _vram(context, meta),
                ]),
              ]),
            ),
            const SizedBox(width: 12),
            if (busy == null && partial == 0) _actions(context, installed, selected),
          ]),
          if (busy != null || partial > 0) ...[
            const SizedBox(height: 14),
            DownloadPanel(
              received: busy?.received ?? partial,
              total: busy?.total ?? m.sizeMB * 1024 * 1024,
              source: busy?.source,
              extracting: busy?.stage == 'extract',
              paused: busy == null,
              onPause: () => models.pause(m),
              onResume: _download,
              onCancel: () => models.cancel(m),
            ),
          ],
          if (err != null) ...[
            const SizedBox(height: 8),
            Text(err, maxLines: 4, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.error, fontSize: 12)),
          ],
        ]),
      ),
    );
  }

  Widget _meta(IconData icon, String text, TextStyle style) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: style.color),
        const SizedBox(width: 4),
        Text(text, style: style),
      ]);

  /// Estimated GPU memory; models outside the GPU set run on the CPU.
  Widget _vram(BuildContext context, TextStyle style) {
    if (!m.gpuRecommended || m.vramMB == 0) {
      return _meta(Icons.memory_rounded, t('CPU 运行 · 不占显存', 'Runs on CPU · no VRAM'), style);
    }
    final total = gpu.memoryTotalMB;
    final gb = (m.vramMB / 1024).toStringAsFixed(1);
    final text = total != null
        ? t('显存约 $gb GB / ${(total / 1024).toStringAsFixed(0)} GB', 'VRAM ≈ $gb GB / ${(total / 1024).toStringAsFixed(0)} GB')
        : t('显存约 $gb GB', 'VRAM ≈ $gb GB');
    final tight = total != null && m.vramMB > total * 0.8;
    return Tooltip(
      message: t('使用 GPU 加速时的预估显存占用（实测峰值，含 CUDA 运行时）',
          'Estimated GPU memory with CUDA (measured peak incl. the CUDA runtime)'),
      child: _meta(Icons.memory_rounded, text, tight ? style.copyWith(color: Theme.of(context).colorScheme.error) : style),
    );
  }

  Widget _actions(BuildContext context, bool installed, bool selected) {
    if (!installed) {
      return FilledButton.tonalIcon(
        icon: const Icon(Icons.download_rounded, size: 18),
        label: Text(t('下载', 'Download')),
        onPressed: _download,
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (!selected)
        FilledButton(
          onPressed: () async {
            await settings.update((s) => s.modelId = m.id);
            await dictation.ensureModel(force: true);
          },
          child: Text(t('使用', 'Use')),
        ),
      OsMoreMenu(
        tooltip: t('更多', 'More'),
        actions: [
          OsMenuAction(Icons.delete_outline_rounded, t('删除模型', 'Delete model'), () async {
            if (selected) await dictation.engine.dispose();
            await models.delete(m);
          }, destructive: true),
        ],
      ),
    ]);
  }

  Widget _tag(BuildContext context, String label, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
      );
}
