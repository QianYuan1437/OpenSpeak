import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/asr_engine.dart';
import 'package:openspeak/core/model_catalog.dart';

import 'asr_engine_test.dart' show readWav;

/// Switches between two GPU models a few times on one engine and checks that
/// this process's GPU memory does not keep growing (old recognizers must be
/// freed). Opt-in: OS_MODELS_ROOT + OS_LIB_DIR (GPU pack) on an NVIDIA box.
void main() {
  final root = Platform.environment['OS_MODELS_ROOT'];
  final libDir = Platform.environment['OS_LIB_DIR'];

  Future<int> vramMiB() async {
    final r = await Process.run('nvidia-smi', ['--query-compute-apps=pid,used_memory', '--format=csv,noheader,nounits']);
    for (final line in (r.stdout as String).split('\n')) {
      final f = line.split(',');
      if (f.length == 2 && int.tryParse(f[0].trim()) == pid) return int.parse(f[1].trim());
    }
    return 0;
  }

  test('switching GPU models releases the previous one', () async {
    if (root == null || libDir == null) {
      markTestSkipped('set OS_MODELS_ROOT and OS_LIB_DIR');
      return;
    }
    final a = modelById('fire-red-asr2-ctc')!, b = modelById('qwen3-asr-0.6b')!;
    final wav = Float32List.fromList(readWav('$root/${kModels.first.dir}/test_wavs/zh.wav'));
    final engine = AsrEngine();
    final usage = <int>[];
    for (final m in [a, b, a, b, a, b]) {
      await engine.load(AsrConfig(
        kind: m.kind,
        files: m.files.map((k, v) => MapEntry(k, '$root/${m.dir}/$v')),
        vadModel: 'assets/silero_vad.onnx',
        provider: 'cuda',
        partial: false,
        libDir: libDir,
      ));
      engine.begin();
      engine.feed(wav);
      engine.end();
      await engine.events.firstWhere((e) => e is AsrFinal);
      usage.add(await vramMiB());
    }
    await engine.dispose();
    // ignore: avoid_print
    print('VRAM after each load (MiB): $usage');
    // Same model, later round: no more than a little allocator noise.
    expect(usage[4] - usage[0], lessThan(150));
    expect(usage[5] - usage[1], lessThan(150));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
