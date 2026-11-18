import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/asr_engine.dart';
import 'package:openspeak/core/model_catalog.dart';

/// Reads a 16 kHz mono 16-bit WAV file into floats.
Float32List readWav(String path) {
  final b = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(b);
  var off = 12;
  while (off < b.length - 8) {
    final id = String.fromCharCodes(b.sublist(off, off + 4));
    final size = bd.getUint32(off + 4, Endian.little);
    if (id == 'data') {
      final n = size ~/ 2;
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = bd.getInt16(off + 8 + i * 2, Endian.little) / 32768.0;
      }
      return out;
    }
    off += 8 + size;
  }
  throw 'no data chunk';
}

void main() {
  final modelDir = Platform.environment['OS_MODEL_DIR'];
  final libDir = Platform.environment['OS_LIB_DIR'];

  test('streams a wav through VAD + SenseVoice', () async {
    final engine = AsrEngine();
    await engine.load(AsrConfig(
      kind: ModelKind.senseVoice,
      files: {'model': '$modelDir/model.int8.onnx', 'tokens': '$modelDir/tokens.txt'},
      vadModel: 'assets/silero_vad.onnx',
      threads: 4,
      libDir: libDir,
    ));
    for (final name in ['zh.wav', 'en.wav']) {
      final wav = readWav('$modelDir/test_wavs/$name');
      final events = <AsrEvent>[];
      final sub = engine.events.listen(events.add);
      engine.begin();
      for (var i = 0; i < wav.length; i += 1600) {
        engine.feed(Float32List.fromList(wav.sublist(i, (i + 1600).clamp(0, wav.length))));
        await Future.delayed(const Duration(milliseconds: 5));
      }
      engine.end();
      final fin = await engine.events.firstWhere((e) => e is AsrFinal) as AsrFinal;
      await sub.cancel();
      // ignore: avoid_print
      print('$name partials=${events.whereType<AsrPartial>().length} segments=${events.whereType<AsrSegment>().length} '
          'audio=${fin.audioMs}ms decode=${fin.decodeMs}ms -> ${fin.text}');
      expect(fin.text, isNotEmpty);
    }
    await engine.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
