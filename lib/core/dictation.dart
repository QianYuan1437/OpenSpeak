import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Size;
import 'package:record/record.dart' show InputDevice;
import 'package:shared_preferences/shared_preferences.dart';

import 'asr_engine.dart';
import 'audio_capture.dart';
import 'gpu.dart';
import 'mic_profiles.dart';
import 'model_catalog.dart';
import 'model_manager.dart';
import 'native_bridge.dart';
import 'settings.dart';
import 'text_output.dart';

enum DictationState { idle, loading, listening, processing, error }

class HistoryItem {
  HistoryItem(this.text, this.time, this.audioMs);
  final String text;
  final DateTime time;
  final int audioMs;

  Map<String, Object> toJson() =>
      {'text': text, 'time': time.millisecondsSinceEpoch, 'audioMs': audioMs};

  factory HistoryItem.fromJson(Map m) => HistoryItem(m['text'] as String,
      DateTime.fromMillisecondsSinceEpoch(m['time'] as int), m['audioMs'] as int? ?? 0);
}

/// Orchestrates capture → recognition → output, driven by the UI, global
/// hotkeys (desktop) or the floating bubble (Android).
class Dictation extends ChangeNotifier {
  Dictation(this.settings, this.models, this.gpu) {
    output = TextOutput(bridge);
    _engineSub = engine.events.listen(_onAsr);
    _nativeSub = bridge.events.listen(_onNative);
    capture.levels.listen((l) {
      level = l;
      _levelTick.add(l);
    });
  }

  final Settings settings;
  final ModelManager models;
  final GpuManager gpu;
  final engine = AsrEngine();
  final capture = AudioCapture();
  final bridge = NativeBridge.instance;
  late final TextOutput output;
  late final StreamSubscription<AsrEvent> _engineSub;
  late final StreamSubscription<NativeEvent> _nativeSub;
  final _levelTick = StreamController<double>.broadcast();
  final _messages = StreamController<String>.broadcast();

  DictationState state = DictationState.idle;
  String? error;
  double level = 0;
  String partial = '';
  final List<String> segments = [];

  /// Text shown in the main transcript box (accumulates across sessions
  /// when dictating into OpenSpeak itself).
  String transcript = '';
  String? loadedModelId;
  String? loadedProvider;
  int? loadMs;
  List<InputDevice> devices = [];
  InputDevice? activeDevice;
  final List<HistoryItem> history = [];

  bool _pill = false;
  bool _deliverExternally = false;
  bool _hotkeyHeld = false;
  Timer? _devicePoll;
  Completer<void>? _loading;
  int _sessionStartMs = 0;

  Stream<double> get levels => _levelTick.stream;

  /// One-line notices for the UI (snackbars / bubble toasts).
  Stream<String> get messages => _messages.stream;

  /// The desktop window is currently shown as the compact recording pill.
  bool get pillMode => _pill;

  bool get isActive =>
      state == DictationState.listening || state == DictationState.processing;

  ModelSpec? get currentModel => modelById(settings.modelId);

  MicBrand? get activeBrand =>
      activeDevice == null ? null : detectMicBrand(activeDevice!.label);

