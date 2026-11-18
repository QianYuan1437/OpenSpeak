import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/model_catalog.dart';
import 'gpu_card.dart';
import 'home_shell.dart';
import 'i18n.dart';
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final installed = models.isInstalled(m);
    final selected = settings.modelId == m.id;
    final busy = models.progress[m.id];
    final err = models.errors[m.id];
    return Card(
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: scheme.primary, width: 1.6))
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                const SizedBox(height: 6),
                Text('${m.langs} · ${m.sizeMB} MB',
                    style: TextStyle(color: scheme.outline, fontSize: 12)),
              ]),
            ),
            const SizedBox(width: 12),
            _actions(context, installed, selected, busy != null),
          ]),
          if (busy != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
                value: busy.stage == 'extract' ? null : busy.fraction,
                borderRadius: BorderRadius.circular(4)),
            const SizedBox(height: 6),
            Text(
              busy.stage == 'extract'
                  ? t('正在解压…', 'Extracting…')
                  : '${formatBytes(busy.received)} / ${formatBytes(busy.total)}'
                      '${busy.source != null ? ' · ${busy.source}' : ''}',
              style: TextStyle(fontSize: 12, color: scheme.outline),
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

  Widget _actions(BuildContext context, bool installed, bool selected, bool busy) {
    if (busy) {
      return TextButton(onPressed: () => models.cancel(m), child: Text(t('取消', 'Cancel')));
    }
    if (!installed) {
      return FilledButton.tonalIcon(
        icon: const Icon(Icons.download_rounded, size: 18),
        label: Text(t('下载', 'Download')),
        onPressed: () async {
          await models.download(m);
          if (models.isInstalled(m) && !models.isInstalled(modelById(settings.modelId) ?? m)) {
            await settings.update((s) => s.modelId = m.id);
          }
          await dictation.ensureModel();
        },
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
      PopupMenuButton<String>(
        onSelected: (v) async {
          if (v == 'delete') {
            if (selected) await dictation.engine.dispose();
            await models.delete(m);
          }
        },
        itemBuilder: (_) => [PopupMenuItem(value: 'delete', child: Text(t('删除模型', 'Delete model')))],
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
