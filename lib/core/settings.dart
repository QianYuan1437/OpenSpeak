import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_capture.dart';
import 'text_refiner.dart';

enum TriggerMode { hold, toggle }

/// How recognized text reaches the focused application.
enum OutputMode { type, paste, clipboard }

/// A global hotkey: one main key plus modifiers. Key names are shared by the
/// native layers (mapped to VK codes on Windows and keysyms on X11).
class Hotkey {
  const Hotkey(this.key,
      {this.ctrl = false, this.alt = false, this.shift = false, this.meta = false});

  final String key;
  final bool ctrl, alt, shift, meta;

  /// [key] is a name the native hotkey code understands: RightCtrl,
  /// RightAlt, RightShift, CapsLock, ScrollLock, Pause, Insert, Space,
  /// Backquote, F1..F24, A..Z or 0..9 (see HotkeyRecorder).
  static const keyLabels = {
    'RightCtrl': '右 Ctrl',
    'RightAlt': '右 Alt',
    'RightShift': '右 Shift',
    'Backquote': '`',
  };

  String get label {
    final parts = [
      if (ctrl) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) Platform.isWindows ? 'Win' : 'Super',
      keyLabels[key] ?? key,
    ];
    return parts.join(' + ');
  }

  Map<String, Object> toJson() =>
      {'key': key, 'ctrl': ctrl, 'alt': alt, 'shift': shift, 'meta': meta};

  factory Hotkey.fromJson(Map m) => Hotkey(m['key'] as String,
      ctrl: m['ctrl'] == true,
      alt: m['alt'] == true,
      shift: m['shift'] == true,
      meta: m['meta'] == true);

  Hotkey copyWith({String? key, bool? ctrl, bool? alt, bool? shift, bool? meta}) =>
      Hotkey(key ?? this.key,
          ctrl: ctrl ?? this.ctrl,
          alt: alt ?? this.alt,
          shift: shift ?? this.shift,
          meta: meta ?? this.meta);
}

/// Persistent user preferences (one JSON blob in shared_preferences).
class Settings extends ChangeNotifier {
  static const _key = 'openspeak.settings.v1';
  late SharedPreferences _prefs;

  String modelId = 'sense-voice-int8';
  String? deviceId;
  bool preferWireless = true;
  ChannelMode channel = ChannelMode.mix;
  double gainDb = 0;
  bool autoGain = true;
  TriggerMode trigger = TriggerMode.hold;
  Hotkey hotkey = const Hotkey('RightCtrl');
  OutputMode output = OutputMode.type;
  bool stripTrailingPeriod = false;
  bool toSimplified = true;
  String language = 'auto';
  bool useGpu = false;
  int threads = defaultThreads;
  ThemeMode themeMode = ThemeMode.system;

  /// ARGB seed of the accent colour (see kAccentPresets).
  int accent = 0xFF5B5BD6;

  /// 'system', 'zh' or 'en'.
  String uiLanguage = 'system';
  bool soundCue = true;

  /// Recording pill: 'center' | 'top' | 'bottom', and window opacity.
  String pillPosition = 'center';
  double pillOpacity = 0.8;
  /// Start in the tray when opened manually (sign-in autostart always does).
  bool startHidden = false;
  bool autoCheckUpdates = true;

  /// App version of the previous launch ('' before the first one).
  String lastRunVersion = '';

  /// No saved settings yet: this is the first launch.
  bool firstRun = false;

  /// Bumped when a stored value must be migrated once.
  static const _prefsVersion = 2;
  bool bubbleEnabled = false;

  // Refine page: offline rules.
  bool removeFillers = true;
  bool removeStutter = true;
  bool normalizePunctuation = true;
  bool cjkSpacing = false;
  bool termCasing = true;
  bool fixAllCaps = true;
  List<Replacement> replacements = [];
  List<String> vocabulary = [];

  // Refine page: AI correction.
  bool llmEnabled = false;
  String llmProvider = 'ollama';
  LlmMode llmMode = LlmMode.correct;
  String llmPrompt = '';
  int llmTimeoutSec = 8;

