import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import 'gpu_loader.dart';
import 'model_catalog.dart';

const kSampleRate = 16000;

/// Everything the worker isolate needs to build a recognizer.
class AsrConfig {
  const AsrConfig({
    required this.kind,
    required this.files,
    required this.vadModel,
    this.provider = 'cpu',
    this.threads = 2,
    this.language = 'auto',
    this.partial = true,
    this.libDir,
  });

  final ModelKind kind;

  /// Role -> absolute path.
  final Map<String, String> files;
  final String vadModel;
  final String provider;
  final int threads;
  final String language;
  final bool partial;

  /// Directory holding an alternative sherpa-onnx C API library (GPU pack).
  final String? libDir;
}

sealed class AsrEvent {}

class AsrReady extends AsrEvent {
  AsrReady(this.loadMs);
  final int loadMs;
}

class AsrError extends AsrEvent {
  AsrError(this.message);
  final String message;
}

/// Live preview of the utterance currently being spoken.
class AsrPartial extends AsrEvent {
  AsrPartial(this.text);
  final String text;
}

/// A finished sentence (VAD segment).
class AsrSegment extends AsrEvent {
  AsrSegment(this.text);
  final String text;
}

/// The session ended; [text] is every segment joined.
class AsrFinal extends AsrEvent {
  AsrFinal(this.text, {required this.audioMs, required this.decodeMs});
  final String text;
  final int audioMs;
  final int decodeMs;
}

/// Runs sherpa-onnx in a background isolate so decoding never blocks the UI.
class AsrEngine {
  Isolate? _isolate;
  SendPort? _tx;
  final _events = StreamController<AsrEvent>.broadcast();
  AsrConfig? _config;
  Completer<void>? _ready;

  Stream<AsrEvent> get events => _events.stream;
  bool get isLoaded => _tx != null && (_ready?.isCompleted ?? false);
  AsrConfig? get config => _config;

  Future<void> load(AsrConfig config) async {
    await dispose();
    _config = config;
    final rx = ReceivePort();
    final ready = _ready = Completer<void>();
    _isolate = await Isolate.spawn(_workerMain, rx.sendPort,
        debugName: 'openspeak-asr');
    rx.listen((msg) {
      if (msg is SendPort) {
        _tx = msg;
        msg.send(_encodeConfig(config));
        return;
      }
      final ev = _decodeEvent(msg as Map);
      if (ev is AsrReady && !ready.isCompleted) ready.complete();
      if (ev is AsrError && !ready.isCompleted) {
        ready.completeError(ev.message);
      }
      _events.add(ev);
    });
    return ready.future;
  }

  /// Starts a new dictation session (clears VAD state and buffers).
  /// [autoGain] normalizes each utterance and boosts the VAD input so quiet
  /// lavalier / wireless mics are detected.
  void begin({bool autoGain = true}) => _tx?.send({'t': 'begin', 'agc': autoGain});

  void feed(Float32List samples) => _tx?.send(
      {'t': 'audio', 'd': TransferableTypedData.fromList([samples])});

  /// Flushes the VAD and emits [AsrFinal].
  void end() => _tx?.send(const {'t': 'end'});

  /// Drops the current session without emitting a result.
  void cancel() => _tx?.send(const {'t': 'cancel'});

  Future<void> dispose() async {
    _tx?.send(const {'t': 'quit'});
    _tx = null;
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _ready = null;
  }
}

Map<String, Object?> _encodeConfig(AsrConfig c) => {
      't': 'init',
      'kind': c.kind.index,
      'files': c.files,
      'vad': c.vadModel,
      'provider': c.provider,
      'threads': c.threads,
      'language': c.language,
      'partial': c.partial,
      'libDir': c.libDir,
    };

AsrEvent _decodeEvent(Map m) => switch (m['t']) {
      'ready' => AsrReady(m['ms'] as int),
      'error' => AsrError(m['msg'] as String),
      'partial' => AsrPartial(m['text'] as String),
      'segment' => AsrSegment(m['text'] as String),
      _ => AsrFinal(m['text'] as String,
          audioMs: m['audioMs'] as int, decodeMs: m['decodeMs'] as int),
    };

