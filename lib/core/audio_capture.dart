import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

import 'asr_engine.dart' show kSampleRate;

enum ChannelMode { mix, left, right }

/// Captures 16 kHz float audio from the selected input with optional
/// left/right channel pick (dual-TX wireless kits), manual gain and AGC.
class AudioCapture {
  AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final _levels = StreamController<double>.broadcast();
  final _carry = BytesBuilder(copy: false);

  int _channels = 1;
  ChannelMode _mode = ChannelMode.mix;
  double _gain = 1;
  bool _agc = true;
  double _agcGain = 1;
  double _env = 0;

  /// 0..1 loudness for meters, emitted ~10×/s.
  Stream<double> get levels => _levels.stream;
  bool get isRunning => _sub != null;

  Future<bool> ensurePermission() => _rec.hasPermission();

  Future<List<InputDevice>> devices() async {
    try {
      return await _rec.listInputDevices();
    } catch (_) {
      return const [];
    }
  }

  Future<void> start({
    InputDevice? device,
    ChannelMode channel = ChannelMode.mix,
    double gainDb = 0,
    bool agc = true,
    required void Function(Float32List samples) onSamples,
  }) async {
    await stop();
    _mode = channel;
    _gain = math.pow(10, gainDb / 20).toDouble();
    _agc = agc;
    _agcGain = 1;
    _env = 0;
    _carry.clear();
    // Mono lets the OS downmix; stereo only when a single side is wanted.
    _channels = channel == ChannelMode.mix ? 1 : 2;

    final stream = await _startStream(_normalize(device));
    _sub = stream.listen((bytes) {
      final s = _convert(bytes);
      if (s.isNotEmpty) onSamples(s);
    });
  }

  /// record_linux keeps the quotes from `pactl list sources` in the id
  /// (`"alsa_input…"`), which parecord then fails to resolve and silently
  /// records the default source instead.
  static InputDevice? _normalize(InputDevice? d) {
    if (d == null || !Platform.isLinux) return d;
    final id = d.id.replaceAll('"', '').trim();
    return InputDevice(id: id, label: d.label);
  }

  Future<Stream<Uint8List>> _startStream(InputDevice? device) async {
    RecordConfig cfg(int ch) => RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: kSampleRate,
          numChannels: ch,
          device: device,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
          androidConfig: const AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceRecognition,
            manageBluetooth: true,
          ),
        );
    try {
      return await _rec.startStream(cfg(_channels));
    } catch (_) {
      if (_channels == 1) rethrow;
      // Some devices refuse stereo; fall back to mono.
      _channels = 1;
      _rec.dispose();
      _rec = AudioRecorder();
      return _rec.startStream(cfg(1));
    }
  }

  Future<void> stop() async {
    final sub = _sub;
    _sub = null;
    if (sub == null) return;
    await sub.cancel();
    try {
      await _rec.stop();
    } catch (_) {}
  }

  Float32List _convert(Uint8List bytes) {
    _carry.add(bytes);
    final all = _carry.takeBytes();
    final frameBytes = 2 * _channels;
    final frames = all.length ~/ frameBytes;
    final used = frames * frameBytes;
    if (used < all.length) _carry.add(Uint8List.sublistView(all, used));
    if (frames == 0) return Float32List(0);

    final bd = ByteData.sublistView(all, 0, used);
    final out = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      double v;
      if (_channels == 1) {
        v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      } else {
        final l = bd.getInt16(i * 4, Endian.little) / 32768.0;
        final r = bd.getInt16(i * 4 + 2, Endian.little) / 32768.0;
        v = switch (_mode) {
          ChannelMode.left => l,
          ChannelMode.right => r,
          ChannelMode.mix => (l + r) * 0.5,
        };
      }
      out[i] = v;
    }
    _applyGain(out);
    return out;
  }

  /// Manual gain, then a slow-attack AGC that lifts quiet lavalier/wireless
  /// receivers toward a comfortable level without pumping on silence.
  void _applyGain(Float32List s) {
    var peak = 0.0;
    var sum = 0.0;
    for (var i = 0; i < s.length; i++) {
      final v = s[i] * _gain;
      s[i] = v;
      final a = v.abs();
      if (a > peak) peak = a;
    }
    if (_agc) {
      _env = math.max(peak, _env * 0.95);
      if (_env > 0.01) {
        final target = (0.45 / _env).clamp(1.0, 12.0);
        // Fast release (avoid clipping), slow attack (avoid noise pumping).
        _agcGain += (target - _agcGain) * (target < _agcGain ? 0.5 : 0.05);
      }
      for (var i = 0; i < s.length; i++) {
        s[i] = (s[i] * _agcGain).clamp(-1.0, 1.0);
      }
    } else {
      for (var i = 0; i < s.length; i++) {
        s[i] = s[i].clamp(-1.0, 1.0);
      }
    }
    for (final v in s) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / s.length);
    // Map -60..0 dBFS to 0..1.
    final db = 20 * math.log(math.max(rms, 1e-6)) / math.ln10;
    _levels.add(((db + 60) / 60).clamp(0.0, 1.0));
  }

  Future<void> dispose() async {
    await stop();
    _rec.dispose();
    await _levels.close();
  }
}

/// Picks the best device: the saved one if present, else a known creator
/// mic when [preferWireless], else the system default (null).
InputDevice? chooseDevice(List<InputDevice> devices, String? savedId,
    {bool preferWireless = true, int Function(String)? rank}) {
  if (savedId != null) {
    for (final d in devices) {
      if (d.id == savedId) return d;
    }
  }
  if (preferWireless && rank != null && devices.isNotEmpty) {
    final best = devices.reduce((a, b) => rank(a.label) >= rank(b.label) ? a : b);
    if (rank(best.label) >= 3) return best;
  }
  return null;
}

bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
