import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../app_state.dart';
import '../core/ollama.dart';
import '../core/text_refiner.dart';
import 'home_shell.dart';
import 'i18n.dart';
import 'theme.dart';
import 'widgets.dart';

/// Typo correction and clean-up of recognition results: offline rules, a
/// user dictionary and optional AI correction.
class RefinePage extends StatefulWidget {
  const RefinePage({super.key});

  @override
  State<RefinePage> createState() => _RefinePageState();
}

class _RefinePageState extends State<RefinePage> {
  static const _sample = '嗯，那个我我我想问一下，明天的会议在几点开始,我们因该提前准备一下github上的文档，然后然后在见。';

  final _input = TextEditingController();
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _prompt = TextEditingController();
  final _term = TextEditingController();
  final _from = TextEditingController();
  final _to = TextEditingController();

  RefineResult? _result;
  bool _running = false;

  /// Try-it "include AI" choice; follows the AI switch until changed here.
  bool? _tryLlmChoice;
  bool get _tryLlm => _tryLlmChoice ?? settings.llmEnabled;
  bool _showKey = false;

  /// Connection test / model list state.
  bool _testing = false;
  String? _testMsg;
  bool _testOk = false;
  List<String>? _models;

  @override
  void initState() {
    super.initState();
    _loadEndpoint();
    if (llmProviderById(settings.llmProvider).local) unawaited(ollama.refresh());
    _prompt.text = settings.llmPrompt.isEmpty ? kCorrectPrompt : settings.llmPrompt;
  }

  void _loadEndpoint() {
    final e = settings.endpointOf(settings.llmProvider);
    _url.text = e.baseUrl;
    _model.text = e.model;
    _key.text = e.apiKey;
    _models = null;
    _testMsg = null;
  }

  @override
  void dispose() {
    _recheck?.cancel();
    for (final c in [_input, _url, _model, _key, _prompt, _term, _from, _to]) {
      c.dispose();
    }
    super.dispose();
  }

  Timer? _recheck;

  void _saveEndpoint() {
    settings.update(
      (s) =>
          s.setEndpoint(s.llmProvider, baseUrl: _url.text.trim(), model: _model.text.trim(), apiKey: _key.text.trim()),
    );
    // A new Ollama address or model: re-check once typing pauses.
    if (llmProviderById(settings.llmProvider).local) {
      _recheck?.cancel();
      _recheck = Timer(const Duration(milliseconds: 800), ollama.refresh);
    }
  }

  Future<void> _run() async {
    final text = _input.text.trim();
    if (text.isEmpty || _running) return;
    setState(() => _running = true);
    final r = await dictation.refine(text, useLlm: _tryLlm);
    if (mounted) {
      setState(() {
        _result = r;
        _running = false;
      });
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testMsg = null;
    });
    final sw = Stopwatch()..start();
    try {
      // Generous timeout: the first request may have to load a local model.
      final out = await dictation.llm.refine(
        '我们明天在见，记得把文档发到GitHub上。',
        settings.llmConfig.copyWith(timeout: const Duration(seconds: 90)),
      );
      _testOk = true;
      _testMsg = t('连接正常（${sw.elapsedMilliseconds} ms）：$out', 'Works (${sw.elapsedMilliseconds} ms): $out');
    } on LlmException catch (e) {
      _testOk = false;
      _testMsg = e.message;
    }
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _fetchModels() async {
    setState(() {
      _testing = true;
      _testMsg = null;
    });
    try {
      _models = await dictation.llm.listModels(settings.llmConfig);
      _testOk = true;
      if (_models!.isEmpty) {
        _testMsg = t('没有可用模型。Ollama 可先运行：ollama pull qwen2.5:3b', 'No models. For Ollama run: ollama pull qwen2.5:3b');
      }
    } on LlmException catch (e) {
      _models = null;
      _testOk = false;
      _testMsg = e.message;
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, ollama]),
      builder: (context, _) {
        final tryIt = _tryItSection(context);
        final rules = _rulesSection(context);
        final dict = _dictionarySection(context);
        final ai = _aiSection(context);
        return PageFrame(
          title: t('优化', 'Refine'),
          maxWidth: 1180,
          children: [
            Text(
              t(
                '每次听写的结果都会先经过这里的处理再输出：先用离线规则纠正和清理，再（可选）交给 AI 改正同音错别字。AI 出错或超时会自动输出规则处理后的结果。',
                'Every dictation passes through here before it is typed: offline rules first, then (optionally) an AI pass that fixes homophone typos. If the AI fails or times out, the rule result is used.',
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            TwoColumn(left: [tryIt, rules], right: [ai, dict], narrow: [tryIt, rules, ai, dict]),
          ],
        );
      },
    );
  }

