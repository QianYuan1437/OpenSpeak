import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/model_manager.dart' show DownloadCancelled;
import 'package:openspeak/core/net.dart';

void main() {
  test('local and LAN hosts bypass the proxy', () {
    for (final h in [
      '127.0.0.1',
      'localhost',
      '::1',
      '[::1]',
      '192.168.1.20',
      '10.17.36.111',
      '172.20.0.5',
      'nas.local',
    ]) {
      expect(isLocalHost(h), isTrue, reason: h);
      expect(proxyFor(Uri.parse('http://${h.contains(':') && !h.startsWith('[') ? '[$h]' : h}:11434/')), 'DIRECT');
    }
    for (final h in ['github.com', 'modelscope.cn', '8.8.8.8', '172.32.0.1', '198.18.1.63']) {
      expect(isLocalHost(h), isFalse, reason: h);
    }
  });

  test('transient errors', () {
    expect(isTransientNetError(const SocketException('reset')), isTrue);
    expect(isTransientNetError(TimeoutException('stalled')), isTrue);
    expect(isTransientNetError(const HttpException('connection closed early')), isTrue);
    expect(isTransientNetError(const HttpException('HTTP 503')), isTrue);
    expect(isTransientNetError(const HttpException('HTTP 404')), isFalse);
    expect(isTransientNetError(Exception('too slow')), isFalse);
  });

  group('retryTransient', () {
    Future<int> run(List<Object?> outcomes, {int tries = 3, List<int>? progress}) {
      var i = 0;
      return retryTransient(
        () async {
          final o = outcomes[i++];
          if (o != null) throw o;
          return i;
        },
        tries: tries,
        // Bytes on disk after i attempts.
        progress: progress == null ? null : () => progress[i],
        cancelled: () => false,
        onCancel: DownloadCancelled.new,
      );
    }

    test('retries transient failures', () async {
      expect(await run([const SocketException('x'), null]), 2);
      await expectLater(run([const HttpException('HTTP 404'), null]), throwsA(isA<HttpException>()));
      await expectLater(
        run([const SocketException('a'), const SocketException('b'), const SocketException('c'), null]),
        throwsA(isA<SocketException>()),
      );
    });

    test('progress does not count against the tries', () async {
      // Each failed attempt got further: never given up, even with tries: 1.
      expect(
        await run([const SocketException('a'), const SocketException('b'), null], tries: 1, progress: [0, 10, 20, 30]),
        3,
      );
      await expectLater(
        run([const SocketException('a'), null], tries: 1, progress: [0, 0, 0]),
        throwsA(isA<SocketException>()),
      );
    });

    test('stops when cancelled', () async {
      var cancel = false;
      final f = retryTransient<int>(
        () async {
          cancel = true;
          throw const SocketException('x');
        },
        cancelled: () => cancel,
        onCancel: DownloadCancelled.new,
      );
      await expectLater(f, throwsA(isA<SocketException>()));
    });
  });

  test('countDownload tracks running downloads', () async {
    final gate = Completer<void>();
    final f = countDownload(() => gate.future);
    expect(activeDownloads, 1);
    gate.complete();
    await f;
    expect(activeDownloads, 0);
  });
}
