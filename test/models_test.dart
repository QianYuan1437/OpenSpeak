import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/asr_engine.dart';
import 'package:openspeak/core/model_catalog.dart';

import 'asr_engine_test.dart' show readWav;

/// Runs every catalog model found under OS_MODELS_ROOT on the SenseVoice
/// test clips (skips models that are not downloaded). OS_PROVIDER=cuda with
/// OS_LIB_DIR pointing at an installed GPU pack runs them on the GPU;
/// OS_MODEL_ID limits the run to one model.
void main() {
  final root = Platform.environment['OS_MODELS_ROOT'] ?? '';
  final libDir = Platform.environment['OS_LIB_DIR'];
  final provider = Platform.environment['OS_PROVIDER'] ?? 'cpu';
  final only = Platform.environment['OS_MODEL_ID'];
  final clips = '$root/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09/test_wavs';

  for (final m in kModels) {
    final dir = '$root/${m.dir}';
    test(m.id, () async {
      if (only != null && only != m.id) {
        markTestSkipped('OS_MODEL_ID=$only');
        return;
      }
      if (!Directory(dir).existsSync()) {
        markTestSkipped('not downloaded');
        return;
      }
      final engine = AsrEngine();
      final sw = Stopwatch()..start();
      await engine.load(AsrConfig(
        kind: m.kind,
        files: m.files.map((k, v) => MapEntry(k, '$dir/$v')),
        vadModel: 'assets/silero_vad.onnx',
        threads: 4,
        partial: false,
        libDir: libDir,
        provider: provider,
      ));
      final loadMs = sw.elapsedMilliseconds;
      for (final name in ['zh.wav', 'en.wav']) {
        final wav = readWav('$clips/$name');
        engine.begin();
        engine.feed(Float32List.fromList(wav));
        engine.end();
        final fin = await engine.events.firstWhere((e) => e is AsrFinal) as AsrFinal;
        // ignore: avoid_print
        print('${m.id.padRight(20)} load=${loadMs}ms $name audio=${fin.audioMs}ms decode=${fin.decodeMs}ms -> ${fin.text}');
      }
      await engine.dispose();
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