  // Try it ---------------------------------------------------------------------

  Widget _tryItSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = _result;
    return SectionCard(
      title: t('试一试', 'Try it'),
      icon: Icons.science_outlined,
      trailing: TextButton(onPressed: () => setState(() => _input.text = _sample), child: Text(t('填入示例', 'Sample'))),
      children: [
        TextField(
          controller: _input,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(
            hintText: t('粘贴或输入一段识别结果…', 'Paste or type a recognition result…'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Checkbox(value: _tryLlm, onChanged: (v) => setState(() => _tryLlmChoice = v ?? false)),
            Expanded(child: Text(t('包含 AI 优化', 'Include AI pass'))),
            FilledButton.icon(
              icon: _running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.auto_fix_high_rounded, size: 18),
              label: Text(t('优化', 'Refine')),
              onPressed: _running ? null : _run,
            ),
          ],
        ),
        if (r != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(kRadius - 2),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: SelectableText(r.text.isEmpty ? '—' : r.text, style: const TextStyle(height: 1.5))),
                IconButton(
                  tooltip: t('复制', 'Copy'),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  onPressed: () => Clipboard.setData(ClipboardData(text: r.text)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            r.usedLlm
                ? t('规则 + AI · ${r.llmMs} ms', 'Rules + AI · ${r.llmMs} ms')
                : r.llmError != null
                ? t('AI 未生效（${r.llmError}），显示的是规则处理结果', 'AI skipped (${r.llmError}); showing the rule result')
                : t('仅离线规则', 'Offline rules only'),
            style: TextStyle(fontSize: 12, color: r.llmError != null ? scheme.error : scheme.outline),
          ),
        ],
      ],
    );
  }

  // Rules ----------------------------------------------------------------------

  Widget _rulesSection(BuildContext context) {
    Widget sw(String title, String subtitle, bool value, void Function(bool v) set) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (v) => settings.update((_) => set(v)),
    );
    return SectionCard(
      title: t('基础规则（离线）', 'Offline rules'),
      icon: Icons.rule_rounded,
      children: [
        sw(
          t('去除语气词', 'Remove filler words'),
          t('嗯、呃，以及单独出现的"啊""那个"等', '"um", "uh", 嗯, 呃 and stand-alone 那个'),
          settings.removeFillers,
          (v) => settings.removeFillers = v,
        ),
        sw(
          t('去除口吃重复', 'Remove stutters'),
          t('"我我我想" → "我想"，"这个这个" → "这个"', '"I I I think" → "I think"'),
          settings.removeStutter,
          (v) => settings.removeStutter = v,
        ),
        sw(
          t('规范标点', 'Tidy punctuation'),
          t('中文里用全角标点，去掉重复和多余的标点', 'Full-width marks in Chinese, no doubled marks'),
          settings.normalizePunctuation,
          (v) => settings.normalizePunctuation = v,
        ),
        sw(
          t('常见术语大小写', 'Fix common term casing'),
          t('github → GitHub，chat gpt → ChatGPT 等', 'github → GitHub, chat gpt → ChatGPT, …'),
          settings.termCasing,
          (v) => settings.termCasing = v,
        ),
        sw(
          t('全大写英文改为正常大小写', 'Fix ALL-CAPS English'),
          t(
            '"HELLO WORLD" → "Hello world"（SenseVoice 常输出大写英文）',
            '"HELLO WORLD" → "Hello world" (SenseVoice prints capitals)',
          ),
          settings.fixAllCaps,
          (v) => settings.fixAllCaps = v,
        ),
        sw(
          t('中英文之间加空格', 'Space between Chinese and Latin'),
          t('"用Python写" → "用 Python 写"', '"用Python写" → "用 Python 写"'),
          settings.cjkSpacing,
          (v) => settings.cjkSpacing = v,
        ),
        sw(
          t('繁体转简体', 'Convert Traditional to Simplified Chinese'),
          t('部分模型（如 Qwen3）可能输出繁体字', 'Some models (e.g. Qwen3) may output Traditional characters'),
          settings.toSimplified,
          (v) => settings.toSimplified = v,
        ),
        sw(
          t('去掉句末句号', 'Drop trailing period'),
          t('适合聊天软件里的短句输入', 'Handy for short chat messages'),
          settings.stripTrailingPeriod,
          (v) => settings.stripTrailingPeriod = v,
        ),
      ],
    );
  }

  // Dictionary -----------------------------------------------------------------

  Widget _dictionarySection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    void addTerm() {
      final w = _term.text.trim();
      if (w.isEmpty || settings.vocabulary.contains(w)) return;
      settings.update((s) => s.vocabulary = [...s.vocabulary, w]);
      _term.clear();
    }

    void addRule() {
      final f = _from.text.trim(), to = _to.text.trim();
      if (f.isEmpty || f == to) return;
      settings.update((s) => s.replacements = [...s.replacements.where((r) => r.from != f), Replacement(f, to)]);
      _from.clear();
      _to.clear();
    }

    const dense = InputDecoration(isDense: true, border: OutlineInputBorder());
    return SectionCard(
      title: t('词典', 'Dictionary'),
      icon: Icons.menu_book_rounded,
      trailing: TextButton.icon(
        icon: const Icon(Icons.edit_note_rounded, size: 18),
        label: Text(t('批量编辑', 'Bulk edit')),
        onPressed: () => _bulkEdit(context),
      ),
      children: [
        Text(t('专有名词', 'Terms'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          t(
            '人名、产品名、行业术语等。英文词会自动统一大小写；开启 AI 时会作为参考，让读音相近的词改成它们。',
            'Names, products, jargon. Latin words get their casing fixed; the AI also uses them to fix similar-sounding words.',
          ),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (settings.vocabulary.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final w in settings.vocabulary)
                InputChip(
                  label: Text(w),
                  onDeleted: () => settings.update((s) => s.vocabulary = [...s.vocabulary]..remove(w)),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _term,
                decoration: dense.copyWith(hintText: t('例如：OpenSpeak、张三丰', 'e.g. OpenSpeak')),
                onSubmitted: (_) => addTerm(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(tooltip: t('添加', 'Add'), icon: const Icon(Icons.add_rounded), onPressed: addTerm),
          ],
        ),
        const Divider(height: 28),
        Text(t('替换规则', 'Replacements'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          t(
            '总是识别错的词，直接替换成正确写法（区分大小写，按顺序执行）。',
            'Words that keep coming out wrong, replaced as written (case-sensitive, in order).',
          ),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        for (final r in settings.replacements)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(child: Text(r.from, overflow: TextOverflow.ellipsis)),
                Icon(Icons.arrow_forward_rounded, size: 16, color: scheme.outline),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r.to.isEmpty ? t('（删除）', '(remove)') : r.to,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: t('删除', 'Delete'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => settings.update((s) => s.replacements = [...s.replacements]..remove(r)),
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _from,
                decoration: dense.copyWith(hintText: t('识别成', 'Heard as')),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.arrow_forward_rounded, size: 16, color: scheme.outline),
            ),
            Expanded(
              child: TextField(
                controller: _to,
                decoration: dense.copyWith(hintText: t('改成', 'Replace with')),
                onSubmitted: (_) => addRule(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(tooltip: t('添加', 'Add'), icon: const Icon(Icons.add_rounded), onPressed: addRule),
          ],
        ),
      ],
    );
  }

  /// One entry per line: "wrong = right" is a replacement, anything else a term.
  Future<void> _bulkEdit(BuildContext context) async {
    final c = TextEditingController(
      text: [...settings.vocabulary, for (final r in settings.replacements) '${r.from} = ${r.to}'].join('\n'),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('批量编辑词典', 'Edit dictionary')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t(
                  '每行一条。"错词 = 正词" 是替换规则，单独一个词是专有名词。',
                  'One per line. "wrong = right" is a replacement; a single word is a term.',
                ),
                style: TextStyle(fontSize: 13, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: c,
                autofocus: true,
                minLines: 10,
                maxLines: 16,
                style: const TextStyle(fontSize: 14, height: 1.5),
                decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'OpenSpeak\n在见 = 再见'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('保存', 'Save'))),
        ],
      ),
    );
    if (ok == true) {
      final (terms, rules) = parseDictionary(c.text);
      await settings.update((s) {
        s.vocabulary = terms;
        s.replacements = rules;
      });
    }
    c.dispose();
  }

  // AI -------------------------------------------------------------------------

  Widget _aiSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = llmProviderById(settings.llmProvider);
    final on = settings.llmEnabled;
    const dense = InputDecoration(isDense: true, border: OutlineInputBorder());
    return SectionCard(
      title: t('AI 纠错与润色', 'AI correction'),
      icon: Icons.auto_awesome_rounded,
      trailing: Switch(
        value: on,
        onChanged: (v) async {
          await settings.update((s) => s.llmEnabled = v);
          if (!v || !p.local) return;
          await ollama.refresh();
          if (ollama.status == OllamaStatus.missing && context.mounted) {
            await _installDialog(context);
          } else {
            dictation.warmUpLlm(force: true);
          }
        },
      ),
      children: [
        Text(
          t(
            '用大语言模型根据上下文改正同音字、错别字和标点。推荐在本机运行 Ollama，文字不出本机；也可使用云端服务。',
            'A language model fixes homophones, typos and punctuation from context. Ollama runs on this machine so text stays local; cloud services also work.',
          ),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        SettingRow(
          title: t('服务', 'Service'),
          trailing: OsDropdown<String>(
            value: p.id,
            maxWidth: 230,
            items: [for (final q in kLlmProviders) DropdownMenuItem(value: q.id, child: Text(L.zh ? q.zh : q.en))],
            onChanged: (v) async {
              if (v == null) return;
              await settings.update((s) => s.llmProvider = v);
              setState(_loadEndpoint);
              if (llmProviderById(v).local) unawaited(ollama.refresh());
            },
          ),
        ),
        if (p.local) _ollamaPanel(context),
        if (!p.local)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(kRadius - 4),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.cloud_outlined, size: 18, color: scheme.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t(
                      '开启后识别出的文字会发送到该服务处理（音频不会上传），请留意其隐私条款与计费。',
                      'Recognized text (not audio) is sent to this service; mind its privacy terms and pricing.',
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        TextField(
          controller: _url,
          decoration: dense.copyWith(labelText: t('接口地址', 'Base URL'), hintText: 'https://…/v1'),
          onChanged: (_) => _saveEndpoint(),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _model,
                decoration: dense.copyWith(labelText: t('模型', 'Model')),
                onChanged: (_) => _saveEndpoint(),
              ),
            ),
            const SizedBox(width: 8),
            _models != null && _models!.isNotEmpty
                ? PopupMenuButton<String>(
                    tooltip: t('选择模型', 'Pick a model'),
                    icon: const Icon(Icons.arrow_drop_down_circle_outlined),
                    itemBuilder: (_) => [for (final m in _models!) PopupMenuItem(value: m, child: Text(m))],
                    onSelected: (m) {
                      _model.text = m;
                      _saveEndpoint();
                    },
                  )
                : IconButton(
                    tooltip: t('获取模型列表', 'List models'),
                    icon: const Icon(Icons.list_rounded),
                    onPressed: _testing ? null : _fetchModels,
                  ),
          ],
        ),
        const SizedBox(height: 10),
        if (!p.local)
          TextField(
            controller: _key,
            obscureText: !_showKey,
            decoration: dense.copyWith(
              labelText: p.needsKey ? 'API Key' : t('API Key（可选）', 'API key (optional)'),
              suffixIcon: IconButton(
                icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                onPressed: () => setState(() => _showKey = !_showKey),
              ),
            ),
            onChanged: (_) => _saveEndpoint(),
          ),
        if (p.keyUrl != null && !p.local)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text(t('获取 API Key', 'Get an API key')),
              onPressed: () => openUrl(p.keyUrl!),
            ),
          ),
        const SizedBox(height: 8),
        Text(t('处理方式', 'Mode'), style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        SegmentedButton<LlmMode>(
          segments: [
            ButtonSegment(value: LlmMode.correct, label: Text(t('只纠错', 'Fix typos'))),
            ButtonSegment(value: LlmMode.polish, label: Text(t('纠错并润色', 'Fix & polish'))),
            ButtonSegment(value: LlmMode.custom, label: Text(t('自定义', 'Custom'))),
          ],
          selected: {settings.llmMode},
          onSelectionChanged: (v) => settings.update((s) => s.llmMode = v.first),
        ),
        const SizedBox(height: 6),
        Text(switch (settings.llmMode) {
          LlmMode.correct => t('只改错别字和标点，保留原话的用词和语气。', 'Only typos and punctuation; wording is kept.'),
          LlmMode.polish => t(
            '同时去掉口头禅、重复和改口，整理成通顺的书面语。',
            'Also drops fillers, repeats and false starts for clean prose.',
          ),
          LlmMode.custom => t('使用下面的提示词。', 'Uses the prompt below.'),
        }, style: TextStyle(fontSize: 12, color: scheme.outline)),
        if (settings.llmMode == LlmMode.custom) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _prompt,
            minLines: 4,
            maxLines: 10,
            style: const TextStyle(fontSize: 13),
            decoration: dense.copyWith(
              labelText: t('提示词（识别结果会放在 <text> 标签里发送）', 'Prompt (the text is sent inside <text> tags)'),
              suffixIcon: IconButton(
                tooltip: t('恢复默认', 'Reset'),
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                onPressed: () {
                  _prompt.text = kCorrectPrompt;
                  settings.update((s) => s.llmPrompt = '');
                },
              ),
            ),
            onChanged: (v) => settings.update((s) => s.llmPrompt = v == kCorrectPrompt ? '' : v),
          ),
        ],
        const SizedBox(height: 4),
        Row(
          children: [
            Text(t('超时', 'Timeout'), style: TextStyle(color: scheme.onSurfaceVariant)),
            Expanded(
              child: Slider(
                min: 3,
                max: 30,
                divisions: 27,
                value: settings.llmTimeoutSec.clamp(3, 30).toDouble(),
                label: '${settings.llmTimeoutSec} s',
                onChanged: (v) => settings.update((s) => s.llmTimeoutSec = v.round()),
              ),
            ),
            SizedBox(width: 40, child: Text('${settings.llmTimeoutSec} s')),
          ],
        ),
        Row(
          children: [
            OutlinedButton.icon(
              icon: _testing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.network_check_rounded, size: 18),
              label: Text(t('测试连接', 'Test')),
              onPressed: _testing ? null : _test,
            ),
            const SizedBox(width: 12),
            if (_testMsg != null)
              Expanded(
                child: Text(
                  _testMsg!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: _testOk ? scheme.primary : scheme.error),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // Ollama -----------------------------------------------------------------------

  String _pullStageText() => switch (ollama.pullStage) {
    'download' => '${t('从镜像下载', 'Downloading from')} ${ollama.pullSource ?? ''}',
    'verify' => t('校验文件…', 'Verifying…'),
    'import' => t('导入 Ollama…', 'Importing into Ollama…'),
    'registry' => t('Ollama 官方仓库', 'Ollama registry'),
    _ => '',
  };

  Widget _ollamaPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = ollama.status;
    final model = _model.text.trim().isEmpty ? kRecommendedOllamaModel : _model.text.trim();
    final pr = ollama.progress;

    Widget panel(IconData icon, Color color, String title, {String? body, List<Widget> children = const []}) =>
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            border: Border.all(color: color.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(kRadius - 4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: t('重新检测', 'Check again'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    onPressed: ollama.installing || ollama.starting ? null : ollama.refresh,
                  ),
                ],
              ),
              if (body != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(body, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
              ...children.map((w) => Padding(padding: const EdgeInsets.only(top: 10, right: 6), child: w)),
              if (ollama.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 6),
                  child: Text(ollama.error!, style: TextStyle(fontSize: 12, color: scheme.error)),
                ),
            ],
          ),
        );

    final warn = scheme.error;
    const ok = Colors.green;

    if (ollama.installing || ollama.pendingDir != null) {
      final extracting = pr?.stage == 'extract' || pr?.stage == 'install';
      return panel(
        Icons.downloading_rounded,
        scheme.primary,
        pr?.stage == 'install'
            ? t('正在安装 Ollama…', 'Installing Ollama…')
            : extracting
            ? t('正在校验并解压 Ollama…', 'Verifying and unpacking Ollama…')
            : ollama.installing
            ? t('正在下载 Ollama', 'Downloading Ollama')
            : t('Ollama 下载已暂停', 'Ollama download paused'),
        body: '${t('安装位置', 'Location')}：${ollama.pendingDir}',
        children: [
          DownloadPanel(
            received: pr?.received ?? ollama.partialBytes,
            total: pr?.total ?? ollamaPackageBytes,
            source: pr?.source,
            extracting: extracting,
            paused: !ollama.installing,
            onPause: ollama.pause,
            onResume: ollama.resume,
            onCancel: ollama.cancel,
          ),
        ],
      );
    }
    if (ollama.starting) {
      return panel(
        Icons.hourglass_top_rounded,
        scheme.primary,
        t('正在启动 Ollama…', 'Starting Ollama…'),
        children: [const LinearProgressIndicator()],
      );
    }
    switch (s) {
      case OllamaStatus.unknown:
        return panel(Icons.search_rounded, scheme.outline, t('正在检测 Ollama…', 'Looking for Ollama…'));
      case OllamaStatus.running:
        final ready = ollama.hasModel(model);
        return panel(
          ready ? Icons.check_circle_rounded : Icons.download_for_offline_outlined,
          ready ? ok : warn,
          ready
              ? t('Ollama 运行中 · 模型已就绪', 'Ollama is running · model ready')
              : t('Ollama 运行中 · 还没有下载模型 $model', 'Ollama is running · $model not downloaded'),
          body: [
            'v${ollama.version} · ${ollama.apiBase.authority}',
            if (ollama.managed) '${t('由 OpenSpeak 安装于', 'Installed by OpenSpeak in')} ${settings.ollamaDir}',
          ].join('\n'),
          children: [
            if (ollama.pulling != null) ...[
              LinearProgressIndicator(
                value: ollama.pullTotal > 0 ? ollama.pullCompleted / ollama.pullTotal : null,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      [
                        ollama.pulling,
                        _pullStageText(),
                        if (ollama.pullTotal > 0)
                          '${formatBytes(ollama.pullCompleted)} / ${formatBytes(ollama.pullTotal)}'
                        else if (ollama.pullStatus.isNotEmpty)
                          ollama.pullStatus,
                      ].whereType<String>().where((x) => x.isNotEmpty).join(' · '),
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  TextButton(onPressed: ollama.cancelPull, child: Text(t('停止', 'Stop'))),
                ],
              ),
            ] else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!ready)
                    FilledButton.icon(
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: Text(
                        model == kRecommendedOllamaModel
                            ? t(
                                '下载模型（约 ${formatBytes(kRecommendedModelBytes)}）',
                                'Download model (~${formatBytes(kRecommendedModelBytes)})',
                              )
                            : t('下载模型 $model', 'Download $model'),
                      ),
                      onPressed: () async {
                        if (await ollama.pull(model)) dictation.warmUpLlm(force: true);
                      },
                    ),
                  if (ollama.managed)
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: Text(t('卸载', 'Uninstall')),
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                      onPressed: () => _confirmUninstall(context),
                    ),
                ],
              ),
          ],
        );
      case OllamaStatus.stopped:
        return panel(
          Icons.pause_circle_outline_rounded,
          warn,
          t('已安装 Ollama，但没有运行', 'Ollama is installed but not running'),
          body: ollama.exe,
          children: [
            Row(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(t('启动 Ollama', 'Start Ollama')),
                  onPressed: () async {
                    if (await ollama.start()) dictation.warmUpLlm(force: true);
                  },
                ),
                const SizedBox(width: 8),
                if (ollama.managed)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: scheme.error),
                    onPressed: () => _confirmUninstall(context),
                    child: Text(t('卸载', 'Uninstall')),
                  ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    t('需要时自动启动（打开 OpenSpeak 或开始听写时）', 'Start automatically (at launch or when dictating)'),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Switch(
                  value: settings.ollamaAutoStart,
                  onChanged: (v) => settings.update((s) => s.ollamaAutoStart = v),
                ),
              ],
            ),
          ],
        );
      case OllamaStatus.missing:
        return panel(
          Icons.info_outline_rounded,
          warn,
          t('这台电脑还没有安装 Ollama', 'Ollama is not installed on this computer'),
          body: t(
            'Ollama 是在本机运行大模型的开源工具，AI 纠错需要它。可以让 OpenSpeak 自动安装官方便携版（可选择安装位置，无需管理员权限），也可以去官网下载安装包自行安装，装好后点右上角刷新。',
            'Ollama is the open-source tool that runs the model locally. OpenSpeak can install the official portable build for you (you pick the folder; no admin rights), or get the installer from ollama.com and press refresh afterwards.',
          ),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.install_desktop_rounded, size: 18),
                  label: Text(t('自动安装…', 'Install…')),
                  onPressed: () => _installDialog(context),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: Text(t('官网下载', 'ollama.com')),
                  onPressed: () => openUrl(kOllamaDownloadPage),
                ),
              ],
            ),
          ],
        );
      case OllamaStatus.remote:
        return panel(
          Icons.wifi_off_rounded,
          warn,
          t('无法连接 ${ollama.apiBase.authority}', 'Cannot reach ${ollama.apiBase.authority}'),
          body: t(
            '请确认那台电脑上的 Ollama 正在运行，并设置了环境变量 OLLAMA_HOST=0.0.0.0 以允许局域网访问。',
            'Make sure Ollama runs on that computer with OLLAMA_HOST=0.0.0.0 so the LAN can reach it.',
          ),
        );
      case OllamaStatus.unsupported:
        return panel(
          Icons.phone_android_rounded,
          scheme.outline,
          t('手机上不能运行 Ollama', 'Ollama cannot run on a phone'),
          body: t(
            '可以把下面的接口地址改成局域网内一台电脑的地址（如 http://192.168.1.10:11434/v1，那台电脑需设置 OLLAMA_HOST=0.0.0.0），或改用云端服务。',
            'Point the address below at a computer on your network (e.g. http://192.168.1.10:11434/v1, with OLLAMA_HOST=0.0.0.0 there), or use a cloud service.',
          ),
        );
    }
  }

  Future<void> _confirmUninstall(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('卸载 Ollama？', 'Uninstall Ollama?')),
        content: Text(
          t(
            '会停止 Ollama 并删除 ${settings.ollamaDir}，包括其中下载的模型。',
            'This stops Ollama and deletes ${settings.ollamaDir}, including downloaded models.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('卸载', 'Uninstall'))),
        ],
      ),
    );
    if (ok == true) await ollama.uninstall();
  }

  /// Confirms the folder (and the model download) before installing.
  Future<void> _installDialog(BuildContext context) async {
    var dir = ollama.pendingDir ?? _installTarget(OllamaManager.defaultDir);
    var withModel = true;
    int? free;
    var freeFor = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final scheme = Theme.of(ctx).colorScheme;
          if (freeFor != dir) {
            freeFor = dir;
            free = null;
            final asked = dir;
            OllamaManager.freeBytes(dir).then((f) {
              if (ctx.mounted && asked == dir) set(() => free = f);
            });
          }
          // The archive and the unpacked files exist side by side for a moment.
          final need = ollamaPackageBytes + ollamaUnpackedBytes + (withModel ? kRecommendedModelBytes : 0);
          final short = free != null && free! < need;
          return AlertDialog(
            title: Text(t('安装 Ollama', 'Install Ollama')),
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t(
                      '将从 Ollama 官方渠道（ollama.com / GitHub）下载最新的便携版（约 ${formatBytes(ollamaPackageBytes)}）并解压到下面的文件夹。不需要管理员权限，不修改系统设置；模型也保存在这个文件夹里，卸载时一并删除。',
                      'OpenSpeak downloads the latest official portable build (about ${formatBytes(ollamaPackageBytes)}) from ollama.com / GitHub and unpacks it into the folder below. No admin rights or system changes; models are kept in the same folder and removed on uninstall.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(t('安装位置', 'Install location'), style: Theme.of(ctx).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SelectableText(dir, style: const TextStyle(fontSize: 13)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () async {
                          final picked = await getDirectoryPath(
                            initialDirectory: _existingParent(dir),
                            confirmButtonText: t('选择', 'Select'),
                          );
                          if (picked == null) return;
                          set(() => dir = _installTarget(picked));
                        },
                        child: Text(t('更改…', 'Change…')),
                      ),
                    ],
                  ),
                  if (dir != _installTarget(OllamaManager.defaultDir))
                    TextButton(
                      onPressed: () => set(() => dir = _installTarget(OllamaManager.defaultDir)),
                      child: Text(t('恢复默认位置', 'Use default location')),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    free == null
                        ? t('需要约 ${formatBytes(need)} 空间', 'Needs about ${formatBytes(need)}')
                        : t(
                            '需要约 ${formatBytes(need)}，该磁盘可用 ${formatBytes(free!)}',
                            'Needs about ${formatBytes(need)}; ${formatBytes(free!)} free on that drive',
                          ),
                    style: TextStyle(fontSize: 12, color: short ? scheme.error : scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 6),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: withModel,
                    onChanged: (v) => set(() => withModel = v ?? true),
                    title: Text(
                      t(
                        '安装后下载推荐模型 $kRecommendedOllamaModel（约 ${formatBytes(kRecommendedModelBytes)}）',
                        'Then download the recommended model $kRecommendedOllamaModel (~${formatBytes(kRecommendedModelBytes)})',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('取消', 'Cancel'))),
              TextButton(onPressed: () => openUrl(kOllamaDownloadPage), child: Text(t('改为去官网下载', 'Open ollama.com'))),
              FilledButton(onPressed: short ? null : () => Navigator.pop(ctx, true), child: Text(t('开始安装', 'Install'))),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    if (withModel) {
      _model.text = kRecommendedOllamaModel;
      _saveEndpoint();
    }
    await settings.update((s) => s.llmEnabled = true);
    unawaited(
      ollama.install(dir, model: withModel ? kRecommendedOllamaModel : null).then((_) {
        if (ollama.status == OllamaStatus.running) dictation.warmUpLlm(force: true);
      }),
    );
  }

  /// A picked folder that is empty (or an earlier OpenSpeak install of
  /// Ollama) is used as is; otherwise Ollama goes into an "Ollama" subfolder,
  /// so picking e.g. D:\ or Downloads never mixes it with other files.
  static String _installTarget(String picked) =>
      OllamaManager.usableInstallDir(picked) ? picked : path.join(picked, 'Ollama');

  static String _existingParent(String dir) {
    var d = Directory(dir);
    while (!d.existsSync() && d.parent.path != d.path) {
      d = d.parent;
    }
    return d.path;
  }
}
