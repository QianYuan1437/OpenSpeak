import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/ollama.dart';
import 'package:openspeak/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A minimal stand-in for the Ollama API, plus a file host for mirror tests
/// (`/files/<name>`, with Range support; `/files/missing` is a 404).
class FakeOllama {
  FakeOllama._(this.server);
  final HttpServer server;
  int get port => server.port;
  final installed = <String>[];
  final blobs = <String, int>{};
  final created = <Map>[];
  final files = <String, List<int>>{};

  /// Files whose next request is cut off halfway (a dropped connection).
  final dropOnce = <String>{};
  int fileRequests = 0;
  String? pullError;

  Future<void> close() => server.close(force: true);
}

Future<FakeOllama> fakeOllama({List<String> models = const [], bool pullFails = false}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final f = FakeOllama._(server)..installed.addAll(models);
  if (pullFails) f.pullError = 'pull model manifest: file does not exist';
  server.listen((req) async {
    final res = req.response..headers.contentType = ContentType.json;
    final path = req.uri.path;
    if (path.startsWith('/files/')) {
      final name = path.substring(7);
      final data = f.files[name];
      f.fileRequests++;
      if (data == null) {
        res.statusCode = 404;
      } else {
        final range = RegExp(r'bytes=(\d+)-').firstMatch(req.headers.value('range') ?? '');
        final from = range == null ? 0 : int.parse(range.group(1)!);
        if (range != null) res.statusCode = 206;
        res.headers.contentType = ContentType.binary;
        res.contentLength = data.length - from;
        if (f.dropOnce.remove(name)) {
          final socket = await res.detachSocket();
          socket.add(data.sublist(from, from + (data.length - from) ~/ 2));
          await socket.flush();
          socket.destroy();
          return;
        }
        res.add(data.sublist(from));
      }
    } else if (path.startsWith('/api/blobs/sha256:')) {
      final digest = path.substring('/api/blobs/sha256:'.length);
      if (req.method == 'HEAD') {
        res.statusCode = f.blobs.containsKey(digest) ? 200 : 404;
      } else {
        final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        if (sha256.convert(body).toString() != digest) {
          res.statusCode = 400;
          res.write(jsonEncode({'error': 'digest mismatch'}));
        } else {
          f.blobs[digest] = body.length;
          res.statusCode = 201;
        }
      }
    } else {
      switch (path) {
        case '/api/version':
          res.write(jsonEncode({'version': '0.40.17'}));
        case '/api/tags':
          res.write(
            jsonEncode({
              'models': [
                for (final m in f.installed) {'name': m},
              ],
            }),
          );
        case '/api/create':
          final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
          f.created.add(body);
          res.headers.contentType = ContentType('application', 'x-ndjson');
          final missing = (body['files'] as Map).values.any((d) => !f.blobs.containsKey((d as String).substring(7)));
          if (missing) {
            res.writeln(jsonEncode({'error': 'blob not found'}));
          } else {
            res.writeln(jsonEncode({'status': 'parsing GGUF'}));
            res.writeln(jsonEncode({'status': 'success'}));
            f.installed.add('${body['model']}');
          }
        case '/api/pull':
          final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
          res.headers.contentType = ContentType('application', 'x-ndjson');
          res.writeln(jsonEncode({'status': 'pulling manifest'}));
          if (f.pullError != null) {
            res.writeln(jsonEncode({'error': f.pullError}));
          } else {
            for (final done in [0, 500, 1000]) {
              res.writeln(jsonEncode({'status': 'pulling abc', 'total': 1000, 'completed': done}));
              await res.flush();
            }
            res.writeln(jsonEncode({'status': 'success'}));
            f.installed.add(body['model'] as String);
          }
        default:
          res.statusCode = 404;
      }
    }
    await res.close();
  });
  return f;
}

Future<Settings> settingsFor(int port) async {
  SharedPreferences.setMockInitialValues({});
  final s = Settings();
  await s.load();
  s.setEndpoint('ollama', baseUrl: 'http://127.0.0.1:$port/v1');
  return s;
}

