// Ollama model download running alongside model downloads from the Models
// tab, over the real network. Skipped unless OS_OLLAMA_PORT is set:
//   OS_OLLAMA_PORT=11435 flutter test test/manual/parallel_download_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/model_catalog.dart';
import 'package:openspeak/core/model_manager.dart';
import 'package:openspeak/core/net.dart';
import 'package:openspeak/core/ollama.dart';
import 'package:openspeak/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final port = Platform.environment['OS_OLLAMA_PORT'];
  test(
    'parallel downloads',
    () async {
      SharedPreferences.setMockInitialValues({});
      final s = Settings();
      await s.load();
      s.setEndpoint('ollama', baseUrl: 'http://127.0.0.1:$port/v1');
      final tmp = await Directory.systemTemp.createTemp('os_parallel');
      final o = OllamaManager(s)..importDirOverride = '${tmp.path}/import';
      final m = ModelManager()..root = (Directory('${tmp.path}/models')..createSync(recursive: true));
      final sources = <String>{};
      var maxActive = 0;
      void log(String what) {
        if (activeDownloads > maxActive) maxActive = activeDownloads;
        // ignore: avoid_print
        print('${DateTime.now().toIso8601String().substring(11, 19)} active=$activeDownloads $what');
      }

      var lastLog = DateTime(0);
      void tick() {
        if (DateTime.now().difference(lastLog).inSeconds < 10) return;
        lastLog = DateTime.now();
        log(
          [
            'ollama: ${o.pullStage} ${o.pullSource} ${o.pullCompleted ~/ 1000000}/${o.pullTotal ~/ 1000000} MB',
            for (final e in m.progress.entries)
              '${e.key}: ${e.value.source} ${e.value.received ~/ 1000000}/${e.value.total ~/ 1000000} MB',
          ].join(' | '),
        );
      }

      o.addListener(() {
        if (o.pullStage == 'download' && o.pullSource != null) sources.add(o.pullSource!);
        tick();
      });
      m.addListener(tick);
      final asr = [modelById('sense-voice-int8')!, modelById('paraformer-zh-small')!];
      final model = Platform.environment['OS_IMPORT_MODEL'] ?? 'qwen2.5:1.5b';
      final results = await Future.wait([o.pull(model), for (final a in asr) m.download(a).then((_) => true)]);
      log('done: ollama=${results.first} error=${o.error} sources=$sources maxActive=$maxActive');
      for (final a in asr) {
        log('${a.id}: installed=${m.isInstalled(a)} error=${m.errors[a.id]}');
        expect(m.isInstalled(a), isTrue);
      }
      expect(results.first, isTrue);
      expect(o.hasModel(model), isTrue);
      expect(sources.length, 1, reason: 'switched mirrors: $sources');
      expect(maxActive, greaterThanOrEqualTo(2));
      expect(activeDownloads, 0);
      await tmp.delete(recursive: true);
    },
    skip: port == null ? 'set OS_OLLAMA_PORT to run' : false,
    timeout: const Timeout(Duration(minutes: 40)),
  );
}
