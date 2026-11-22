import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/dictation.dart';
import '../core/model_catalog.dart';
import '../core/ollama.dart';
import '../core/settings.dart';
import '../core/text_refiner.dart';
import 'home_shell.dart';
import 'i18n.dart';
import 'theme.dart';
import 'perf_card.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onOpenModels, required this.onOpenSettings, required this.onOpenRefine});

  final VoidCallback onOpenModels;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenRefine;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.text = dictation.transcript;
    dictation.addListener(_sync);
    if (Platform.isAndroid) _refreshAndroid();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    dictation.removeListener(_sync);
    _text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) _refreshAndroid();
  }

  bool _overlayOk = false;
  bool _a11yOk = false;

  Future<void> _refreshAndroid() async {
    final o = await dictation.bridge.canDrawOverlays();
    final a = await dictation.bridge.accessibilityEnabled();
    if (!mounted) return;
    setState(() {
      _overlayOk = o;
      _a11yOk = a;
    });
    // Restart the bubble after a process restart.
    if (o && settings.bubbleEnabled) await dictation.bridge.startBubble();
  }

  void _sync() {
    if (_text.text != dictation.transcript) {
      _text.value = TextEditingValue(
        text: dictation.transcript,
        selection: TextSelection.collapsed(offset: dictation.transcript.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([dictation, models, settings, ollama]),
      builder: (context, _) {
        final spec = dictation.currentModel;
        final installed = spec != null && models.isInstalled(spec);
        return PageFrame(
          title: t('听写', 'Dictate'),
          children: [
            _statusChips(context, spec),
            if (!installed) _noModelCard(context, spec),
            _recorderCard(context, installed),
            if (Platform.isAndroid) _bubbleCard(context),
            _transcriptCard(context),
            const PerfCard(),
          ],
        );
      },
    );
  }

  Widget _statusChips(BuildContext context, ModelSpec? spec) {
    final scheme = Theme.of(context).colorScheme;
    final dev = dictation.activeDevice;
    final brand = dictation.activeBrand;
    final gpuOn = dictation.loadedProvider == 'cuda';
    return Wrap(spacing: 8, runSpacing: 8, children: [
      InfoChip(
        icon: Icons.memory_rounded,
        label: '${spec?.name ?? '-'} · ${gpuOn ? 'GPU' : 'CPU'}',
        color: gpuOn ? Colors.green : null,
        onTap: widget.onOpenModels,
      ),
      InfoChip(
        icon: brand != null ? Icons.settings_input_antenna_rounded : Icons.mic_none_rounded,
        label: brand != null
            ? '${brand.name} · ${dev!.label}'
            : (dev?.label ?? t('系统默认麦克风', 'System default mic')),
        color: brand != null ? scheme.primary : null,
        onTap: widget.onOpenSettings,
      ),
      if (Platform.isWindows || Platform.isLinux)
        InfoChip(
          icon: Icons.keyboard_rounded,
          label:
              '${settings.trigger == TriggerMode.hold ? t('按住', 'Hold') : t('按下切换', 'Toggle')} ${settings.hotkey.label}',
          onTap: widget.onOpenSettings,
        ),
      if (settings.llmEnabled) _aiChip(context),
    ]);
  }

  /// AI correction status; red when the local Ollama is not usable.
  Widget _aiChip(BuildContext context) {
    final local = llmProviderById(settings.llmProvider).local;
    final model = settings.endpointOf(settings.llmProvider).model;
    final s = ollama.status;
    final bad = local && s != OllamaStatus.running && s != OllamaStatus.unknown;
    final missingModel = local && s == OllamaStatus.running && !ollama.hasModel(model);
    return InfoChip(
      icon: Icons.auto_fix_high_rounded,
      label: bad
          ? switch (s) {
              OllamaStatus.missing => t('AI 优化不可用：未安装 Ollama', 'AI off: Ollama not installed'),
              OllamaStatus.stopped => t('AI 优化不可用：Ollama 未运行', 'AI off: Ollama not running'),
              _ => t('AI 优化不可用：无法连接 Ollama', 'AI off: cannot reach Ollama'),
            }
          : missingModel
              ? t('AI 优化不可用：未下载 $model', 'AI off: $model not downloaded')
              : 'AI · $model',
      color: bad || missingModel ? Theme.of(context).colorScheme.error : Colors.green,
      onTap: widget.onOpenRefine,
    );
  }

  Widget _noModelCard(BuildContext context, ModelSpec? spec) {
    final m = spec ?? kModels.first;
    final busy = models.progress[m.id];
    final partial = busy == null ? models.partialBytes(m) : 0;
    Future<void> download() async {
      await models.download(m);
      if (models.isInstalled(m)) {
        await settings.update((s) => s.modelId = m.id);
        await dictation.ensureModel();
      }
    }

    return Card(
      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          const Icon(Icons.download_rounded, size: 32),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('首次使用需要下载识别模型', 'Download a speech model to get started'),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 4),
              Text('${m.name} · ${m.sizeMB} MB · ${m.langs}',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              if (busy != null || partial > 0) ...[
                const SizedBox(height: 10),
                DownloadPanel(
                  received: busy?.received ?? partial,
                  total: busy?.total ?? m.sizeMB * 1024 * 1024,
                  source: busy?.source,
                  extracting: busy?.stage == 'extract',
                  paused: busy == null,
                  onPause: () => models.pause(m),
                  onResume: download,
                  onCancel: () => models.cancel(m),
                ),
              ],
              if (models.errors[m.id] != null) ...[
                const SizedBox(height: 6),
                Text(models.errors[m.id]!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              ],
            ]),
          ),
          if (busy == null && partial == 0) ...[
            const SizedBox(width: 12),
            FilledButton(onPressed: download, child: Text(t('一键下载', 'Download'))),
          ],
        ]),
      ),
    );
  }

  Widget _recorderCard(BuildContext context, bool installed) {
    final s = dictation.state;
    final scheme = Theme.of(context).colorScheme;
    final hint = switch (s) {
      DictationState.listening => t('正在聆听…再次点击结束', 'Listening… tap again to finish'),
      DictationState.processing => t('识别中…', 'Recognizing…'),
      DictationState.loading => t('正在加载模型…', 'Loading model…'),
      _ when Platform.isAndroid => t('点击开始说话，或长按说话松开结束', 'Tap to talk, or hold and release'),
      _ => settings.trigger == TriggerMode.hold
          ? t('在任意应用中按住 ${settings.hotkey.label} 说话，松开即输入', 'Hold ${settings.hotkey.label} in any app, release to type')
          : t('在任意应用中按 ${settings.hotkey.label} 开始/结束', 'Press ${settings.hotkey.label} in any app to start/stop'),
    };
    final live = dictation.liveText;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
        child: Column(children: [
          MicButton(
            size: 120,
            onTap: installed ? () => dictation.toggle() : widget.onOpenModels,
            onLongPressStart: installed && Platform.isAndroid ? () => dictation.start() : null,
            onLongPressEnd: installed && Platform.isAndroid ? () => dictation.stop() : null,
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: s == DictationState.listening
                ? LevelBars(key: const ValueKey('bars'), bars: 32, height: 26, color: kListening)
                : const SizedBox(key: ValueKey('nobars'), height: 26),
          ),
          const SizedBox(height: 8),
          Text(hint, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          if (live.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(live, style: const TextStyle(fontSize: 16, height: 1.5)),
            ),
          ],
          if (dictation.state == DictationState.error && dictation.error != null) ...[
            const SizedBox(height: 10),
            Text(dictation.error!, style: TextStyle(color: scheme.error, fontSize: 12)),
          ],
        ]),
      ),
    );
  }

  Widget _bubbleCard(BuildContext context) {
    return SectionCard(
      title: t('悬浮按钮', 'Floating button'),
      icon: Icons.bubble_chart_rounded,
      trailing: Switch(
        value: settings.bubbleEnabled && _overlayOk,
        onChanged: (v) async {
          if (v && !_overlayOk) {
            await dictation.bridge.requestOverlayPermission();
            await settings.update((s) => s.bubbleEnabled = true);
            return;
          }
          await settings.update((s) => s.bubbleEnabled = v);
          if (v) {
            await dictation.bridge.startBubble();
          } else {
            await dictation.bridge.stopBubble();
          }
        },
      ),
      children: [
        Text(
          t('开启后，在任何应用上方都会显示一个麦克风悬浮球：点击开始/结束，长按说话松开结束。识别结果会自动复制到剪贴板。',
              'Shows a mic bubble over every app: tap to start/stop, or hold to talk. Results are copied to the clipboard.'),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(_a11yOk ? Icons.check_circle_rounded : Icons.keyboard_alt_outlined,
              color: _a11yOk ? Colors.green : null),
          title: Text(t('自动上屏（可选）', 'Auto insert (optional)')),
          subtitle: Text(_a11yOk
              ? t('已开启：识别结果会直接写入当前输入框', 'On: results are inserted into the focused field')
              : t('开启 OpenSpeak 无障碍服务后，结果可直接写入当前输入框', 'Enable the OpenSpeak accessibility service to insert text directly')),
          trailing: _a11yOk
              ? null
              : OutlinedButton(
                  onPressed: dictation.bridge.openAccessibilitySettings,
                  child: Text(t('去开启', 'Enable'))),
        ),
      ],
    );
  }

  Widget _transcriptCard(BuildContext context) {
    return SectionCard(
      title: t('文本', 'Transcript'),
      icon: Icons.notes_rounded,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: t('复制', 'Copy'),
          icon: const Icon(Icons.copy_rounded, size: 20),
          onPressed: _text.text.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: _text.text));
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(t('已复制', 'Copied'))));
                },
        ),
        IconButton(
          tooltip: t('清空', 'Clear'),
          icon: const Icon(Icons.delete_sweep_outlined, size: 20),
          onPressed: _text.text.isEmpty ? null : dictation.clearTranscript,
        ),
      ]),
      children: [
        TextField(
          controller: _text,
          minLines: 5,
          maxLines: 14,
          onChanged: (v) {
            dictation.setTranscript(v);
            // Refresh the copy/clear buttons after manual edits.
            setState(() {});
          },
          style: const TextStyle(fontSize: 15, height: 1.6),
          decoration: InputDecoration(
            hintText: t('在这里点击麦克风说话，文字会出现在这里；在其他应用中用快捷键说话，文字会直接输入到那个应用。',
                'Dictate here with the mic button, or use the hotkey in any other app to type there directly.'),
            hintMaxLines: 3,
          ),
        ),
      ],
    );
  }
}
