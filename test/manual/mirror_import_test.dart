// Real mirror import into a running Ollama. Skipped unless OS_OLLAMA_PORT is set:
//   OS_OLLAMA_PORT=11435 OS_IMPORT_MODEL=qwen2.5:1.5b flutter test test/manual/mirror_import_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/ollama.dart';
import 'package:openspeak/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final port = Platform.environment['OS_OLLAMA_PORT'];
  test(
    'mirror import',
    () async {
      SharedPreferences.setMockInitialValues({});
      final s = Settings();
      await s.load();
      s.setEndpoint('ollama', baseUrl: 'http://127.0.0.1:$port/v1');
      final tmp = await Directory.systemTemp.createTemp('os_real_import');
      // A GGUF already on disk (OS_IMPORT_GGUF) is hard-linked in, skipping the download.
      final local = Platform.environment['OS_IMPORT_GGUF'];
      if (local != null) await Process.run('ln', [local, tmp.path]);
      final o = OllamaManager(s)..importDirOverride = tmp.path;
      var lastLog = DateTime(0);
      o.addListener(() {
        if (DateTime.now().difference(lastLog).inSeconds >= 10 || o.pullStage != 'download') {
          lastLog = DateTime.now();
          // ignore: avoid_print
          print(
            '${DateTime.now().toIso8601String().substring(11, 19)} ${o.pullStage} ${o.pullSource} '
            '${o.pullCompleted ~/ 1000000}/${o.pullTotal ~/ 1000000} MB ${o.pullStatus}',
          );
        }
      });
      final model = Platform.environment['OS_IMPORT_MODEL'] ?? 'qwen2.5:1.5b';
      final ok = await o.pull(model);
      // ignore: avoid_print
      print('ok=$ok error=${o.error} models=${o.models}');
      expect(ok, isTrue);
      expect(tmp.listSync(), isEmpty);
      await tmp.delete();
    },
    skip: port == null ? 'set OS_OLLAMA_PORT to run' : false,
    timeout: const Timeout(Duration(minutes: 40)),
  );
}
