import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Detects an NVIDIA GPU and manages the optional CUDA runtime pack that lets
/// sherpa-onnx run on the GPU (desktop only).
class GpuManager extends ChangeNotifier {
  String? gpuName;
  String? driverVersion;
  late Directory packDir;

  bool get supported => Platform.isWindows || Platform.isLinux;
  bool get available => gpuName != null;

  /// The GPU build of the sherpa-onnx C API is installed and loadable.
  bool get ready => available && File(p.join(packDir.path, '.complete')).existsSync();

  String? get libDir => ready ? packDir.path : null;

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    packDir = Directory(p.join(support.path, 'gpu'));
    if (!supported) return;
    try {
      final r = await Process.run('nvidia-smi',
          ['--query-gpu=name,driver_version', '--format=csv,noheader']);
      if (r.exitCode == 0) {
        final line = (r.stdout as String).trim().split('\n').first.split(',');
        gpuName = line.first.trim();
        if (line.length > 1) driverVersion = line[1].trim();
      }
    } catch (_) {
      // No NVIDIA driver.
    }
    notifyListeners();
  }
}
