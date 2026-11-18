import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_manager.dart' show DownloadCancelled, DownloadProgress;

/// One NVIDIA runtime component taken from its PyPI wheel.
class _Wheel {
  const _Wheel(this.package, this.major, this.dir, this.pattern);
  final String package;
  final int major;

  /// Directory inside the wheel holding the libraries.
  final String dir;
  final RegExp pattern;
}

/// Detects an NVIDIA GPU and installs the optional CUDA pack that lets
/// sherpa-onnx run on the GPU (Windows/Linux x64):
///
/// * the CUDA build of the sherpa-onnx C API + onnxruntime, repackaged by
///   this repo's `gpu-runtime` workflow, and
/// * CUDA runtime / cuBLAS / cuFFT / cuDNN libraries from NVIDIA's PyPI
///   wheels (PyPI mirrors are much faster than GitHub in mainland China).
class GpuManager extends ChangeNotifier {
  static const sherpaVersion = '2.0.1';
  static const _repo = 'https://github.com/QianYuan1437/OpenSpeak';
  static const _mirrors = [
    'https://mirrors.aliyun.com/pypi',
    'https://pypi.tuna.tsinghua.edu.cn',
    'https://pypi.org',
  ];

  String? gpuName;
  String? driverVersion;
  late Directory packDir;
  DownloadProgress? progress;
  String? error;
  bool _cancel = false;

  /// Set when the CPU libraries were loaded in this process; switching to the
  /// GPU build then needs a restart (same DLL names).
  static bool cpuLibLoaded = false;

  bool get supported => Platform.isWindows || Platform.isLinux;
  bool get available => gpuName != null;
  bool get busy => progress != null;

  /// The GPU pack is installed.
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

  List<_Wheel> get _wheels => Platform.isWindows
      ? [
          _Wheel('nvidia-cuda-runtime-cu12', 12, 'nvidia/cuda_runtime/bin/', RegExp(r'cudart64_12\.dll$')),
          _Wheel('nvidia-cublas-cu12', 12, 'nvidia/cublas/bin/', RegExp(r'cublas(Lt)?64_12\.dll$')),
          _Wheel('nvidia-cufft-cu12', 11, 'nvidia/cufft/bin/', RegExp(r'cufft64_11\.dll$')),
          _Wheel('nvidia-cudnn-cu12', 9, 'nvidia/cudnn/bin/', RegExp(r'cudnn[a-z_]*64_9\.dll$')),
        ]
      : [
          _Wheel('nvidia-cuda-runtime-cu12', 12, 'nvidia/cuda_runtime/lib/', RegExp(r'libcudart\.so\.12$')),
          _Wheel('nvidia-cublas-cu12', 12, 'nvidia/cublas/lib/', RegExp(r'libcublas(Lt)?\.so\.12$')),
          _Wheel('nvidia-cufft-cu12', 11, 'nvidia/cufft/lib/', RegExp(r'libcufft\.so\.11$')),
          _Wheel('nvidia-cudnn-cu12', 9, 'nvidia/cudnn/lib/', RegExp(r'libcudnn[a-z_]*\.so\.9$')),
        ];

  String get _platformTag => Platform.isWindows ? 'win_amd64' : 'manylinux';

  void cancel() => _cancel = true;

  Future<void> uninstall() async {
    if (await packDir.exists()) await packDir.delete(recursive: true);
    notifyListeners();
  }

  /// [includeRuntime] = false skips the sherpa-onnx GPU archive (tests).
  Future<void> install({bool includeRuntime = true}) async {
    if (busy) return;
    _cancel = false;
    error = null;
    final tmp = Directory(p.join(packDir.parent.path, 'gpu-download'));
    try {
      await packDir.create(recursive: true);
      await tmp.create(recursive: true);
      final marker = File(p.join(packDir.path, '.complete'));
      if (await marker.exists()) await marker.delete();

      // Resolve every download first so progress covers the whole pack.
      final jobs = <(Uri, String?, String, Future<void> Function(String))>[];
      final os = Platform.isWindows ? 'windows' : 'linux';
      final runtime = 'openspeak-gpu-$os-x64.zip';
      if (includeRuntime) {
        jobs.add((
          Uri.parse('$_repo/releases/download/gpu-runtime-$sherpaVersion/$runtime'),
          null,
          runtime,
          (file) => _extract(file, (name) => !name.endsWith('/'), flatten: true),
        ));
      }
      for (final w in _wheels) {
        final (url, hash) = await _findWheel(w);
        jobs.add((
          url,
          hash,
          Uri.decodeComponent(p.basename(url.path)),
          (file) => _extract(file, (name) => name.startsWith(w.dir) && w.pattern.hasMatch(name),
              flatten: true),
        ));
      }
      final sizes = <int>[];
      for (final j in jobs) {
        sizes.add(await _length(j.$1));
      }
      final total = sizes.fold<int>(0, (a, b) => a + b);
      var done = 0;
      for (var i = 0; i < jobs.length; i++) {
        final (url, hash, name, extract) = jobs[i];
        final dest = File(p.join(tmp.path, name));
        await _fetch(url, dest, (got) {
          progress = DownloadProgress(done + got, total, 'download', source: url.host);
          notifyListeners();
        });
        if (hash != null) await _verify(dest, hash);
        progress = DownloadProgress(done + sizes[i], total, 'extract', source: name);
        notifyListeners();
        await extract(dest.path);
        await dest.delete();
        done += sizes[i];
      }
      await File(p.join(packDir.path, '.complete')).writeAsString('sherpa-onnx $sherpaVersion\n');
    } on DownloadCancelled {
      // Keep partial downloads for resume.
    } catch (e) {
      error = '$e';
    } finally {
      progress = null;
      notifyListeners();
    }
  }

