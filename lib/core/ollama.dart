import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' show extractFileToDisk;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'audio_capture.dart' show isDesktop;
import 'model_manager.dart' show DownloadCancelled, DownloadProgress;
import 'settings.dart';

enum OllamaStatus {
  /// Not checked yet.
  unknown,

  /// The API answers.
  running,

  /// Installed on this machine but not serving.
  stopped,

  /// Not installed on this machine.
  missing,

  /// The configured address is another machine and does not answer.
  remote,

  /// Ollama cannot run on this platform (Android): only a LAN address works.
  unsupported,
}

/// Size of the portable package, shown before installing.
int get ollamaPackageBytes => Platform.isWindows ? 1620 * 1000 * 1000 : 1550 * 1000 * 1000;

/// Disk space of the unpacked portable build.
int get ollamaUnpackedBytes => Platform.isWindows ? 2300 * 1000 * 1000 : 2500 * 1000 * 1000;

/// Approximate download size of the recommended model.
const kRecommendedOllamaModel = 'qwen2.5:3b';
const kRecommendedModelBytes = 1930 * 1000 * 1000;
const kOllamaDownloadPage = 'https://ollama.com/download';

/// Finds, starts and installs a local Ollama for the AI correction.
///
/// "Installing" means the official portable build (the same files as the
/// official installer, from ollama.com / GitHub releases) unpacked into a
/// folder the user picked, with its models stored in a `models` subfolder.
/// No administrator rights or system changes are needed.
class OllamaManager extends ChangeNotifier {
  OllamaManager(this.settings) {
    // A download paused (or interrupted) in an earlier session.
    if (settings.ollamaPendingDir.isNotEmpty && Directory(settings.ollamaPendingDir).existsSync()) {
      pendingDir = settings.ollamaPendingDir;
      _pendingModel = settings.ollamaPendingModel.isEmpty ? null : settings.ollamaPendingModel;
    }
  }
  final Settings settings;

  OllamaStatus status = OllamaStatus.unknown;
  String? version;
  List<String> models = [];

  /// The ollama executable that was found (null when missing).
  String? exe;
  bool starting = false;
  String? error;

  /// Install progress (download / extract); null when not installing.
  DownloadProgress? progress;
  bool installing = false;

  /// Folder of an install that was paused, so it can be resumed.
  String? pendingDir;
  String? _pendingModel;
  bool _cancel = false;
  bool _discard = false;

  /// Model being pulled and its progress.
  String? pulling;
  String pullStatus = '';
  int pullCompleted = 0, pullTotal = 0;
  HttpClient? _pullClient;

  /// `http://host:port` of the Ollama API (from the Ollama service URL).
  Uri get apiBase {
    final raw = settings.endpointOf('ollama').baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final u = Uri.tryParse(raw.replaceFirst(RegExp(r'/v1$'), ''));
    if (u == null || u.host.isEmpty) return Uri.parse('http://127.0.0.1:11434');
    return Uri(scheme: u.scheme.isEmpty ? 'http' : u.scheme, host: u.host, port: u.hasPort ? u.port : 11434);
  }

  bool get isLocal => const {'127.0.0.1', 'localhost', '::1', '0.0.0.0'}.contains(apiBase.host);

  /// Installed by OpenSpeak into [Settings.ollamaDir].
  bool get managed => settings.ollamaDir.isNotEmpty && exe == managedExe(settings.ollamaDir);

  bool hasModel(String name) {
    final n = name.trim();
    return models.contains(n) || (!n.contains(':') && models.contains('$n:latest'));
  }

  /// Marks a folder as OpenSpeak's Ollama install; only such folders (or
  /// empty ones) are installed into directly and cleaned up on uninstall.
  static const marker = '.openspeak-ollama';

  /// [dir] can hold the install as is: missing, empty, or ours already.
  static bool usableInstallDir(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return true;
    return d.listSync().isEmpty || File(p.join(dir, marker)).existsSync();
  }

  static String managedExe(String dir) => Platform.isWindows ? p.join(dir, 'ollama.exe') : p.join(dir, 'bin', 'ollama');

  /// Default install folder: per-user, no admin rights needed.
  static String get defaultDir {
    if (Platform.isWindows) {
      final local =
          Platform.environment['LOCALAPPDATA'] ??
          p.join(Platform.environment['USERPROFILE'] ?? 'C:\\', 'AppData', 'Local');
      return p.join(local, 'OpenSpeak', 'Ollama');
    }
    return p.join(Platform.environment['HOME'] ?? '/tmp', '.local', 'share', 'openspeak', 'ollama');
  }

  // Detection -------------------------------------------------------------------

