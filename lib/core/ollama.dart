import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' show extractFileToDisk;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audio_capture.dart' show isDesktop;
import 'model_manager.dart' show DownloadCancelled, DownloadProgress;
import 'net.dart';
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

  /// Where the program can come from, in order: the official portable build
  /// (ollama.com → GitHub), then a mirror in mainland China when GitHub is
  /// slow or unreachable. Every file is verified before use.
  List<_ProgramSource> get _sources => Platform.isWindows
      ? [
          _ProgramSource(Uri.parse('https://ollama.com/download/ollama-windows-amd64.zip'), 'ollama-windows-amd64.zip'),
          // No mirror carries the zip; this is the official signed installer
          // (re-hosted on ModelScope), accepted only with Ollama's signature.
          _ProgramSource(
            Uri.parse('https://modelscope.cn/models/Liangdi/ollama-windows-release/resolve/master/OllamaSetup.exe'),
            'OllamaSetup.exe',
            installer: true,
          ),
        ]
      : [
          _ProgramSource(
            Uri.parse('https://ollama.com/download/ollama-linux-amd64.tar.zst'),
            'ollama-linux-amd64.tar.zst',
          ),
          _ProgramSource(
            Uri.parse('https://modelscope.cn/models/modelscope/ollama-linux/resolve/master/ollama-linux-amd64.tar.zst'),
            'ollama-linux-amd64.tar.zst',
            modelScopeRepo: 'modelscope/ollama-linux',
          ),
        ];

  /// Bytes of a paused install already on disk.
  int get partialBytes {
    final dir = pendingDir;
    if (dir == null) return 0;
    var n = 0;
    for (final s in _sources) {
      final f = File(_partPath(dir, s.file, s.url));
      if (f.existsSync()) n = n > f.lengthSync() ? n : f.lengthSync();
    }
    return n;
  }

  static String _partPath(String dir, String file, Uri source) => p.join(dir, '$file.${source.host}.part');

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
    for (final s in _sources) {
      final f = File(_partPath(dir, s.file, s.url));
      if (await f.exists()) await f.delete();
    }
  }

  /// Downloads and installs Ollama into [dir], starts it and (optionally)
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
      final sources = _sources;
      final (used, chain) = await _downloadAny(
        [for (final s in sources) s.url],
        dir,
        (u) => sources.firstWhere((s) => s.url == u).file,
        onProgress: (host, got, total) {
          progress = DownloadProgress(got, total > 0 ? total : ollamaPackageBytes, 'download', source: host);
          notifyListeners();
        },
        cancelled: () => _cancel,
      );
      final src = sources.firstWhere((s) => s.url == used);
      final file = File(p.join(dir, src.file));
      progress = const DownloadProgress(0, 0, 'extract');
      notifyListeners();
      try {
        await _verifyProgram(src, file, chain);
        if (src.installer) {
          await _runInstaller(file, dir);
        } else {
          await _extract(file.path, dir);
        }
      } finally {
        if (await file.exists()) await file.delete();
      }
      final path = managedExe(dir);
      if (!await File(path).exists()) throw Exception('ollama not found after installing');
      if (!Platform.isWindows) await Process.run('chmod', ['+x', path]);
      await settings.update((s) => s.ollamaDir = dir);
      exe = path;
      await _setPending(null);
      installing = false;
      progress = null;
      notifyListeners();
      // The Windows installer may already have started Ollama.
      var up = await _version() != null;
      if (up) {
        await refresh();
      } else {
        up = await start();
      }
      if (up && model != null) await pull(model);
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

  /// Official files are checked against the release's sha256sum.txt,
  /// ModelScope files against ModelScope's listing, and the Windows
  /// installer by its Authenticode signature (it must be Ollama's).
  Future<void> _verifyProgram(_ProgramSource src, File file, List<Uri> chain) async {
    if (src.installer) {
      final path = file.path.replaceAll("'", "''");
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "\$s = Get-AuthenticodeSignature -LiteralPath '$path'; \"\$(\$s.Status)|\$(\$s.SignerCertificate.Subject)\"",
      ]);
      final out = r.stdout.toString().trim();
      if (!out.startsWith('Valid|') || !out.toLowerCase().contains('ollama')) {
        throw Exception('安装包签名校验未通过 / installer signature check failed ($out)');
      }
      return;
    }
    String? expected;
    try {
      if (src.modelScopeRepo != null) {
        expected = await _modelScopeSha256(src.modelScopeRepo!, src.file);
      } else {
        // ollama.com → github.com/…/releases/latest/download/<file> →
        // …/releases/download/<tag>/<file>: the tagged URL pins the release.
        final release = chain.lastWhere((u) => u.host == 'github.com' && u.path.contains('/download/'));
        final sums = await _getText(release.resolve('sha256sum.txt'));
        for (final line in sums.split('\n')) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length == 2 && p.basename(parts[1]) == src.file) expected = parts[0];
        }
      }
    } catch (_) {
      // Checksum list unreachable: the download itself came over HTTPS from
      // the publisher, so carry on.
    }
    if (expected == null) return;
    final actual = await _sha256(file);
    if (actual != expected.toLowerCase()) {
      throw Exception('文件校验失败，已删除，请重试 / checksum mismatch, file deleted — try again');
    }
  }

  Future<String?> _modelScopeSha256(String repo, String file) async {
    final body = await _getText(Uri.parse('https://www.modelscope.cn/api/v1/models/$repo/repo/files?Revision=master'));
    for (final f in ((jsonDecode(body) as Map)['Data'] as Map)['Files'] as List) {
      if ((f as Map)['Name'] == file) return (f['Sha256'] as String?)?.toLowerCase();
    }
    return null;
  }

  /// Runs the official installer silently into [dir] with the models kept
  /// there too (also for the Ollama app that starts at sign-in).
  Future<void> _runInstaller(File setup, String dir) async {
    final models = p.join(dir, 'models');
    progress = const DownloadProgress(0, 0, 'install');
    notifyListeners();
    final r = await Process.run(
      setup.path,
      ['/DIR=$dir', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'],
      environment: {'OLLAMA_MODELS': models},
    );
    if (r.exitCode != 0) throw Exception('installer exit code ${r.exitCode}');
    await Process.run('setx', ['OLLAMA_MODELS', models]);
  }

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..findProxy = proxyFor
    ..userAgent = 'OpenSpeak';

  Future<String> _getText(Uri url) async {
    final c = _client();
    try {
      final req = await c.getUrl(url);
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode}', uri: url);
      return body;
    } finally {
      c.close(force: true);
    }
  }

  static Future<String> _sha256(File f) async => (await sha256.bind(f.openRead()).first).toString();

  /// Downloads from the first source that is fast enough into
  /// `dir/<name(url)>`; a second pass accepts any speed, starting with the
  /// source that got furthest. Each source resumes its own `.part` (mirrors
  /// may serve different builds); dropped or stalled connections are resumed
  /// before moving on. Returns the source used and the redirect chain it
  /// went through.
  Future<(Uri, List<Uri>)> _downloadAny(
    List<Uri> urls,
    String dir,
    String Function(Uri url) name, {
    required void Function(String host, int got, int total) onProgress,
    required bool Function() cancelled,
    int fastEnough = 1024 * 1024,
  }) => countDownload(() async {
    Object? lastError;
    int have(Uri url) {
      final f = File(_partPath(dir, name(url), url));
      return f.existsSync() ? f.lengthSync() : 0;
    }

    for (final strict in [true, false]) {
      final order = strict ? urls : ([...urls]..sort((a, b) => have(b) - have(a)));
      for (final url in order) {
        final file = name(url);
        final part = File(_partPath(dir, file, url));
        try {
          final chain = await retryTransient(
            () => _fetch(
              url,
              part,
              minRate: strict && urls.length > 1 ? fastEnough : 0,
              onProgress: (got, total) => onProgress(url.host, got, total),
              cancelled: cancelled,
            ),
            // First pass: an unreachable source is skipped at once, one that
            // was delivering is resumed. Second pass: a few tries each.
            tries: strict ? 1 : 4,
            progress: () => have(url),
            cancelled: cancelled,
            onCancel: DownloadCancelled.new,
          );
          final dest = File(p.join(dir, file));
          if (await dest.exists()) await dest.delete();
          await part.rename(dest.path);
          for (final other in urls) {
            final f = File(_partPath(dir, name(other), other));
            if (await f.exists()) await f.delete();
          }
          return (url, chain);
        } on DownloadCancelled {
          rethrow;
        } catch (e) {
          lastError = e;
        }
      }
    }
    throw lastError!;
  });

  /// Resumable GET into [part]; redirects are followed by hand so the Range
  /// header survives CDN hops. Returns the URLs visited.
  Future<List<Uri>> _fetch(
    Uri url,
    File part, {
    int minRate = 0,
    required void Function(int got, int total) onProgress,
    required bool Function() cancelled,
  }) async {
    var have = await part.exists() ? await part.length() : 0;
    final chain = <Uri>[url];
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
          chain.add(u);
          continue;
        }
        res = r;
        break;
      }
      if (res == null) throw HttpException('too many redirects', uri: url);
      if (res.statusCode == 416) {
        await res.drain<void>();
        return chain;
      }
      if (res.statusCode >= 400) {
        await res.drain<void>();
        throw HttpException('HTTP ${res.statusCode}', uri: url);
      }
      if (res.statusCode != 206) have = 0;
      final total = res.contentLength > 0 ? have + res.contentLength : 0;
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var got = have;
      var last = DateTime.now();
      var windowStart = last;
      var windowBytes = got;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 30))) {
          if (cancelled()) throw DownloadCancelled();
          sink.add(chunk);
          got += chunk.length;
          final now = DateTime.now();
          if (now.difference(last).inMilliseconds > 250) {
            last = now;
            onProgress(got, total);
          }
          if (now.difference(windowStart) >= const Duration(seconds: 12)) {
            final rate = (got - windowBytes) / now.difference(windowStart).inSeconds;
            // Other downloads running take their share of the bandwidth.
            if (rate < minRate && activeDownloads <= 1) throw Exception('${url.host} too slow');
            (windowStart, windowBytes) = (now, got);
          }
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && got < total) throw HttpException('${url.host}: connection closed early', uri: url);
      onProgress(got, total);
      return chain;
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
        await Process.run('taskkill', ['/F', '/IM', 'ollama app.exe']);
        await Process.run('taskkill', ['/F', '/IM', 'ollama.exe']);
        // Installed with the official installer (mirror route): use its
        // uninstaller so shortcuts and the Apps entry go too.
        final unins = File(p.join(dir, 'unins000.exe'));
        if (await unins.exists()) {
          await Process.run(unins.path, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART']);
          final q = await Process.run('reg', ['query', r'HKCU\Environment', '/v', 'OLLAMA_MODELS']);
          if (q.stdout.toString().contains(p.join(dir, 'models'))) {
            await Process.run('reg', ['delete', r'HKCU\Environment', '/v', 'OLLAMA_MODELS', '/f']);
          }
        }
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
      'downloads',
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
      final n = p.basename(e.path);
      if ((n.startsWith('ollama-') || n.startsWith('OllamaSetup')) && n.endsWith('.part')) await e.delete();
    }
    // bin/ and lib/ only if they are now empty; then the folder likewise.
    for (final sub in ['bin', 'lib', '']) {
      final s = Directory(p.join(dir, sub));
      if (await s.exists() && await s.list().isEmpty) await s.delete();
    }
  }

  // Models ----------------------------------------------------------------------

  /// What [pull] is doing: 'download' (GGUF from a mirror), 'verify',
  /// 'import' (upload to Ollama), 'registry' (Ollama's own pull).
  String pullStage = '';
  String? pullSource;
  bool _pullCancelled = false;

  /// Models that [pull] fetches from the mirrors; overridable in tests.
  @visibleForTesting
  Map<String, GgufMirror> mirrors = kGgufMirrors;

  /// Where mirror downloads wait before being imported; overridable in tests.
  @visibleForTesting
  String? importDirOverride;

  Future<String> _importDir() async {
    if (importDirOverride != null) return importDirOverride!;
    if (managed) return p.join(settings.ollamaDir, 'downloads');
    return p.join((await getApplicationCacheDirectory()).path, 'ollama-import');
  }

  /// Gets [model] into Ollama. Known models come as GGUF files from mirrors
  /// (ModelScope, hf-mirror, HuggingFace) that OpenSpeak downloads, checks
  /// and imports itself: Ollama's own download follows redirects to
  /// Cloudflare R2, which fails behind "fake-IP" proxies (non-public address)
  /// and is often slow in mainland China. Ollama's registry is the fallback,
  /// and the only route for other models.
  Future<bool> pull(String model) async {
    final name = model.trim();
    if (pulling != null || name.isEmpty) return false;
    pulling = name;
    pullStatus = '';
    pullStage = '';
    pullSource = null;
    pullCompleted = pullTotal = 0;
    _pullCancelled = false;
    error = null;
    notifyListeners();
    try {
      String? mirrorError;
      final mirror = mirrors[name];
      if (mirror != null) {
        try {
          await _importGguf(name, mirror);
          models = await _tags();
          if (hasModel(name)) return true;
        } on DownloadCancelled {
          return false;
        } catch (e) {
          if (_pullCancelled) return false;
          mirrorError = '$e';
        }
      }
      try {
        await _registryPull(name);
        models = await _tags();
        return hasModel(name);
      } catch (e) {
        if (_pullCancelled) return false;
        error = pullErrorText('$e', mirrorError);
        return false;
      }
    } finally {
      _pullClient?.close(force: true);
      _pullClient = null;
      pulling = null;
      pullStage = '';
      notifyListeners();
    }
  }

  /// User-facing reason for a failed model download.
  @visibleForTesting
  static String pullErrorText(String registryError, String? mirrorError) {
    final blocked = registryError.contains('non-public') || registryError.contains('redirect target not allowed');
    return [
      '模型下载失败 / Model download failed',
      if (mirrorError != null) '镜像 / mirrors: $mirrorError',
      if (blocked)
        'Ollama 官方仓库的下载地址被代理软件解析成了内网地址（如 198.18.x.x，常见于 Clash 等的 fake-ip 模式），Ollama 出于安全拒绝连接。'
            '请把 r2.cloudflarestorage.com 设为直连或关闭 fake-ip 后重试，或改用推荐模型（走国内镜像）。'
            ' / A proxy maps Ollama\'s download host to a private address (fake-IP mode); allow r2.cloudflarestorage.com directly or use the recommended model (mirrored).'
      else
        'Ollama: $registryError',
    ].join('\n');
  }

  void _pullProgress(String stage, int done, int total, {String? source}) {
    pullStage = stage;
    pullCompleted = done;
    pullTotal = total;
    if (source != null) pullSource = source;
    notifyListeners();
  }

  Future<void> _importGguf(String model, GgufMirror m) async {
    final dir = await _importDir();
    await Directory(dir).create(recursive: true);
    final gguf = File(p.join(dir, m.file));
    if (!(await gguf.exists() && await gguf.length() == m.size)) {
      await _downloadAny(
        m.urls,
        dir,
        (_) => m.file,
        onProgress: (host, got, _) => _pullProgress('download', got, m.size, source: host),
        cancelled: () => _pullCancelled,
        fastEnough: 512 * 1024,
      );
    }
    _pullProgress('verify', 0, 0);
    final digest = await _sha256(gguf);
    if (digest != m.sha256) {
      await gguf.delete();
      throw Exception('checksum mismatch (${m.file})');
    }
    if (_pullCancelled) throw DownloadCancelled();
    await _pushBlob(gguf, digest);
    await _createModel(model, m.file, digest);
    await gguf.delete();
  }

  /// Uploads [f] to Ollama's blob store unless it is there already.
  Future<void> _pushBlob(File f, String digest) async {
    final url = apiBase.replace(path: '/api/blobs/sha256:$digest');
    final c = _pullClient = _client();
    final head = await (await c.openUrl('HEAD', url)).close();
    await head.drain<void>();
    if (head.statusCode == 200) return;
    final size = await f.length();
    final req = await c.postUrl(url);
    req.contentLength = size;
    req.headers.contentType = ContentType.binary;
    var sent = 0;
    var last = DateTime(0);
    await req.addStream(
      f.openRead().map((chunk) {
        if (_pullCancelled) throw DownloadCancelled();
        sent += chunk.length;
        final now = DateTime.now();
        if (now.difference(last).inMilliseconds > 250) {
          last = now;
          _pullProgress('import', sent, size);
        }
        return chunk;
      }),
    );
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw HttpException('blob upload: HTTP ${res.statusCode} $body');
    }
  }

  Future<void> _createModel(String model, String file, String digest) async {
    _pullProgress('import', 1, 1);
    await _streamCall('/api/create', {
      'model': model,
      'files': {file: 'sha256:$digest'},
      'stream': true,
    });
  }

  Future<void> _registryPull(String model) async {
    _pullProgress('registry', 0, 0, source: 'registry.ollama.ai');
    await _streamCall(
      '/api/pull',
      {'model': model, 'stream': true},
      onLine: (j) {
        pullStatus = '${j['status'] ?? ''}';
        if (j['total'] is int) _pullProgress('registry', j['completed'] as int? ?? 0, j['total'] as int);
      },
    );
  }

  /// POSTs [body] to an Ollama endpoint that answers with NDJSON progress
  /// lines; an `error` line becomes an exception.
  Future<void> _streamCall(String path, Map<String, Object> body, {void Function(Map j)? onLine}) async {
    final c = _pullClient = _client();
    final req = await c.postUrl(apiBase.replace(path: path));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}: ${await res.transform(utf8.decoder).join()}');
    }
    var last = DateTime(0);
    await for (final line in res.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final j = jsonDecode(line) as Map;
      if (j['error'] != null) throw Exception(j['error']);
      final now = DateTime.now();
      if (now.difference(last).inMilliseconds > 250) {
        last = now;
        onLine?.call(j);
      }
    }
  }

  /// Stops a model download; partial files are kept for next time.
  void cancelPull() {
    _pullCancelled = true;
    _pullClient?.close(force: true);
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

class _ProgramSource {
  const _ProgramSource(this.url, this.file, {this.installer = false, this.modelScopeRepo});
  final Uri url;

  /// Name of the downloaded file in the install folder.
  final String file;

  /// An installer to run (Windows mirror) rather than an archive to unpack.
  final bool installer;

  /// ModelScope repo whose file listing holds the expected SHA-256.
  final String? modelScopeRepo;
}

/// A model's GGUF file as published by its authors, mirrored in China.
class GgufMirror {
  const GgufMirror(this.repo, this.file, this.sha256, this.size, {List<Uri>? urls}) : _urls = urls;
  final String repo, file, sha256;
  final int size;
  final List<Uri>? _urls;

  List<Uri> get urls =>
      _urls ??
      [
        Uri.parse('https://modelscope.cn/models/$repo/resolve/master/$file'),
        Uri.parse('https://hf-mirror.com/$repo/resolve/main/$file'),
        Uri.parse('https://huggingface.co/$repo/resolve/main/$file'),
      ];
}

/// Ollama model names that can be fetched from the mirrors (official Qwen
/// GGUF releases, Q4_K_M like Ollama's own tags).
const kGgufMirrors = {
  'qwen2.5:3b': GgufMirror(
    'Qwen/Qwen2.5-3B-Instruct-GGUF',
    'qwen2.5-3b-instruct-q4_k_m.gguf',
    '626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d',
    2104932768,
  ),
  'qwen2.5:1.5b': GgufMirror(
    'Qwen/Qwen2.5-1.5B-Instruct-GGUF',
    'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
    1117320736,
  ),
};