  /// Folder of the Ollama that OpenSpeak installed ('' if none).
  String ollamaDir = '';

  /// Start an installed but stopped Ollama when the AI needs it.
  bool ollamaAutoStart = true;

  /// An unfinished Ollama install: folder and model to pull afterwards.
  String ollamaPendingDir = '';
  String ollamaPendingModel = '';

  /// Per provider: {baseUrl, model, apiKey}, so switching keeps each key.
  Map<String, Map<String, String>> llmEndpoints = {};

  /// URL / model / key of [id], falling back to the preset's defaults.
  ({String baseUrl, String model, String apiKey}) endpointOf(String id) {
    final p = llmProviderById(id);
    final e = llmEndpoints[id] ?? const {};
    return (
      baseUrl: e['baseUrl'] ?? p.baseUrl,
      model: e['model'] ?? p.model,
      apiKey: e['apiKey'] ?? '',
    );
  }

  void setEndpoint(String id, {String? baseUrl, String? model, String? apiKey}) {
    final e = endpointOf(id);
    llmEndpoints[id] = {
      'baseUrl': baseUrl ?? e.baseUrl,
      'model': model ?? e.model,
      'apiKey': apiKey ?? e.apiKey,
    };
  }

  RuleOptions get ruleOptions => RuleOptions(
        removeFillers: removeFillers,
        removeStutter: removeStutter,
        normalizePunctuation: normalizePunctuation,
        cjkSpacing: cjkSpacing,
        termCasing: termCasing,
        fixAllCaps: fixAllCaps,
        replacements: replacements,
        vocabulary: vocabulary,
      );

  LlmConfig get llmConfig {
    final e = endpointOf(llmProvider);
    return LlmConfig(
      api: llmProviderById(llmProvider).api,
      baseUrl: e.baseUrl,
      model: e.model,
      apiKey: e.apiKey,
      mode: llmMode,
      customPrompt: llmPrompt,
      vocabulary: vocabulary,
      timeout: Duration(seconds: llmTimeoutSec),
      ollama: llmProvider == 'ollama',
    );
  }