  Future<void> init() async {
    await _loadHistory();
    await refreshDevices();
    _devicePoll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!isActive) refreshDevices();
    });
    if (isDesktop) await applyHotkey();
    unawaited(ensureModel());
  }

  // Models ------------------------------------------------------------------

  /// Loads the selected model if installed and not already loaded.
  Future<void> ensureModel({bool force = false}) async {
    final spec = currentModel;
    if (spec == null || !models.isInstalled(spec)) return;
    // The CPU and CUDA builds share DLL names, so whichever loads first stays
    // for the rest of the process; switching takes a restart.
    final gpuLib = GpuManager.gpuLibLoaded || settings.useGpu && gpu.ready && !GpuManager.cpuLibLoaded;
    // Small int8 models already decode in ~0.1 s on the CPU and lose accuracy
    // under CUDA, so only the models marked for the GPU use it.
    final provider = gpuLib && settings.useGpu && spec.gpuRecommended ? 'cuda' : 'cpu';
    if (!force &&
        engine.isLoaded &&
        loadedModelId == spec.id &&
        loadedProvider == provider) {
      return;
    }
    if (_loading != null) return _loading!.future;
    final done = _loading = Completer<void>();
    state = DictationState.loading;
    error = null;
    notifyListeners();
    try {
      await engine.load(AsrConfig(
        kind: spec.kind,
        files: models.filesOf(spec),
        vadModel: models.vadPath,
        provider: provider,
        threads: settings.threads,
        language: settings.language,
        partial: spec.supportsPartial,
        libDir: gpuLib ? gpu.libDir : null,
      ));
      loadedModelId = spec.id;
      loadedProvider = provider;
      if (gpuLib) {
        GpuManager.gpuLibLoaded = true;
      } else {
        GpuManager.cpuLibLoaded = true;
      }
      state = DictationState.idle;
    } catch (e) {
      loadedModelId = null;
      error = '$e';
      state = DictationState.error;
      if (provider == 'cuda') {
        _messages.add('GPU 加载失败，已回退到 CPU / GPU load failed, using CPU');
        await settings.update((s) => s.useGpu = false);
        _loading = null;
        done.complete();
        return ensureModel(force: true);
      }
    } finally {
      _loading = null;
      if (!done.isCompleted) done.complete();
      notifyListeners();
    }
  }

  void _onAsr(AsrEvent ev) {
    switch (ev) {
      case AsrReady(:final loadMs):
        this.loadMs = loadMs;
      case AsrError(:final message):
        if (state == DictationState.processing || state == DictationState.listening) {
          state = DictationState.error;
          error = message;
          _finishUi(false);
        }
      case AsrPartial(:final text):
        if (state == DictationState.listening) partial = text;
      case AsrSegment(:final text):
        segments.add(text);
        partial = '';
      case AsrFinal():
        unawaited(_onFinal(ev));
    }
    _pushBubble();
    notifyListeners();
  }

  // Devices -----------------------------------------------------------------

  Future<void> refreshDevices() async {
    final list = await capture.devices();
    final before = devices.map((d) => d.id).toSet();
    devices = list;
    final picked = chooseDevice(list, settings.deviceId,
        preferWireless: settings.preferWireless, rank: micPreference);
    final newBrand = picked != null &&
        !before.contains(picked.id) &&
        before.isNotEmpty &&
        detectMicBrand(picked.label) != null;
    if (picked?.id != activeDevice?.id) {
      activeDevice = picked;
      if (newBrand) _messages.add('🎙 ${detectMicBrand(picked.label)!.name}: ${picked.label}');
    }
    notifyListeners();
  }

  Future<void> selectDevice(String? id) async {
    await settings.update((s) => s.deviceId = id);
    await refreshDevices();
  }

  // Hotkeys / native events ---------------------------------------------------

  Future<bool> applyHotkey() async {
    final ok = await bridge.registerHotkey(settings.hotkey);
    if (!ok) _messages.add('快捷键注册失败 / Hotkey registration failed: ${settings.hotkey.label}');
    return ok;
  }

  void _onNative(NativeEvent ev) {
    switch (ev) {
      case NativeEvent.hotkeyDown:
        if (_hotkeyHeld) return; // key repeat
        _hotkeyHeld = true;
        if (settings.trigger == TriggerMode.hold) {
          if (!isActive) start(external: true);
        } else {
          toggle(external: true);
        }
      case NativeEvent.hotkeyUp:
        _hotkeyHeld = false;
        if (settings.trigger == TriggerMode.hold && state == DictationState.listening) {
          stop();
        }
      case NativeEvent.bubbleTap:
        toggle(external: true);
      case NativeEvent.bubblePressStart:
        if (!isActive) start(external: true);
      case NativeEvent.bubblePressEnd:
        if (state == DictationState.listening) stop();
    }
  }

  // Session -----------------------------------------------------------------

  Future<void> toggle({bool external = false}) async {
    if (state == DictationState.listening) {
      await stop();
    } else if (!isActive) {
      await start(external: external);
    }
  }

  /// [external]: triggered from a hotkey/bubble, so the result goes to the
  /// focused app instead of only the in-app transcript.
  Future<void> start({bool external = false}) async {
    if (isActive) return;
    final spec = currentModel;
    if (spec == null || !models.isInstalled(spec)) {
      _fail('请先在“模型”页下载识别模型 / Download a model first');
      return;
    }
    await ensureModel();
    if (!engine.isLoaded) {
      _fail(error ?? 'model not loaded');
      return;
    }
    if (!await capture.ensurePermission()) {
      _fail('没有麦克风权限 / Microphone permission denied');
      return;
    }
    _deliverExternally = external;
    if (isDesktop && external) {
      final active = await bridge.isWindowActive();
      _deliverExternally = !active;
      if (!active) {
        await _showPill();
      }
    }
    segments.clear();
    partial = '';
    error = null;
    engine.begin(autoGain: settings.autoGain);
    try {
      await capture.start(
        device: activeDevice,
        channel: settings.channel,
        gainDb: settings.gainDb,
        agc: settings.autoGain,
        onSamples: engine.feed,
      );
    } catch (e) {
      _fail('无法打开麦克风 / Cannot open microphone: $e');
      return;
    }
    _sessionStartMs = DateTime.now().millisecondsSinceEpoch;
    state = DictationState.listening;
    _pushBubble();
    notifyListeners();
  }

  Future<void> stop() async {
    if (state != DictationState.listening) return;
    state = DictationState.processing;
    _pushBubble();
    notifyListeners();
    await capture.stop();
    engine.end();
  }

  static const pillSize = Size(460, 72);

  Future<void> _showPill() async {
    _pill = true;
    notifyListeners();
    await bridge.enterPill(pillSize.width, pillSize.height,
        position: settings.pillPosition, opacity: settings.pillOpacity);
  }

  /// Shows the pill for a moment so its position/opacity can be judged.
  Future<void> previewPill(String sample) async {
    if (isActive || _pill) return;
    partial = sample;
    await _showPill();
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    partial = '';
    _pill = false;
    await bridge.exitPill();
    notifyListeners();
  }

  /// Aborts the session without output.
  Future<void> cancel() async {
    if (!isActive) return;
    await capture.stop();
    engine.cancel();
    state = DictationState.idle;
    segments.clear();
    partial = '';
    _finishUi(false);
    notifyListeners();
  }

  Future<void> _onFinal(AsrFinal fin) async {
    if (state != DictationState.processing) return;
    final text = postProcess(fin.text,
        stripTrailingPeriod: settings.stripTrailingPeriod, toSimplified: settings.toSimplified);
    segments.clear();
    partial = '';
    state = DictationState.idle;
    if (text.isEmpty) {
      _messages.add('没有识别到语音 / No speech detected');
      _finishUi(false);
      notifyListeners();
      return;
    }
    final audioMs = fin.audioMs > 0
        ? fin.audioMs
        : DateTime.now().millisecondsSinceEpoch - _sessionStartMs;
    _addHistory(HistoryItem(text, DateTime.now(), audioMs));
    if (_deliverExternally) {
      if (_pill) {
        // Let the pill vanish first so focus is surely back on the target.
        await bridge.exitPill();
        _pill = false;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      final r = await output.deliver(text, settings.output);
      if (r == OutputResult.copied) _messages.add('已复制到剪贴板 / Copied to clipboard');
      if (Platform.isAndroid) {
        await bridge.setBubbleState('done', text: text);
      }
    } else {
      transcript = joinSegments([transcript, text]);
    }
    _finishUi(true);
    notifyListeners();
  }

  void _fail(String msg) {
    error = msg;
    state = DictationState.idle;
    _messages.add(msg);
    _finishUi(false);
    if (Platform.isAndroid) bridge.setBubbleState('error', text: msg);
    notifyListeners();
  }

  void _finishUi(bool ok) {
    if (_pill) {
      _pill = false;
      bridge.exitPill();
    }
    if (Platform.isAndroid && !ok) bridge.setBubbleState('idle');
  }

  DateTime _lastBubble = DateTime(0);

  void _pushBubble() {
    if (!Platform.isAndroid || !settings.bubbleEnabled) return;
    final now = DateTime.now();
    if (state == DictationState.listening &&
        now.difference(_lastBubble).inMilliseconds < 80) {
      return;
    }
    _lastBubble = now;
    final s = switch (state) {
      DictationState.listening => 'listening',
      DictationState.processing => 'processing',
      _ => null,
    };
    if (s != null) bridge.setBubbleState(s, level: level, text: liveText);
  }

  /// Segments plus the in-progress partial.
  String get liveText => joinSegments([...segments, partial]);

  void clearTranscript() {
    transcript = '';
    notifyListeners();
  }

  void setTranscript(String t) => transcript = t;

  // History -----------------------------------------------------------------

  static const _historyKey = 'openspeak.history.v1';

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null) return;
    try {
      history
        ..clear()
        ..addAll((jsonDecode(raw) as List).map((e) => HistoryItem.fromJson(e as Map)));
    } catch (_) {}
  }

  void _addHistory(HistoryItem h) {
    history.insert(0, h);
    if (history.length > 300) history.removeRange(300, history.length);
    _saveHistory();
  }

  void removeHistory(HistoryItem h) {
    history.remove(h);
    _saveHistory();
    notifyListeners();
  }

  void clearHistory() {
    history.clear();
    _saveHistory();
    notifyListeners();
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(history.map((h) => h.toJson()).toList()));
  }

  @override
  void dispose() {
    _devicePoll?.cancel();
    _engineSub.cancel();
    _nativeSub.cancel();
    capture.dispose();
    engine.dispose();
    super.dispose();
  }
}
