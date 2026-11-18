import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/gpu.dart';

/// Downloads the NVIDIA wheels into OS_GPU_PACK (≈1.2 GB). Opt-in only;
/// OS_GPU_RUNTIME=1 also fetches the sherpa-onnx GPU runtime archive.
void main() {
  final dir = Platform.environment['OS_GPU_PACK'];
  test('installs CUDA libraries from PyPI mirrors', () async {
    if (dir == null) {
      markTestSkipped('set OS_GPU_PACK');
      return;
    }
    final gpu = GpuManager()
      ..gpuName = 'test'
      ..packDir = Directory(dir);
    var last = -1;
    gpu.addListener(() {
      final p = gpu.progress;
      if (p == null) return;
      final pct = ((p.fraction ?? 0) * 100).floor();
      if (pct ~/ 10 != last ~/ 10) {
        last = pct;
        // ignore: avoid_print
        print('${p.stage} $pct% ${p.source} ${DateTime.now().toIso8601String().substring(11, 19)}');
      }
    });
    await gpu.install(includeRuntime: Platform.environment['OS_GPU_RUNTIME'] == '1');
    // ignore: avoid_print
    if (gpu.error != null) print('ERROR: ${gpu.error}');
    expect(gpu.error, isNull);
    // ignore: avoid_print
    print(Directory(dir).listSync().map((e) => e.path.split('/').last).join('\n'));
  }, timeout: const Timeout(Duration(minutes: 60)));
}
