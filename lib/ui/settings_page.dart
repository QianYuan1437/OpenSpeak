import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/audio_capture.dart';
import '../core/dictation.dart';
import '../core/mic_profiles.dart';
import '../core/settings.dart';
import 'desktop_shell.dart';
import 'home_shell.dart';
import 'i18n.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    dictation.refreshDevices();
  }

  @override
  void dispose() {
    if (_testing) dictation.capture.stop();
    super.dispose();
  }

  Future<void> _toggleTest() async {
    if (_testing) {
      await dictation.capture.stop();
      setState(() => _testing = false);
      return;
    }
    if (dictation.isActive) return;
    if (!await dictation.capture.ensurePermission()) return;
    await dictation.capture.start(
      device: dictation.activeDevice,
      channel: settings.channel,
      gainDb: settings.gainDb,
      agc: settings.autoGain,
      onSamples: (_) {},
    );
    setState(() => _testing = true);
  }

  /// Restarts the level test so new gain/channel settings apply.
  Future<void> _restartTest() async {
    if (!_testing) return;
    await dictation.capture.stop();
    _testing = false;
    await _toggleTest();
  }

  bool get _desktop => Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, dictation]),
      builder: (context, _) => PageFrame(
        title: t('设置', 'Settings'),
        children: [
          _micSection(context),
          if (_desktop) _hotkeySection(context),
          _recognitionSection(context),
          _appearanceSection(context),
          _aboutSection(context),
        ],
      ),
    );
  }

  Widget _micSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brand = dictation.activeBrand;
    final ids = dictation.devices.map((d) => d.id).toSet();
    final value = ids.contains(settings.deviceId) ? settings.deviceId : null;
    return SectionCard(
      title: t('麦克风', 'Microphone'),
      icon: Icons.mic_rounded,
      trailing: IconButton(
        tooltip: t('刷新设备', 'Refresh devices'),
        icon: const Icon(Icons.refresh_rounded),
        onPressed: dictation.refreshDevices,
      ),
      children: [
        SettingRow(
          title: t('输入设备', 'Input device'),
          subtitle: value == null ? t('自动：优先无线麦克风，否则系统默认', 'Auto: wireless mic first, else system default') : null,
          trailing: OsDropdown<String?>(
            value: value,
            maxWidth: 340,
            items: [
              DropdownMenuItem(
                value: null,
                child: Text(t('自动', 'Auto')),
              ),
              for (final d in dictation.devices)
                DropdownMenuItem(
                  value: d.id,
                  child: Row(children: [
                    if (detectMicBrand(d.label) != null) ...[
                      Icon(Icons.settings_input_antenna_rounded, size: 16, color: scheme.primary),
                      const SizedBox(width: 6),
                    ],
                    Expanded(child: Text(d.label, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
            ],
            onChanged: (v) async {
              await dictation.selectDevice(v);
              await _restartTest();
            },
          ),
        ),
        if (brand != null) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.verified_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(L.zh ? brand.tipZh : brand.tipEn)),
            ]),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('自动切换到无线麦克风', 'Auto-switch to wireless mics')),
          subtitle: Text(t('插入 DJI / Godox / 影石 Insta360 / RØDE 等接收器时自动使用',
              'Use DJI / Godox / Insta360 / RØDE receivers as soon as they are plugged in')),
          value: settings.preferWireless,
          onChanged: (v) async {
            await settings.update((s) => s.preferWireless = v);
            await dictation.refreshDevices();
          },
        ),
        const SizedBox(height: 4),
        Text(t('声道', 'Channel'), style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        SegmentedButton<ChannelMode>(
          segments: [
            ButtonSegment(value: ChannelMode.mix, label: Text(t('混合', 'Mix'))),
            ButtonSegment(value: ChannelMode.left, label: Text(t('左 / TX1', 'Left / TX1'))),
            ButtonSegment(value: ChannelMode.right, label: Text(t('右 / TX2', 'Right / TX2'))),
          ],
          selected: {settings.channel},
          onSelectionChanged: (v) async {
            await settings.update((s) => s.channel = v.first);
            await _restartTest();
          },
        ),
        const SizedBox(height: 12),
        Row(children: [
          Text(t('增益', 'Gain'), style: TextStyle(color: scheme.onSurfaceVariant)),
          Expanded(
            child: Slider(
              min: -12,
              max: 24,
              divisions: 36,
              value: settings.gainDb,
              label: '${settings.gainDb.round()} dB',
              onChanged: (v) => settings.update((s) => s.gainDb = v),
              onChangeEnd: (_) => _restartTest(),
            ),
          ),
          SizedBox(width: 56, child: Text('${settings.gainDb.round()} dB', textAlign: TextAlign.end)),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('自动增益', 'Auto gain')),
          subtitle: Text(t('自动放大音量偏小的领夹 / 无线麦克风', 'Boost quiet lavalier / wireless mics automatically')),
          value: settings.autoGain,
          onChanged: (v) async {
            await settings.update((s) => s.autoGain = v);
            await _restartTest();
          },
        ),
        Row(children: [
          OutlinedButton.icon(
            icon: Icon(_testing ? Icons.stop_rounded : Icons.graphic_eq_rounded, size: 18),
            label: Text(_testing ? t('停止测试', 'Stop test') : t('测试麦克风', 'Test microphone')),
            onPressed: dictation.isActive ? null : _toggleTest,
          ),
          const SizedBox(width: 16),
          if (_testing) const Expanded(child: LevelBars(bars: 36, height: 28, color: kListening)),
        ]),
      ],
    );
  }

  Widget _hotkeySection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = settings.hotkey;
    Future<void> setKey(Hotkey k) async {
      await settings.update((s) => s.hotkey = k);
      await dictation.applyHotkey();
    }

    return SectionCard(
      title: t('快捷键与输出', 'Hotkey & output'),
      icon: Icons.keyboard_rounded,
      children: [
        Text(t('触发方式', 'Trigger'), style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        SegmentedButton<TriggerMode>(
          segments: [
            ButtonSegment(
                value: TriggerMode.hold,
                icon: const Icon(Icons.touch_app_rounded, size: 18),
                label: Text(t('按住说话', 'Hold to talk'))),
            ButtonSegment(
                value: TriggerMode.toggle,
                icon: const Icon(Icons.toggle_on_outlined, size: 18),
                label: Text(t('按一下开始/结束', 'Press to toggle'))),
          ],
          selected: {settings.trigger},
          onSelectionChanged: (v) => settings.update((s) => s.trigger = v.first),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Text(t('按键', 'Key'), style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(width: 12),
          OsDropdown<String>(
            value: h.key,
            items: [
              for (final k in Hotkey.keys) DropdownMenuItem(value: k, child: Text(Hotkey.keyLabels[k] ?? k)),
            ],
            onChanged: (v) => setKey(h.copyWith(key: v)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              FilterChip(label: const Text('Ctrl'), selected: h.ctrl, onSelected: (v) => setKey(h.copyWith(ctrl: v))),
              FilterChip(label: const Text('Alt'), selected: h.alt, onSelected: (v) => setKey(h.copyWith(alt: v))),
              FilterChip(label: const Text('Shift'), selected: h.shift, onSelected: (v) => setKey(h.copyWith(shift: v))),
              FilterChip(
                  label: Text(Platform.isWindows ? 'Win' : 'Super'),
                  selected: h.meta,
                  onSelected: (v) => setKey(h.copyWith(meta: v))),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        Text('${t('当前', 'Current')}: ${h.label}', style: TextStyle(color: scheme.outline, fontSize: 12)),
        const SizedBox(height: 16),
        Text(t('录音浮条', 'Recording pill'), style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'center', label: Text(t('屏幕中央', 'Center'))),
              ButtonSegment(value: 'top', label: Text(t('顶部', 'Top'))),
              ButtonSegment(value: 'bottom', label: Text(t('底部', 'Bottom'))),
            ],
            selected: {settings.pillPosition},
            onSelectionChanged: (v) => settings.update((s) => s.pillPosition = v.first),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: Text(t('预览', 'Preview')),
            onPressed: dictation.isActive
                ? null
                : () async {
                    await dictation.previewPill(t('这是录音浮条的预览效果', 'This is how the pill looks'));
                    await DesktopShell.showMain();
                  },
          ),
        ]),
        Row(children: [
          Text(t('不透明度', 'Opacity'), style: TextStyle(color: scheme.onSurfaceVariant)),
          Expanded(
            child: Slider(
              min: 0.5,
              max: 1.0,
              divisions: 10,
              value: settings.pillOpacity.clamp(0.5, 1.0),
              label: '${(settings.pillOpacity * 100).round()}%',
              onChanged: (v) => settings.update((s) => s.pillOpacity = v),
            ),
          ),
          SizedBox(width: 44, child: Text('${(settings.pillOpacity * 100).round()}%', textAlign: TextAlign.end)),
        ]),
        const SizedBox(height: 12),
        Text(t('输出到当前应用的方式', 'How text reaches the focused app'),
            style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        SegmentedButton<OutputMode>(
          segments: [
            ButtonSegment(value: OutputMode.type, label: Text(t('模拟键入', 'Type'))),
            ButtonSegment(value: OutputMode.paste, label: Text(t('粘贴', 'Paste'))),
            ButtonSegment(value: OutputMode.clipboard, label: Text(t('仅复制', 'Copy only'))),
          ],
          selected: {settings.output},
          onSelectionChanged: (v) => settings.update((s) => s.output = v.first),
        ),
        const SizedBox(height: 4),
        Text(
          switch (settings.output) {
            OutputMode.type => t('逐字键入，不占用剪贴板（推荐）', 'Types characters directly; clipboard untouched (recommended)'),
            OutputMode.paste => t('通过剪贴板粘贴，长文本更快，粘贴后恢复原剪贴板', 'Pastes via clipboard (faster for long text), then restores it'),
            OutputMode.clipboard => t('只复制到剪贴板，由你手动粘贴', 'Only copies; you paste manually'),
          },
          style: TextStyle(color: scheme.outline, fontSize: 12),
        ),
        if (Platform.isLinux)
          FutureBuilder<bool>(
            future: dictation.output.hasXdotool,
            builder: (context, snap) => snap.data == false
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(t('未找到 xdotool，将仅复制到剪贴板。请执行：sudo apt install xdotool',
                        'xdotool not found; falling back to clipboard. Run: sudo apt install xdotool'),
                        style: TextStyle(color: scheme.error, fontSize: 12)),
                  )
                : const SizedBox.shrink(),
          ),
      ],
    );
  }

  Widget _recognitionSection(BuildContext context) {
    final spec = dictation.currentModel;
    final langs = {
      'auto': t('自动检测', 'Auto detect'),
      'zh': '中文',
      'en': 'English',
      'ja': '日本語',
      'ko': '한국어',
      'yue': '粤语',
    };
    final maxThreads = Platform.numberOfProcessors.clamp(1, 16);
    return SectionCard(
      title: t('识别', 'Recognition'),
      icon: Icons.translate_rounded,
      children: [
        if (spec?.id.startsWith('sense-voice') ?? false)
          SettingRow(
            title: t('语言', 'Language'),
            subtitle: t('指定语言可提升短句准确率', 'Fixing the language helps with short phrases'),
            trailing: OsDropdown<String>(
              value: settings.language,
              items: [for (final e in langs.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) async {
                await settings.update((s) => s.language = v ?? 'auto');
                await dictation.ensureModel(force: true);
              },
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('繁体转简体', 'Convert Traditional to Simplified Chinese')),
          subtitle: Text(t('部分模型（如 Qwen3）可能输出繁体字', 'Some models (e.g. Qwen3) may output Traditional characters')),
          value: settings.toSimplified,
          onChanged: (v) => settings.update((s) => s.toSimplified = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('去掉句末句号', 'Drop trailing period')),
          subtitle: Text(t('适合聊天软件里的短句输入', 'Handy for short chat messages')),
          value: settings.stripTrailingPeriod,
          onChanged: (v) => settings.update((s) => s.stripTrailingPeriod = v),
        ),
        Row(children: [
          Text(t('CPU 线程', 'CPU threads'), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Expanded(
            child: Slider(
              min: 1,
              max: maxThreads.toDouble(),
              divisions: maxThreads > 1 ? maxThreads - 1 : null,
              value: settings.threads.clamp(1, maxThreads).toDouble(),
              label: '${settings.threads}',
              onChanged: (v) => settings.update((s) => s.threads = v.round()),
              onChangeEnd: (_) => dictation.ensureModel(force: true),
            ),
          ),
          SizedBox(width: 32, child: Text('${settings.threads}', textAlign: TextAlign.end)),
        ]),
        if (dictation.loadMs != null && dictation.state != DictationState.loading)
          Text('${t('模型加载耗时', 'Model load time')}: ${dictation.loadMs} ms',
              style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 12)),
      ],
    );
  }

  Widget _appearanceSection(BuildContext context) {
    return SectionCard(
      title: t('外观与启动', 'Appearance & startup'),
      icon: Icons.palette_outlined,
      children: [
        Text(t('主题色', 'Accent color'), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final (argb, zh, en) in kAccentPresets)
            Tooltip(
              message: t(zh, en),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => settings.update((s) => s.accent = argb),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Color(argb),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: settings.accent == argb ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: settings.accent == argb
                      ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
                      : null,
                ),
              ),
            ),
        ]),
        const SizedBox(height: 16),
        Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<ThemeMode>(
            segments: [
              ButtonSegment(value: ThemeMode.system, label: Text(t('跟随系统', 'System'))),
              ButtonSegment(value: ThemeMode.light, label: Text(t('浅色', 'Light'))),
              ButtonSegment(value: ThemeMode.dark, label: Text(t('深色', 'Dark'))),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (v) => settings.update((s) => s.themeMode = v.first),
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'system', label: Text('Auto')),
              ButtonSegment(value: 'zh', label: Text('中文')),
              ButtonSegment(value: 'en', label: Text('English')),
            ],
            selected: {settings.uiLanguage},
            onSelectionChanged: (v) => settings.update((s) => s.uiLanguage = v.first),
          ),
        ]),
        if (_desktop)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('启动时隐藏到托盘', 'Start hidden in tray')),
            value: settings.startHidden,
            onChanged: (v) => settings.update((s) => s.startHidden = v),
          ),
      ],
    );
  }

  Widget _aboutSection(BuildContext context) {
    return SectionCard(
      title: t('关于', 'About'),
      icon: Icons.info_outline_rounded,
      children: [
        Text('OpenSpeak $appVersionLabel — ${t('开源、离线、跨平台的语音输入工具', 'open-source, offline, cross-platform voice typing')}'),
        const SizedBox(height: 4),
        SelectableText(kRepoUrl, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
        const SizedBox(height: 4),
        Text(t('识别引擎：sherpa-onnx（k2-fsa）· 模型版权归各自作者', 'Engine: sherpa-onnx (k2-fsa) · models © their authors'),
            style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 12)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => showLicensePage(context: context, applicationName: 'OpenSpeak', applicationVersion: kAppVersion),
            child: Text(t('开源许可', 'Licenses')),
          ),
        ),
      ],
    );
  }
}
