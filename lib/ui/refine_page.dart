import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
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
    for (final c in [_input, _url, _model, _key, _prompt, _term, _from, _to]) {
      c.dispose();
    }
    super.dispose();
  }

  void _saveEndpoint() => settings.update((s) =>
      s.setEndpoint(s.llmProvider, baseUrl: _url.text.trim(), model: _model.text.trim(), apiKey: _key.text.trim()));

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
          '我们明天在见，记得把文档发到GitHub上。', settings.llmConfig.copyWith(timeout: const Duration(seconds: 90)));
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
      listenable: settings,
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
              t('每次听写的结果都会先经过这里的处理再输出：先用离线规则纠正和清理，再（可选）交给 AI 改正同音错别字。AI 出错或超时会自动输出规则处理后的结果。',
                  'Every dictation passes through here before it is typed: offline rules first, then (optionally) an AI pass that fixes homophone typos. If the AI fails or times out, the rule result is used.'),
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            TwoColumn(
              left: [tryIt, rules],
              right: [ai, dict],
              narrow: [tryIt, rules, ai, dict],
            ),
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
      trailing: TextButton(
        onPressed: () => setState(() => _input.text = _sample),
        child: Text(t('填入示例', 'Sample')),
      ),
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
        Row(children: [
          Checkbox(
            value: _tryLlm,
            onChanged: (v) => setState(() => _tryLlmChoice = v ?? false),
          ),
          Expanded(child: Text(t('包含 AI 优化', 'Include AI pass'))),
          FilledButton.icon(
            icon: _running
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.auto_fix_high_rounded, size: 18),
            label: Text(t('优化', 'Refine')),
            onPressed: _running ? null : _run,
          ),
        ]),
        if (r != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(kRadius - 2),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: SelectableText(r.text.isEmpty ? '—' : r.text, style: const TextStyle(height: 1.5))),
              IconButton(
                tooltip: t('复制', 'Copy'),
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () => Clipboard.setData(ClipboardData(text: r.text)),
              ),
            ]),
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
        sw(t('去除语气词', 'Remove filler words'), t('嗯、呃，以及单独出现的"啊""那个"等', '"um", "uh", 嗯, 呃 and stand-alone 那个'),
            settings.removeFillers, (v) => settings.removeFillers = v),
        sw(t('去除口吃重复', 'Remove stutters'), t('"我我我想" → "我想"，"这个这个" → "这个"', '"I I I think" → "I think"'),
            settings.removeStutter, (v) => settings.removeStutter = v),
        sw(t('规范标点', 'Tidy punctuation'), t('中文里用全角标点，去掉重复和多余的标点', 'Full-width marks in Chinese, no doubled marks'),
            settings.normalizePunctuation, (v) => settings.normalizePunctuation = v),
        sw(t('常见术语大小写', 'Fix common term casing'), t('github → GitHub，chat gpt → ChatGPT 等', 'github → GitHub, chat gpt → ChatGPT, …'),
            settings.termCasing, (v) => settings.termCasing = v),
        sw(t('全大写英文改为正常大小写', 'Fix ALL-CAPS English'), t('"HELLO WORLD" → "Hello world"（SenseVoice 常输出大写英文）', '"HELLO WORLD" → "Hello world" (SenseVoice prints capitals)'),
            settings.fixAllCaps, (v) => settings.fixAllCaps = v),
        sw(t('中英文之间加空格', 'Space between Chinese and Latin'), t('"用Python写" → "用 Python 写"', '"用Python写" → "用 Python 写"'),
            settings.cjkSpacing, (v) => settings.cjkSpacing = v),
        sw(t('繁体转简体', 'Convert Traditional to Simplified Chinese'),
            t('部分模型（如 Qwen3）可能输出繁体字', 'Some models (e.g. Qwen3) may output Traditional characters'),
            settings.toSimplified, (v) => settings.toSimplified = v),
        sw(t('去掉句末句号', 'Drop trailing period'), t('适合聊天软件里的短句输入', 'Handy for short chat messages'),
            settings.stripTrailingPeriod, (v) => settings.stripTrailingPeriod = v),
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
          t('人名、产品名、行业术语等。英文词会自动统一大小写；开启 AI 时会作为参考，让读音相近的词改成它们。',
              'Names, products, jargon. Latin words get their casing fixed; the AI also uses them to fix similar-sounding words.'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (settings.vocabulary.isNotEmpty) ...[
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final w in settings.vocabulary)
              InputChip(
                label: Text(w),
                onDeleted: () => settings.update((s) => s.vocabulary = [...s.vocabulary]..remove(w)),
              ),
          ]),
          const SizedBox(height: 8),
        ],
        Row(children: [
          Expanded(
            child: TextField(
              controller: _term,
              decoration: dense.copyWith(hintText: t('例如：OpenSpeak、张三丰', 'e.g. OpenSpeak')),
              onSubmitted: (_) => addTerm(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(tooltip: t('添加', 'Add'), icon: const Icon(Icons.add_rounded), onPressed: addTerm),
        ]),
        const Divider(height: 28),
        Text(t('替换规则', 'Replacements'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          t('总是识别错的词，直接替换成正确写法（区分大小写，按顺序执行）。', 'Words that keep coming out wrong, replaced as written (case-sensitive, in order).'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        for (final r in settings.replacements)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              Expanded(child: Text(r.from, overflow: TextOverflow.ellipsis)),
              Icon(Icons.arrow_forward_rounded, size: 16, color: scheme.outline),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(r.to.isEmpty ? t('（删除）', '(remove)') : r.to,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600))),
              IconButton(
                tooltip: t('删除', 'Delete'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () => settings.update((s) => s.replacements = [...s.replacements]..remove(r)),
              ),
            ]),
          ),
        Row(children: [
          Expanded(
            child: TextField(controller: _from, decoration: dense.copyWith(hintText: t('识别成', 'Heard as'))),
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
        ]),
      ],
    );
  }

  /// One entry per line: "wrong = right" is a replacement, anything else a term.
  Future<void> _bulkEdit(BuildContext context) async {
    final c = TextEditingController(text: [
      ...settings.vocabulary,
      for (final r in settings.replacements) '${r.from} = ${r.to}',
    ].join('\n'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('批量编辑词典', 'Edit dictionary')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('每行一条。"错词 = 正词" 是替换规则，单独一个词是专有名词。', 'One per line. "wrong = right" is a replacement; a single word is a term.'),
                style: TextStyle(fontSize: 13, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            TextField(
              controller: c,
              autofocus: true,
              minLines: 10,
              maxLines: 16,
              style: const TextStyle(fontSize: 14, height: 1.5),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'OpenSpeak\n在见 = 再见'),
            ),
          ]),
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
          dictation.warmUpLlm(force: true);
        },
      ),
      children: [
        Text(
          t('用大语言模型根据上下文改正同音字、错别字和标点。推荐在本机运行 Ollama，文字不出本机；也可使用云端服务。',
              'A language model fixes homophones, typos and punctuation from context. Ollama runs on this machine so text stays local; cloud services also work.'),
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
            },
          ),
        ),
        if (!p.local)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(kRadius - 4),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.cloud_outlined, size: 18, color: scheme.tertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('开启后识别出的文字会发送到该服务处理（音频不会上传），请留意其隐私条款与计费。',
                      'Recognized text (not audio) is sent to this service; mind its privacy terms and pricing.'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ]),
          ),
        const SizedBox(height: 4),
        TextField(
          controller: _url,
          decoration: dense.copyWith(labelText: t('接口地址', 'Base URL'), hintText: 'https://…/v1'),
          onChanged: (_) => _saveEndpoint(),
        ),
        const SizedBox(height: 10),
        Row(children: [
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
        ]),
        const SizedBox(height: 10),
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
        if (p.local)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              t('安装 Ollama 后在终端运行 ollama pull qwen2.5:3b 下载模型（约 2 GB）；已下载的其他模型可点模型右侧的按钮选择。',
                  'After installing Ollama run "ollama pull qwen2.5:3b" (about 2 GB); pick other downloaded models with the button next to Model.'),
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        if (p.keyUrl != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text(p.local ? t('下载 Ollama', 'Get Ollama') : t('获取 API Key', 'Get an API key')),
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
        Text(
          switch (settings.llmMode) {
            LlmMode.correct => t('只改错别字和标点，保留原话的用词和语气。', 'Only typos and punctuation; wording is kept.'),
            LlmMode.polish => t('同时去掉口头禅、重复和改口，整理成通顺的书面语。', 'Also drops fillers, repeats and false starts for clean prose.'),
            LlmMode.custom => t('使用下面的提示词。', 'Uses the prompt below.'),
          },
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
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
        Row(children: [
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
        ]),
        Row(children: [
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
        ]),
      ],
    );
  }
}
