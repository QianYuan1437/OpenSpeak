import 'package:flutter_test/flutter_test.dart';
import 'package:openspeak/core/updater.dart';

Map<String, dynamic> rel(String tag, List<String> assets, {bool pre = false}) => {
      'tag_name': tag,
      'prerelease': pre,
      'draft': false,
      'html_url': 'https://github.com/x/y/releases/tag/$tag',
      'assets': [for (final a in assets) {'name': a, 'browser_download_url': 'https://dl/$a'}],
    };

void main() {
  final releases = [
    rel('latest', ['OpenSpeak-0.1.0-dev.9-windows-x64-setup.exe', 'OpenSpeak-0.1.0-dev.9-linux-amd64.deb'], pre: true),
    rel('gpu-runtime-2.0.1', ['openspeak-gpu-windows-x64.zip'], pre: true),
    rel('v0.0.9', ['OpenSpeak-0.0.9-windows-x64-setup.exe']),
  ];

  test('orders versions; a release beats its dev builds', () {
    AppVersion v(String s) => AppVersion.tryParse(s)!;
    expect(v('0.1.0') > v('0.1.0-dev.30'), isTrue);
    expect(v('0.1.0-dev.10') > v('0.1.0-dev.9'), isTrue);
    expect(v('v0.2.0') > v('0.1.9'), isTrue);
    expect(AppVersion.tryParse('gpu-runtime-2.0.1'), isNull);
  });

  test('dev builds are offered the newer rolling build with this platform asset', () {
    final u = pickUpdate(releases, AppVersion.tryParse('0.1.0-dev.8')!, '-windows-x64-setup.exe')!;
    expect(u.version.toString(), '0.1.0-dev.9');
    expect(u.downloadUrl, 'https://dl/OpenSpeak-0.1.0-dev.9-windows-x64-setup.exe');
  });

  test('up to date and stable users ignore dev builds', () {
    expect(pickUpdate(releases, AppVersion.tryParse('0.1.0-dev.9')!, '-windows-x64-setup.exe'), isNull);
    expect(pickUpdate(releases, AppVersion.tryParse('0.0.9')!, '-windows-x64-setup.exe'), isNull);
    final stable = pickUpdate([...releases, rel('v0.2.0', ['OpenSpeak-0.2.0-linux-amd64.deb'])],
        AppVersion.tryParse('0.0.9')!, '-linux-amd64.deb')!;
    expect(stable.version.toString(), '0.2.0');
  });
}