  Future<String?> _version() async {
    final c = _client()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await c.getUrl(apiBase.replace(path: '/api/version'));
      final res = await req.close().timeout(const Duration(seconds: 3));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      return (jsonDecode(body) as Map)['version'] as String? ?? '?';
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  Future<List<String>> _tags() async {
    final c = _client();
    try {
      final req = await c.getUrl(apiBase.replace(path: '/api/tags'));
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body = await res.transform(utf8.decoder).join();
      return [for (final m in (jsonDecode(body) as Map)['models'] as List? ?? const []) (m as Map)['name'] as String]
        ..sort();
    } catch (_) {
      return [];
    } finally {
      c.close(force: true);
    }
  }

  /// Looks for an ollama executable: OpenSpeak's own install, the official
  /// installer's locations, then PATH.
  Future<String?> findExe() async {
    final env = Platform.environment;
    final candidates = [
      if (settings.ollamaDir.isNotEmpty) managedExe(settings.ollamaDir),
      if (Platform.isWindows) ...[
        if (env['LOCALAPPDATA'] != null) p.join(env['LOCALAPPDATA']!, 'Programs', 'Ollama', 'ollama.exe'),
        if (env['ProgramFiles'] != null) p.join(env['ProgramFiles']!, 'Ollama', 'ollama.exe'),
      ] else ...[
        '/usr/local/bin/ollama',
        '/usr/bin/ollama',
        if (env['HOME'] != null) p.join(env['HOME']!, '.local', 'bin', 'ollama'),
      ],
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['ollama']);
      final first = r.stdout
          .toString()
          .split(RegExp(r'[\r\n]+'))
          .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      if (r.exitCode == 0 && first.isNotEmpty) return first.trim();
    } catch (_) {}
    return null;
  }

  Future<void> refresh() async {
    final v = await _version();
    if (v != null) {
      version = v;
      models = await _tags();
      status = OllamaStatus.running;
    } else if (!isDesktop) {
      status = isLocal ? OllamaStatus.unsupported : OllamaStatus.remote;
    } else if (!isLocal) {
      status = OllamaStatus.remote;
    }
    if (isDesktop) {
      exe = await findExe();
      if (v == null && isLocal) status = exe == null ? OllamaStatus.missing : OllamaStatus.stopped;
    }
    notifyListeners();
  }

  // Start -----------------------------------------------------------------------

  Completer<bool>? _ensuring;

  /// True when the API answers, starting an installed Ollama if the user
  /// allows it.
  Future<bool> ensureRunning() async {
    if (_ensuring != null) return _ensuring!.future;
    final done = _ensuring = Completer<bool>();
    try {
      await refresh();
      if (status == OllamaStatus.stopped && settings.ollamaAutoStart) await start();
      done.complete(status == OllamaStatus.running);
    } catch (_) {
      done.complete(false);
    } finally {
      _ensuring = null;
    }
    return done.future;
  }