void main() {
  test('API base from the service URL', () async {
    final s = await settingsFor(11434);
    final o = OllamaManager(s);
    expect(o.apiBase.toString(), 'http://127.0.0.1:11434');
    expect(o.isLocal, isTrue);
    s.setEndpoint('ollama', baseUrl: 'http://192.168.1.10:8080/v1/');
    expect(o.apiBase.toString(), 'http://192.168.1.10:8080');
    expect(o.isLocal, isFalse);
    s.setEndpoint('ollama', baseUrl: 'localhost');
    expect(o.apiBase.toString(), 'http://127.0.0.1:11434');
  });

  test('detects a running Ollama and its models', () async {
    final server = await fakeOllama(models: ['qwen2.5:3b', 'llama3:latest']);
    final o = OllamaManager(await settingsFor(server.port));
    await o.refresh();
    expect(o.status, OllamaStatus.running);
    expect(o.version, '0.40.17');
    expect(o.hasModel('qwen2.5:3b'), isTrue);
    expect(o.hasModel('llama3'), isTrue);
    expect(o.hasModel('qwen3:4b'), isFalse);
    expect(await o.ensureRunning(), isTrue);
    await server.close();
  });

  test('pulls a model with progress', () async {
    final server = await fakeOllama();
    final o = OllamaManager(await settingsFor(server.port));
    await o.refresh();
    final seen = <int>[];
    o.addListener(() {
      if (o.pulling != null) seen.add(o.pullCompleted);
    });
    o.mirrors = {}; // registry route only
    expect(await o.pull('qwen2.5:3b'), isTrue);
    expect(o.hasModel('qwen2.5:3b'), isTrue);
    expect(o.pulling, isNull);
    expect(seen.first, 0);
    await server.close();
  });

  test('reports a failed pull', () async {
    final server = await fakeOllama(pullFails: true);
    final o = OllamaManager(await settingsFor(server.port));
    expect(await o.pull('nope:1b'), isFalse);
    expect(o.error, contains('file does not exist'));
    await server.close();
  });

  group('mirror import', () {
    late FakeOllama server;
    late OllamaManager o;
    late Directory tmp;
    final gguf = List<int>.generate(300 * 1024, (i) => (i * 7) % 251);
    final digest = sha256.convert(gguf).toString();
    GgufMirror mirror({String? sha}) => GgufMirror(
      'Org/Repo',
      'tiny.gguf',
      sha ?? digest,
      gguf.length,
      urls: [
        Uri.parse('http://127.0.0.1:${server.port}/files/missing'),
        Uri.parse('http://127.0.0.1:${server.port}/files/tiny.gguf'),
      ],
    );

    setUp(() async {
      server = await fakeOllama();
      server.files['tiny.gguf'] = gguf;
      tmp = await Directory.systemTemp.createTemp('os_import');
      o = OllamaManager(await settingsFor(server.port))..importDirOverride = tmp.path;
    });
    tearDown(() async {
      await server.close();
      await tmp.delete(recursive: true);
    });

    test('downloads from a working mirror, verifies and imports', () async {
      o.mirrors = {'tiny:1b': mirror()};
      final stages = <String>{};
      o.addListener(() => stages.add(o.pullStage));
      expect(await o.pull('tiny:1b'), isTrue);
      expect(o.error, isNull);
      expect(o.hasModel('tiny:1b'), isTrue);
      expect(server.blobs[digest], gguf.length);
      expect(server.created.single, {
        'model': 'tiny:1b',
        'files': {'tiny.gguf': 'sha256:$digest'},
        'stream': true,
      });
      expect(stages, containsAll(['download', 'verify', 'import']));
      expect(stages, isNot(contains('registry')));
      expect(tmp.listSync(), isEmpty); // the GGUF and part files are gone
    });

    test('resumes a partial download', () async {
      o.mirrors = {'tiny:1b': mirror()};
      final part = File('${tmp.path}/tiny.gguf.127.0.0.1.part');
      await part.writeAsBytes(gguf.sublist(0, 1000));
      expect(await o.pull('tiny:1b'), isTrue);
      expect(server.blobs[digest], gguf.length);
    });

    test('a dropped connection resumes from the same mirror', () async {
      o.mirrors = {'tiny:1b': mirror()};
      server.dropOnce.add('tiny.gguf');
      final sources = <String?>{};
      o.addListener(() => sources.add(o.pullSource));
      expect(await o.pull('tiny:1b'), isTrue);
      expect(o.error, isNull);
      expect(server.blobs[digest], gguf.length);
      expect(server.fileRequests, 3); // missing, cut off, resumed
      expect(sources.whereType<String>(), {'127.0.0.1'});
    });

    test('a bad checksum falls back to the registry', () async {
      o.mirrors = {'tiny:1b': mirror(sha: '0' * 64)};
      final stages = <String>{};
      o.addListener(() => stages.add(o.pullStage));
      expect(await o.pull('tiny:1b'), isTrue);
      expect(stages, contains('registry'));
      expect(server.blobs, isEmpty);
      expect(tmp.listSync(), isEmpty);
    });

    test('mirrors and registry both failing explain the proxy problem', () async {
      server.files.clear();
      server.pullError =
          'max retries exceeded: Get "https://x.r2.cloudflarestorage.com/...": redirect target not allowed: '
          'x.r2.cloudflarestorage.com resolves to non-public 198.18.1.63';
      o.mirrors = {'tiny:1b': mirror()};
      expect(await o.pull('tiny:1b'), isFalse);
      expect(o.error, contains('fake-ip'));
      expect(o.error, contains('HTTP 404'));
      expect(o.pulling, isNull);
    });
  });

  test('pull error text', () {
    expect(OllamaManager.pullErrorText('file does not exist', null), contains('Ollama: file does not exist'));
    expect(
      OllamaManager.pullErrorText('resolves to non-public 198.18.0.5', 'timeout'),
      allOf(contains('r2.cloudflarestorage.com'), contains('timeout')),
    );
  });

  test('catalog entries point at the official GGUF releases', () {
    for (final m in kGgufMirrors.values) {
      expect(m.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(m.urls.first.host, 'modelscope.cn');
      expect(m.urls.map((u) => u.path.endsWith(m.file)), everyElement(isTrue));
    }
    expect(kGgufMirrors, contains(kRecommendedOllamaModel));
  });

  test('nothing listening: missing / stopped locally, remote otherwise', () async {
    // A port nobody listens on.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final s = await settingsFor(port);
    final o = OllamaManager(s);
    await o.refresh();
    expect(o.status, anyOf(OllamaStatus.missing, OllamaStatus.stopped));
    expect(o.status == OllamaStatus.stopped, o.exe != null);
    s.setEndpoint('ollama', baseUrl: 'http://10.255.255.1:$port/v1');
    await o.refresh();
    expect(o.status, OllamaStatus.remote);
  });

  test('install folder helpers', () {
    expect(
      OllamaManager.managedExe('/x/ollama'),
      Platform.isWindows ? r'/x/ollama\ollama.exe' : '/x/ollama/bin/ollama',
    );
    expect(OllamaManager.defaultDir, contains(Platform.isWindows ? 'OpenSpeak' : 'openspeak'));
  });

  test('installs only into empty or own folders; uninstall keeps other files', () async {
    final tmp = await Directory.systemTemp.createTemp('os_ollama');
    final dir = '${tmp.path}/inst';
    expect(OllamaManager.usableInstallDir(dir), isTrue); // does not exist yet
    await Directory(dir).create();
    expect(OllamaManager.usableInstallDir(dir), isTrue); // empty
    await File('$dir/OllamaSetup.exe').writeAsString('x');
    expect(OllamaManager.usableInstallDir(dir), isFalse); // someone else's files
    await File('$dir/${OllamaManager.marker}').writeAsString('');
    expect(OllamaManager.usableInstallDir(dir), isTrue);

    // A finished install plus a file the user put there.
    final exe = File(OllamaManager.managedExe(dir));
    await exe.create(recursive: true);
    await File('$dir/lib/ollama/libggml.so').create(recursive: true);
    await File('$dir/models/blobs/sha256-1').create(recursive: true);
    await File('$dir/ollama-linux-amd64.tar.zst.ollama.com.part').writeAsString('x');
    await OllamaManager.removeInstall(dir);
    expect(exe.existsSync(), isFalse);
    expect(Directory('$dir/lib').existsSync(), isFalse);
    expect(Directory('$dir/models').existsSync(), isFalse);
    expect(File('$dir/${OllamaManager.marker}').existsSync(), isFalse);
    expect(File('$dir/OllamaSetup.exe').existsSync(), isTrue);
    expect(Directory(dir).listSync().length, 1);

    // Nothing else left: the folder goes too.
    await File('$dir/OllamaSetup.exe').delete();
    await File('$dir/${OllamaManager.marker}').writeAsString('');
    await OllamaManager.removeInstall(dir);
    expect(Directory(dir).existsSync(), isFalse);
    await tmp.delete(recursive: true);
  });

  test('free space of a folder that does not exist yet', () async {
    final free = await OllamaManager.freeBytes('${Directory.systemTemp.path}/no/such/dir');
    expect(free, isNotNull);
    expect(free!, greaterThan(0));
  });
}
