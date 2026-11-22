import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/ollama.dart';
import 'package:openspeak/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A minimal stand-in for the Ollama API.
Future<HttpServer> fakeOllama({List<String> models = const [], bool pullFails = false}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final installed = [...models];
  server.listen((req) async {
    final res = req.response..headers.contentType = ContentType.json;
    switch (req.uri.path) {
      case '/api/version':
        res.write(jsonEncode({'version': '0.40.17'}));
      case '/api/tags':
        res.write(jsonEncode({
          'models': [for (final m in installed) {'name': m}],
        }));
      case '/api/pull':
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        res.headers.contentType = ContentType('application', 'x-ndjson');
        res.writeln(jsonEncode({'status': 'pulling manifest'}));
        if (pullFails) {
          res.writeln(jsonEncode({'error': 'pull model manifest: file does not exist'}));
        } else {
          for (final done in [0, 500, 1000]) {
            res.writeln(jsonEncode({'status': 'pulling abc', 'total': 1000, 'completed': done}));
            await res.flush();
          }
          res.writeln(jsonEncode({'status': 'success'}));
          installed.add(body['model'] as String);
        }
      default:
        res.statusCode = 404;
    }
    await res.close();
  });
  return server;
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
    await server.close(force: true);
  });

  test('pulls a model with progress', () async {
    final server = await fakeOllama();
    final o = OllamaManager(await settingsFor(server.port));
    await o.refresh();
    final seen = <int>[];
    o.addListener(() {
      if (o.pulling != null) seen.add(o.pullCompleted);
    });
    expect(await o.pull('qwen2.5:3b'), isTrue);
    expect(o.hasModel('qwen2.5:3b'), isTrue);
    expect(o.pulling, isNull);
    expect(seen.first, 0);
    await server.close(force: true);
  });

  test('reports a failed pull', () async {
    final server = await fakeOllama(pullFails: true);
    final o = OllamaManager(await settingsFor(server.port));
    expect(await o.pull('nope:1b'), isFalse);
    expect(o.error, contains('file does not exist'));
    await server.close(force: true);
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
    expect(OllamaManager.managedExe('/x/ollama'), Platform.isWindows ? r'/x/ollama\ollama.exe' : '/x/ollama/bin/ollama');
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