  /// Runs `ollama serve` in the background (it keeps running after OpenSpeak
  /// exits, like the official app) and waits for the API.
  Future<bool> start() async {
    final path = exe ?? await findExe();
    if (path == null || starting) return false;
    exe = path;
    starting = true;
    error = null;
    notifyListeners();
    try {
      final env = <String, String>{
        if (managed) 'OLLAMA_MODELS': p.join(settings.ollamaDir, 'models'),
        if (apiBase.port != 11434) 'OLLAMA_HOST': '127.0.0.1:${apiBase.port}',
      };
      await Process.start(
        path,
        ['serve'],
        mode: ProcessStartMode.detached,
        environment: env,
        workingDirectory: p.dirname(path),
      );
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (await _version() != null) {
          await refresh();
          return true;
        }
      }
      error = 'Ollama 启动超时 / Ollama did not start';
      return false;
    } catch (e) {
      error = '无法启动 Ollama / Cannot start Ollama: $e';
      return false;
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  // Install ---------------------------------------------------------------------

  String get _archiveName => Platform.isWindows ? 'ollama-windows-amd64.zip' : 'ollama-linux-amd64.tar.zst';

  /// Official download first; on Linux ModelScope's mirror of the same
  /// package if GitHub is too slow (common in mainland China).
  List<Uri> get _sources => [
    Uri.parse('https://ollama.com/download/$_archiveName'),
    if (Platform.isLinux)
      Uri.parse('https://modelscope.cn/models/modelscope/ollama-linux/resolve/master/$_archiveName'),
  ];

  /// Bytes of a paused install already on disk.
  int get partialBytes {
    final dir = pendingDir;
    if (dir == null) return 0;
    var n = 0;
    for (final u in _sources) {
      final f = File(_partPath(dir, u));
      if (f.existsSync()) n = n > f.lengthSync() ? n : f.lengthSync();
    }
    return n;
  }

  String _partPath(String dir, Uri source) => p.join(dir, '$_archiveName.${source.host}.part');

  void pause() => _cancel = true;

  Future<void> cancel() async {
    if (installing) {
      _discard = true;
      _cancel = true;
      return;
    }
    await _deleteParts();
    await _setPending(null);
    notifyListeners();
  }

  Future<void> _setPending(String? dir, [String? model]) async {
    pendingDir = dir;
    _pendingModel = model;
    await settings.update((s) {
      s.ollamaPendingDir = dir ?? '';
      s.ollamaPendingModel = model ?? '';
    });
  }

  Future<void> _deleteParts() async {
    final dir = pendingDir;
    if (dir == null) return;
    for (final u in _sources) {
      final f = File(_partPath(dir, u));
      if (await f.exists()) await f.delete();
    }
  }

  /// Downloads and unpacks Ollama into [dir], starts it and (optionally)
  /// pulls [model]. Resumable: calling it again continues a paused download.
  Future<void> install(String dir, {String? model}) async {
    if (installing) return;
    installing = true;
    await _setPending(dir, model);
    _cancel = false;
    _discard = false;
    error = null;
    progress = DownloadProgress(partialBytes, ollamaPackageBytes, 'download');
    notifyListeners();
    try {
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, marker)).writeAsString('Ollama installed by OpenSpeak\n');
      final archive = File(p.join(dir, _archiveName));
      await _download(dir, archive);
      progress = const DownloadProgress(0, 0, 'extract');
      notifyListeners();
      await _extract(archive.path, dir);
      await archive.delete();
      final path = managedExe(dir);
      if (!await File(path).exists()) throw Exception('ollama not found after unpacking');
      if (!Platform.isWindows) await Process.run('chmod', ['+x', path]);
      await settings.update((s) => s.ollamaDir = dir);
      exe = path;
      await _setPending(null);
      installing = false;
      progress = null;
      notifyListeners();
      if (await start() && model != null) await pull(model);
    } on DownloadCancelled {
      if (_discard) {
        await _deleteParts();
        await _setPending(null);
      }
    } catch (e) {
      error = '安装失败 / Install failed: $e';
    } finally {
      installing = false;
      progress = null;
      notifyListeners();
    }
  }

  /// Continues a paused install with the same options.
  Future<void> resume() async {
    if (pendingDir != null) await install(pendingDir!, model: _pendingModel);
  }

  Future<void> _download(String dir, File dest) async {
    if (await dest.exists()) return;
    Object? lastError;
    final sources = _sources;
    for (final strict in [true, false]) {
      for (final url in sources) {
        try {
          await _fetch(url, File(_partPath(dir, url)), minRate: strict && sources.length > 1 ? 1024 * 1024 : 0);
          await File(_partPath(dir, url)).rename(dest.path);
          await _deleteParts(); // other mirrors' leftovers
          return;
        } on DownloadCancelled {
          rethrow;
        } catch (e) {
          lastError = e;
        }
      }
    }
    throw lastError!;
  }

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..findProxy = HttpClient.findProxyFromEnvironment
    ..userAgent = 'OpenSpeak';

  /// Resumable GET into [part]; redirects are followed by hand so the Range
  /// header survives the hop to GitHub's CDN.
  Future<void> _fetch(Uri url, File part, {int minRate = 0}) async {
    var have = await part.exists() ? await part.length() : 0;
    final c = _client();
    try {
      var u = url;
      HttpClientResponse? res;
      for (var i = 0; i < 8; i++) {
        final req = await c.getUrl(u);
        req.followRedirects = false;
        if (have > 0) req.headers.set('Range', 'bytes=$have-');
        final r = await req.close().timeout(const Duration(seconds: 20));
        if (r.isRedirect) {
          final loc = r.headers.value(HttpHeaders.locationHeader);
          await r.drain<void>();
          if (loc == null) break;
          u = u.resolve(loc);
          continue;
        }
        res = r;
        break;
      }
      if (res == null) throw HttpException('too many redirects', uri: url);
      if (res.statusCode == 416) {
        await res.drain<void>();
        return;
      }
      if (res.statusCode >= 400) {
        await res.drain<void>();
        throw HttpException('HTTP ${res.statusCode}', uri: url);
      }
      if (res.statusCode != 206) have = 0;
      final total = res.contentLength > 0 ? have + res.contentLength : ollamaPackageBytes;
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var got = have;
      var last = DateTime.now();
      var windowStart = last;
      var windowBytes = got;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 30))) {
          if (_cancel) throw DownloadCancelled();
          sink.add(chunk);
          got += chunk.length;
          final now = DateTime.now();
          if (now.difference(last).inMilliseconds > 250) {
            last = now;
            progress = DownloadProgress(got, total, 'download', source: url.host);
            notifyListeners();
          }
          if (now.difference(windowStart) >= const Duration(seconds: 12)) {
            final rate = (got - windowBytes) / now.difference(windowStart).inSeconds;
            if (rate < minRate) throw Exception('${url.host} too slow');
            (windowStart, windowBytes) = (now, got);
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      c.close(force: true);
    }
  }

  /// System tar is much faster (Windows 10+ ships bsdtar, which reads zip);
  /// the Dart decoder is the fallback (e.g. no zstd binary on Linux).
  static Future<void> _extract(String archive, String dest) async {
    final args = archive.endsWith('.zip') ? ['-xf', archive, '-C', dest] : ['--zstd', '-xf', archive, '-C', dest];
    try {
      final r = await Process.run('tar', args);
      if (r.exitCode == 0) return;
    } catch (_) {}
    await Isolate.run(() => extractFileToDisk(archive, dest));
  }

  /// Stops Ollama and deletes OpenSpeak's install (program and models).
  Future<void> uninstall() async {
    final dir = settings.ollamaDir;
    if (dir.isEmpty) return;
    error = null;
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/IM', 'ollama.exe']);
      } else {
        await Process.run('pkill', ['-f', managedExe(dir)]);
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      await removeInstall(dir);
      await settings.update((s) => s.ollamaDir = '');
    } catch (e) {
      error = '卸载失败 / Uninstall failed: $e';
    }
    await refresh();
  }

  /// Deletes only what the install put into [dir] (program, libraries,
  /// models, downloads, marker), then [dir] itself if nothing else is left.
  static Future<void> removeInstall(String dir) async {
    final names = [
      if (Platform.isWindows) 'ollama.exe' else p.join('bin', 'ollama'),
      p.join('lib', 'ollama'),
      'models',
      marker,
      'ollama-windows-amd64.zip',
      'ollama-linux-amd64.tar.zst',
    ];
    for (final n in names) {
      final path = p.join(dir, n);
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        await File(path).delete();
      }
    }
    final d = Directory(dir);
    if (!await d.exists()) return;
    await for (final e in d.list()) {
      if (p.basename(e.path).startsWith('ollama-') && p.basename(e.path).endsWith('.part')) await e.delete();
    }
    // bin/ and lib/ only if they are now empty; then the folder likewise.
    for (final sub in ['bin', 'lib', '']) {
      final s = Directory(p.join(dir, sub));
      if (await s.exists() && await s.list().isEmpty) await s.delete();
    }
  }

  // Models ----------------------------------------------------------------------

  /// Downloads [model] through the running Ollama (`/api/pull`, resumable).
  Future<bool> pull(String model) async {
    if (pulling != null) return false;
    pulling = model;
    pullStatus = '';
    pullCompleted = pullTotal = 0;
    error = null;
    notifyListeners();
    final c = _pullClient = _client();
    var last = DateTime(0);
    try {
      final req = await c.postUrl(apiBase.replace(path: '/api/pull'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'model': model, 'stream': true}));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}: ${await res.transform(utf8.decoder).join()}');
      }
      await for (final line in res.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final j = jsonDecode(line) as Map;
        if (j['error'] != null) throw Exception(j['error']);
        pullStatus = '${j['status'] ?? ''}';
        if (j['total'] is int) {
          pullTotal = j['total'] as int;
          pullCompleted = j['completed'] as int? ?? 0;
        }
        final now = DateTime.now();
        if (now.difference(last).inMilliseconds > 250) {
          last = now;
          notifyListeners();
        }
      }
      models = await _tags();
      return hasModel(model);
    } catch (e) {
      if (_pullClient != null) error = '模型下载失败 / Model download failed: $e';
      return false;
    } finally {
      _pullClient = null;
      c.close(force: true);
      pulling = null;
      notifyListeners();
    }
  }

  /// Stops a model download; Ollama keeps the part for next time.
  void cancelPull() {
    final c = _pullClient;
    _pullClient = null;
    c?.close(force: true);
  }

  /// Free bytes on the drive that would hold [dir] (null if unknown).
  static Future<int?> freeBytes(String dir) async {
    var d = Directory(dir);
    while (!d.existsSync() && d.parent.path != d.path) {
      d = d.parent;
    }
    try {
      if (Platform.isWindows) {
        final path = d.path.replaceAll("'", "''");
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "(Get-Item -LiteralPath '$path').PSDrive.Free",
        ]);
        return int.tryParse(r.stdout.toString().trim());
      }
      final r = await Process.run('df', ['-B1', '--output=avail', d.path]);
      final lines = r.stdout.toString().trim().split('\n');
      return lines.length > 1 ? int.tryParse(lines.last.trim()) : null;
    } catch (_) {
      return null;
    }
  }
}