  /// Picks the newest wheel of the required major version from the first
  /// mirror that answers. Returns its URL and sha256.
  Future<(Uri, String?)> _findWheel(_Wheel w) async {
    final failures = <String>[];
    for (final m in _mirrors) {
      try {
        final index = Uri.parse('$m/simple/${w.package}/');
        final html = await _getText(index);
        final re = RegExp(r'href="([^"]+/([^/"#]+\.whl))(?:#sha256=([0-9a-f]+))?"');
        Uri? best;
        String? bestHash;
        List<int>? bestVer;
        for (final mt in re.allMatches(html)) {
          final file = mt.group(2)!;
          if (!file.contains(_platformTag) || !file.contains('x86_64') && !file.contains('amd64')) {
            continue;
          }
          final ver = file.split('-')[1].split('.').map((e) => int.tryParse(e) ?? 0).toList();
          if (ver.first != w.major) continue;
          if (bestVer == null || _cmp(ver, bestVer) > 0) {
            bestVer = ver;
            best = index.resolve(mt.group(1)!);
            bestHash = mt.group(3);
          }
        }
        if (best != null) return (best, bestHash);
        failures.add('$m: no wheel');
      } catch (e) {
        failures.add('$m: $e');
      }
    }
    throw Exception('${w.package}: ${failures.join('; ')}');
  }

  static int _cmp(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  Future<void> _extract(String file, bool Function(String name) want, {bool flatten = false}) async {
    final out = packDir.path;
    await Isolate.run(() async {
      final input = InputFileStream(file);
      try {
        final zip = ZipDecoder().decodeStream(input);
        for (final f in zip.files) {
          if (!f.isFile || !want(f.name)) continue;
          final dest = p.join(out, flatten ? p.basename(f.name) : f.name);
          final os = OutputFileStream(dest);
          f.writeContent(os);
          await os.close();
        }
      } finally {
        await input.close();
      }
    });
  }

  static Future<void> _verify(File f, String expected) async {
    final digest = await sha256.bind(f.openRead()).first;
    if (digest.toString() != expected) {
      await f.delete();
      throw Exception('checksum mismatch: ${p.basename(f.path)}');
    }
  }

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..findProxy = HttpClient.findProxyFromEnvironment
    ..userAgent = 'OpenSpeak';

  Future<String> _getText(Uri url) async {
    final c = _client();
    try {
      final req = await c.getUrl(url);
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode}', uri: url);
      return await res.transform(const SystemEncoding().decoder).join();
    } finally {
      c.close(force: true);
    }
  }

  Future<int> _length(Uri url) async {
    final c = _client();
    try {
      final req = await c.headUrl(url);
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode}', uri: url);
      return res.contentLength;
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _fetch(Uri url, File dest, void Function(int) onBytes) async {
    final part = File('${dest.path}.part');
    var have = await part.exists() ? await part.length() : 0;
    final c = _client();
    try {
      final req = await c.getUrl(url);
      if (have > 0) req.headers.set('Range', 'bytes=$have-');
      final res = await req.close();
      if (res.statusCode == 416) {
        await res.drain<void>();
      } else {
        if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode}', uri: url);
        if (res.statusCode != 206) have = 0;
        final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
        var got = have;
        var last = DateTime.now();
        try {
          await for (final chunk in res.timeout(const Duration(seconds: 30))) {
            if (_cancel) throw DownloadCancelled();
            sink.add(chunk);
            got += chunk.length;
            if (DateTime.now().difference(last).inMilliseconds > 250) {
              last = DateTime.now();
              onBytes(got);
            }
          }
        } finally {
          await sink.close();
        }
      }
      await part.rename(dest.path);
    } finally {
      c.close(force: true);
    }
  }
}
