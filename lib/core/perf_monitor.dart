import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'gpu.dart';

/// Samples OpenSpeak's own resource use for the performance card: process
/// CPU and memory, and NVIDIA GPU load/memory. Sampling only runs while a
/// listener is attached, so a hidden card costs nothing.
class PerfMonitor extends ChangeNotifier {
  PerfMonitor(this.gpu);

  final GpuManager gpu;

  /// Share of the whole machine (all cores), like Task Manager.
  double? cpuPercent;
  int? rssBytes;
  int? gpuUtil;
  int? gpuMemUsedMB;
  int? gpuMemTotalMB;

  Timer? _timer;
  int _ticks = 0;
  Duration? _lastCpu;
  DateTime? _lastWall;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_timer == null) {
      _sample();
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sample());
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
      _lastCpu = null;
    }
  }

  Future<void> _sample() async {
    // Nothing to show while the window is hidden in the tray.
    final life = SchedulerBinding.instance.lifecycleState;
    if (life == AppLifecycleState.hidden || life == AppLifecycleState.paused) {
      _lastCpu = null;
      return;
    }
    rssBytes = ProcessInfo.currentRss;
    final cpu = _processCpuTime();
    final now = DateTime.now();
    if (cpu != null && _lastCpu != null && _lastWall != null) {
      final wall = now.difference(_lastWall!).inMicroseconds;
      if (wall > 0) {
        cpuPercent = (cpu - _lastCpu!).inMicroseconds / wall / Platform.numberOfProcessors * 100;
      }
    }
    _lastCpu = cpu;
    _lastWall = now;
    // nvidia-smi is a separate process; poll it less often.
    if (gpu.available && _ticks++ % 2 == 0) await _sampleGpu();
    notifyListeners();
  }

  Future<void> _sampleGpu() async {
    try {
      final r = await Process.run('nvidia-smi',
          ['--query-gpu=utilization.gpu,memory.used,memory.total', '--format=csv,noheader,nounits']);
      if (r.exitCode != 0) return;
      final f = (r.stdout as String).trim().split('\n').first.split(',').map((e) => int.tryParse(e.trim())).toList();
      if (f.length < 3) return;
      gpuUtil = f[0];
      gpuMemUsedMB = f[1];
      gpuMemTotalMB = f[2];
    } catch (_) {
      // Driver gone or nvidia-smi missing; keep the last values.
    }
  }

  /// User + kernel CPU time of this process (all threads, incl. the
  /// recognizer isolate).
  static Duration? _processCpuTime() {
    try {
      if (Platform.isWindows) return _windowsCpuTime();
      // Linux / Android: utime and stime (fields 14 and 15) in clock ticks.
      final stat = File('/proc/self/stat').readAsStringSync();
      final f = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      final ticks = int.parse(f[11]) + int.parse(f[12]);
      return Duration(milliseconds: ticks * 10); // USER_HZ = 100
    } catch (_) {
      return null;
    }
  }

  static final _getProcessTimes = Platform.isWindows
      ? DynamicLibrary.open('kernel32.dll').lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
          int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>('GetProcessTimes')
      : null;

  static Duration? _windowsCpuTime() {
    final t = calloc<Uint64>(4);
    try {
      // -1 is the GetCurrentProcess() pseudo handle; FILETIMEs are 100 ns.
      if (_getProcessTimes!(-1, t, t + 1, t + 2, t + 3) == 0) return null;
      return Duration(microseconds: (t[2] + t[3]) ~/ 10);
    } finally {
      calloc.free(t);
    }
  }
}