/// Joins recognized pieces, adding a space only between Latin words.
String joinSegments(Iterable<String> parts) {
  final out = StringBuffer();
  for (final raw in parts) {
    final p = raw.trim();
    if (p.isEmpty) continue;
    if (out.isNotEmpty) {
      final prev = out.toString();
      final a = prev.codeUnitAt(prev.length - 1);
      final b = p.codeUnitAt(0);
      if (a < 0x80 && b < 0x80 && a != 0x20) out.write(' ');
    }
    out.write(p);
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

void _workerMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  _Worker? worker;
  inbox.listen((msg) {
    final m = msg as Map;
    try {
      switch (m['t']) {
        case 'init':
          final sw = Stopwatch()..start();
          worker = _Worker.create(m, out);
          out.send({'t': 'ready', 'ms': sw.elapsedMilliseconds});
        case 'begin':
          worker?.begin(agc: m['agc'] as bool? ?? true);
        case 'audio':
          final data = (m['d'] as TransferableTypedData).materialize();
          worker?.accept(data.asFloat32List());
        case 'end':
          worker?.finish();
        case 'cancel':
          worker?.begin();
        case 'quit':
          worker?.free();
          worker = null;
          inbox.close();
      }
    } catch (e) {
      out.send({'t': 'error', 'msg': e.toString()});
    }
  });
}

/// Growable float buffer (avoids boxing doubles in a List).
class _FloatBuf {
  Float32List _data = Float32List(kSampleRate * 4);
  int length = 0;

  void add(Float32List s) {
    if (length + s.length > _data.length) {
      final n = Float32List(math.max(_data.length * 2, length + s.length));
      n.setRange(0, length, _data);
      _data = n;
    }
    _data.setRange(length, length + s.length, s);
    length += s.length;
  }

  /// Keeps only the newest [n] samples.
  void keepLast(int n) {
    if (length <= n) return;
    _data.setRange(0, n, _data, length - n);
    length = n;
  }

  Float32List view([int from = 0]) =>
      Float32List.sublistView(_data, from, length);

  void clear() => length = 0;
}

class _Worker {
  _Worker(this.out, this.rec, this.vadConfig, this.partialEnabled)
      : vad = so.VoiceActivityDetector(
            config: vadConfig, bufferSizeInSeconds: 60);

  final SendPort out;
  final so.OfflineRecognizer rec;
  final so.VadModelConfig vadConfig;
  final bool partialEnabled;
  so.VoiceActivityDetector vad;

  static const _window = 512;
  final _carry = _FloatBuf();
  final _pending = _FloatBuf(); // audio since the last finished segment
  final _all = _FloatBuf(); // whole session, for the no-VAD fallback
  final _texts = <String>[];
  final _partialWatch = Stopwatch();
  int _decodeMs = 0;
  int _audioSamples = 0;
  double _peak = 0;

  /// Inside an utterance (from first detection until its segment is popped);
  /// the VAD flag can flicker during short pauses, so it is not enough alone.
  bool _inSpeech = false;

  bool _agc = true;
  double _env = 0;
  double _vadGain = 1;

  static _Worker create(Map m, SendPort out) {
    final libDir = m['libDir'] as String?;
    if (libDir != null) preloadGpuRuntime(libDir);
    so.initBindings(libDir);
    final kind = ModelKind.values[m['kind'] as int];
    final f = (m['files'] as Map).cast<String, String>();
    final lang = m['language'] as String;
    final threads = m['threads'] as int;
    final provider = m['provider'] as String;

    var model = so.OfflineModelConfig(
      tokens: f['tokens'] ?? '',
      numThreads: threads,
      provider: provider,
      debug: false,
    );
    model = switch (kind) {
      ModelKind.senseVoice => so.OfflineModelConfig(
          senseVoice: so.OfflineSenseVoiceModelConfig(
            model: f['model']!,
            language: lang == 'auto' ? '' : lang,
            useInverseTextNormalization: true,
          ),
          tokens: model.tokens,
          numThreads: threads,
          provider: provider,
          debug: false,
        ),
      ModelKind.paraformer => so.OfflineModelConfig(
          paraformer: so.OfflineParaformerModelConfig(model: f['model']!),
          tokens: model.tokens,
          numThreads: threads,
          provider: provider,
          debug: false,
        ),
      ModelKind.fireRedCtc => so.OfflineModelConfig(
          fireRedAsrCtc: so.OfflineFireRedAsrCtcModelConfig(model: f['model']!),
          tokens: model.tokens,
          numThreads: threads,
          provider: provider,
          debug: false,
        ),
      ModelKind.qwen3 => so.OfflineModelConfig(
          qwen3Asr: so.OfflineQwen3AsrModelConfig(
            convFrontend: f['convFrontend']!,
            encoder: f['encoder']!,
            decoder: f['decoder']!,
            tokenizer: f['tokenizer']!,
          ),
          tokens: '',
          numThreads: threads,
          provider: provider,
          debug: false,
        ),
    };

    final rec = so.OfflineRecognizer(so.OfflineRecognizerConfig(model: model));
    final vadConfig = so.VadModelConfig(
      sileroVad: so.SileroVadModelConfig(
        model: m['vad'] as String,
        threshold: 0.4,
        minSilenceDuration: 0.6,
        minSpeechDuration: 0.2,
        maxSpeechDuration: 25,
        windowSize: _window,
      ),
      sampleRate: kSampleRate,
      numThreads: 1,
      debug: false,
    );
    return _Worker(out, rec, vadConfig, m['partial'] as bool);
  }

  void begin({bool? agc}) {
    if (agc != null) _agc = agc;
    _vadGain = 1;
    _env = 0;
    vad.reset();
    _carry.clear();
    _pending.clear();
    _all.clear();
    _texts.clear();
    _decodeMs = 0;
    _audioSamples = 0;
    _peak = 0;
    _inSpeech = false;
    _partialWatch
      ..reset()
      ..start();
  }

  void accept(Float32List samples) {
    _audioSamples += samples.length;
    for (final v in samples) {
      final a = v.abs();
      if (a > _peak) _peak = a;
    }
    if (_all.length < kSampleRate * 60) _all.add(samples);
    _pending.add(samples);
    _carry.add(_agc ? _boostForVad(samples) : samples);

    var off = 0;
    final buf = _carry.view();
    while (buf.length - off >= _window) {
      vad.acceptWaveform(Float32List.sublistView(buf, off, off + _window));
      off += _window;
    }
    _carry.keepLast(buf.length - off);
    _drainSegments();

    if (vad.isDetected()) _inSpeech = true;
    if (_inSpeech) {
      if (partialEnabled &&
          _partialWatch.elapsedMilliseconds > 600 &&
          _pending.length > kSampleRate ~/ 2) {
        _partialWatch
          ..reset()
          ..start();
        final text = _decode(_pending.view());
        if (text.isNotEmpty) out.send({'t': 'partial', 'text': text});
      }
    } else {
      // Silence: keep ~1 s of lead-in, enough to cover the VAD onset delay.
      _pending.keepLast(kSampleRate);
    }
  }

  /// Fast-attack / slow-release gain applied only to the VAD's copy.
  Float32List _boostForVad(Float32List s) {
    var peak = 0.0;
    for (final v in s) {
      final a = v.abs();
      if (a > peak) peak = a;
    }
    _env = math.max(peak, _env * 0.995);
    if (_env > 0.003) _vadGain = (0.3 / _env).clamp(1.0, 20.0);
    if (_vadGain == 1) return s;
    final out = Float32List(s.length);
    for (var i = 0; i < s.length; i++) {
      out[i] = (s[i] * _vadGain).clamp(-1.0, 1.0);
    }
    return out;
  }

  /// Scales a whole utterance to a consistent level (robust peak ≈ 0.6).
  Float32List _normalize(Float32List s) {
    if (!_agc || s.isEmpty) return s;
    final abs = <double>[];
    for (var i = 0; i < s.length; i += 4) {
      abs.add(s[i].abs());
    }
    abs.sort();
    final p = abs[(abs.length * 0.998).floor().clamp(0, abs.length - 1)];
    if (p < 1e-4) return s;
    final g = (0.6 / p).clamp(0.5, 20.0);
    if ((g - 1).abs() < 0.1) return s;
    final out = Float32List(s.length);
    for (var i = 0; i < s.length; i++) {
      out[i] = (s[i] * g).clamp(-1.0, 1.0);
    }
    return out;
  }

  void _drainSegments() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      final text = _decode(_withLeadIn(seg));
      _pending.clear();
      _inSpeech = vad.isDetected();
      if (text.isEmpty) continue;
      _texts.add(text);
      out.send({'t': 'segment', 'text': text});
    }
  }

  /// Silero reports a segment ~0.1 s after the real speech onset, which
  /// clips the first syllable. Re-cut the segment from the session buffer
  /// with 0.3 s of lead-in instead of using the VAD's samples directly.
  Float32List _withLeadIn(so.SpeechSegment seg) {
    const lead = kSampleRate * 3 ~/ 10;
    final end = math.min(seg.start + seg.samples.length, _all.length);
    if (seg.start < 0 || seg.start >= _all.length || end <= seg.start) {
      return seg.samples; // beyond the buffered window
    }
    final from = math.max(0, seg.start - lead);
    return Float32List.fromList(Float32List.sublistView(_all.view(), from, end));
  }

  void finish() {
    if (_carry.length > 0) {
      final tail = Float32List(_window)..setRange(0, _carry.length, _carry.view());
      vad.acceptWaveform(tail);
      _carry.clear();
    }
    vad.flush();
    _drainSegments();
    // Very short or very quiet utterances can slip past the VAD; decode the
    // whole take if it clearly contained sound.
    if (_texts.isEmpty && _all.length > kSampleRate ~/ 4 && _peak > 0.02) {
      final text = _decode(_all.view());
      if (text.isNotEmpty) _texts.add(text);
    }
    out.send({
      't': 'final',
      'text': joinSegments(_texts),
      'audioMs': _audioSamples * 1000 ~/ kSampleRate,
      'decodeMs': _decodeMs,
    });
    begin();
    _partialWatch.stop();
  }

  String _decode(Float32List samples) {
    final sw = Stopwatch()..start();
    final stream = rec.createStream();
    try {
      stream.acceptWaveform(samples: _normalize(samples), sampleRate: kSampleRate);
      rec.decode(stream);
      return _clean(rec.getResult(stream).text);
    } finally {
      stream.free();
      _decodeMs += sw.elapsedMilliseconds;
    }
  }

  static final _tagRe = RegExp(r'<\|[^|]*\|>');

  static String _clean(String s) => s.replaceAll(_tagRe, '').trim();

  void free() {
    vad.free();
    rec.free();
  }
}