  static int get defaultThreads =>
      math.max(1, math.min(4, Platform.numberOfProcessors ~/ 2));

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs.getString(_key);
    if (raw == null) {
      firstRun = true;
      return;
    }
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      modelId = m['modelId'] as String? ?? modelId;
      deviceId = m['deviceId'] as String?;
      preferWireless = m['preferWireless'] as bool? ?? preferWireless;
      channel = ChannelMode.values.byName(m['channel'] as String? ?? 'mix');
      gainDb = (m['gainDb'] as num?)?.toDouble() ?? gainDb;
      autoGain = m['autoGain'] as bool? ?? autoGain;
      trigger = TriggerMode.values.byName(m['trigger'] as String? ?? 'hold');
      if (m['hotkey'] is Map) hotkey = Hotkey.fromJson(m['hotkey'] as Map);
      output = OutputMode.values.byName(m['output'] as String? ?? 'type');
      stripTrailingPeriod = m['stripTrailingPeriod'] as bool? ?? false;
      toSimplified = m['toSimplified'] as bool? ?? true;
      language = m['language'] as String? ?? language;
      useGpu = m['useGpu'] as bool? ?? false;
      threads = m['threads'] as int? ?? threads;
      themeMode = ThemeMode.values.byName(m['themeMode'] as String? ?? 'system');
      accent = m['accent'] as int? ?? accent;
      uiLanguage = m['uiLanguage'] as String? ?? uiLanguage;
      soundCue = m['soundCue'] as bool? ?? soundCue;
      pillPosition = m['pillPosition'] as String? ?? pillPosition;
      pillOpacity = (m['pillOpacity'] as num?)?.toDouble() ?? pillOpacity;
      startHidden = m['startHidden'] as bool? ?? startHidden;
      autoCheckUpdates = m['autoCheckUpdates'] as bool? ?? autoCheckUpdates;
      lastRunVersion = m['lastRunVersion'] as String? ?? '';
      // v1 "start hidden" also covered sign-in autostart and was easy to turn
      // on by accident; it now only means "hide when opened manually".
      if ((m['prefsVersion'] as int? ?? 1) < 2) startHidden = false;
      bubbleEnabled = m['bubbleEnabled'] as bool? ?? bubbleEnabled;
      removeFillers = m['removeFillers'] as bool? ?? removeFillers;
      removeStutter = m['removeStutter'] as bool? ?? removeStutter;
      normalizePunctuation = m['normalizePunctuation'] as bool? ?? normalizePunctuation;
      cjkSpacing = m['cjkSpacing'] as bool? ?? cjkSpacing;
      termCasing = m['termCasing'] as bool? ?? termCasing;
      fixAllCaps = m['fixAllCaps'] as bool? ?? fixAllCaps;
      replacements = [
        for (final r in m['replacements'] as List? ?? const []) Replacement.fromJson(r as Map),
      ];
      vocabulary = [for (final w in m['vocabulary'] as List? ?? const []) w as String];
      llmEnabled = m['llmEnabled'] as bool? ?? llmEnabled;
      llmProvider = m['llmProvider'] as String? ?? llmProvider;
      llmMode = LlmMode.values.byName(m['llmMode'] as String? ?? 'correct');
      llmPrompt = m['llmPrompt'] as String? ?? llmPrompt;
      llmTimeoutSec = m['llmTimeoutSec'] as int? ?? llmTimeoutSec;
      ollamaDir = m['ollamaDir'] as String? ?? ollamaDir;
      ollamaAutoStart = m['ollamaAutoStart'] as bool? ?? ollamaAutoStart;
      ollamaPendingDir = m['ollamaPendingDir'] as String? ?? '';
      ollamaPendingModel = m['ollamaPendingModel'] as String? ?? '';
      llmEndpoints = {
        for (final e in (m['llmEndpoints'] as Map? ?? const {}).entries)
          e.key as String: (e.value as Map).map((k, v) => MapEntry(k as String, v as String)),
      };
    } catch (_) {
      // Corrupt or older settings: keep defaults.
    }
  }

  Future<void> update(void Function(Settings s) change) async {
    change(this);
    notifyListeners();
    await _prefs.setString(_key, jsonEncode(_toJson()));
  }

  Map<String, Object?> _toJson() => {
        'modelId': modelId,
        'deviceId': deviceId,
        'preferWireless': preferWireless,
        'channel': channel.name,
        'gainDb': gainDb,
        'autoGain': autoGain,
        'trigger': trigger.name,
        'hotkey': hotkey.toJson(),
        'output': output.name,
        'stripTrailingPeriod': stripTrailingPeriod,
        'toSimplified': toSimplified,
        'language': language,
        'useGpu': useGpu,
        'threads': threads,
        'themeMode': themeMode.name,
        'accent': accent,
        'uiLanguage': uiLanguage,
        'soundCue': soundCue,
        'pillPosition': pillPosition,
        'pillOpacity': pillOpacity,
        'startHidden': startHidden,
        'autoCheckUpdates': autoCheckUpdates,
        'lastRunVersion': lastRunVersion,
        'prefsVersion': _prefsVersion,
        'bubbleEnabled': bubbleEnabled,
        'removeFillers': removeFillers,
        'removeStutter': removeStutter,
        'normalizePunctuation': normalizePunctuation,
        'cjkSpacing': cjkSpacing,
        'termCasing': termCasing,
        'fixAllCaps': fixAllCaps,
        'replacements': [for (final r in replacements) r.toJson()],
        'vocabulary': vocabulary,
        'llmEnabled': llmEnabled,
        'llmProvider': llmProvider,
        'llmMode': llmMode.name,
        'llmPrompt': llmPrompt,
        'llmTimeoutSec': llmTimeoutSec,
        'ollamaDir': ollamaDir,
        'ollamaAutoStart': ollamaAutoStart,
        'ollamaPendingDir': ollamaPendingDir,
        'ollamaPendingModel': ollamaPendingModel,
        'llmEndpoints': llmEndpoints,
      };
}
