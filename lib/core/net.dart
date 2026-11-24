import 'dart:async';
import 'dart:io';

/// Proxy choice for [HttpClient.findProxy]: the environment's proxy
/// (HTTP_PROXY / HTTPS_PROXY / NO_PROXY) for internet hosts, but always a
/// direct connection to this machine and the local network. Dart does not
/// exempt localhost by itself, so with a proxy variable set (common with
/// Clash and similar tools) requests to a local Ollama went to the proxy and
/// timed out.
String proxyFor(Uri url) => isLocalHost(url.host) ? 'DIRECT' : HttpClient.findProxyFromEnvironment(url);

/// Loopback, private (RFC 1918 / ULA), link-local and `.local` hosts.
bool isLocalHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) return true;
  final ip = InternetAddress.tryParse(h.startsWith('[') ? h.substring(1, h.length - 1) : h);
  if (ip == null) return false;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 || b[0] == 0 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
  }
  return (b[0] & 0xfe) == 0xfc;
}

/// A dropped, stalled or refused connection, or a server-side hiccup: worth
/// trying again (downloads resume from their `.part`). HTTP 4xx is not.
bool isTransientNetError(Object e) =>
    e is SocketException ||
    e is TimeoutException ||
    e is TlsException ||
    (e is HttpException && !RegExp(r'^HTTP 4\d\d').hasMatch(e.message));

/// Number of downloads running right now (models, Ollama and its models).
/// While several share the bandwidth, a slow source is not a bad source.
int activeDownloads = 0;

Future<T> countDownload<T>(Future<T> Function() run) async {
  activeDownloads++;
  try {
    return await run();
  } finally {
    activeDownloads--;
  }
}

/// Runs [attempt] again after transient network errors, waiting a little
/// longer each time. [progress] reports the bytes on disk: an attempt that
/// got further than the last one does not count against [tries], so a
/// download that keeps moving is never given up.
Future<T> retryTransient<T>(
  Future<T> Function() attempt, {
  int tries = 4,
  int Function()? progress,
  required bool Function() cancelled,
  required Exception Function() onCancel,
}) async {
  var failures = 0;
  var seen = progress?.call() ?? 0;
  for (;;) {
    try {
      return await attempt();
    } catch (e) {
      if (cancelled() || !isTransientNetError(e)) rethrow;
      final now = progress?.call() ?? 0;
      if (now > seen) {
        seen = now;
        failures = 0;
      } else if (++failures >= tries) {
        rethrow;
      }
    }
    // 0.5 s, 1 s, 2 s, 4 s … checking for pause/cancel meanwhile.
    for (var i = 0; i < 2 << failures; i++) {
      if (cancelled()) throw onCancel();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}
