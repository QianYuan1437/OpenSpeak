import 'dart:async';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'core/audio_capture.dart' show isDesktop;
import 'core/dictation.dart';
import 'core/gpu.dart';
import 'core/model_manager.dart';
import 'core/perf_monitor.dart';
import 'core/settings.dart';
import 'core/updater.dart';
import 'ui/desktop_shell.dart';
import 'ui/home_shell.dart';
import 'ui/i18n.dart';
import 'ui/pill_view.dart';
import 'ui/theme.dart';

/// `--install-gpu` opens the Models page and starts downloading the CUDA pack;
/// `--hidden` (used by start-at-sign-in) starts in the tray.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  settings = Settings();
  await settings.load();
  L.apply(settings.uiLanguage);
  models = ModelManager();
  await models.init();
  gpu = GpuManager();
  await gpu.init();
  dictation = Dictation(settings, models, gpu);
  perf = PerfMonitor(gpu);
  updater = Updater(kRepo, kAppVersion);
  final installGpu = args.contains('--install-gpu') && gpu.available && !gpu.ready;
  if (installGpu) {
    HomeShell.initialPage = 2;
  }
  if (isDesktop) {
    // Always show the window on the first launch and the first launch of a
    // new version; afterwards only an explicit setting (or sign-in
    // autostart's --hidden) keeps it in the tray.
    final newVersion = settings.firstRun || settings.lastRunVersion != kAppVersion;
    final hidden = args.contains('--hidden') || (settings.startHidden && !newVersion);
    await DesktopShell.init(show: installGpu || !hidden);
  }
  if (settings.lastRunVersion != kAppVersion || settings.firstRun) {
    await settings.update((s) => s.lastRunVersion = kAppVersion);
  }
  runApp(const OpenSpeakApp());
  unawaited(dictation.init());
  if (installGpu) unawaited(dictation.installGpu());
  if (settings.autoCheckUpdates) {
    unawaited(Future<void>.delayed(const Duration(seconds: 8), updater.check));
  }
}

final messengerKey = GlobalKey<ScaffoldMessengerState>();

(int, bool)? _titleBar;

/// Keeps the native title bar in the page colour / brightness.
void _syncTitleBar(ThemeData theme) {
  final want = (theme.scaffoldBackgroundColor.toARGB32(), theme.brightness == Brightness.dark);
  if (want == _titleBar) return;
  _titleBar = want;
  WidgetsBinding.instance.addPostFrameCallback((_) => dictation.bridge.setTitleBar(want.$1, dark: want.$2));
}

class OpenSpeakApp extends StatefulWidget {
  const OpenSpeakApp({super.key});

  @override
  State<OpenSpeakApp> createState() => _OpenSpeakAppState();
}

class _OpenSpeakAppState extends State<OpenSpeakApp> {
  late final StreamSubscription<String> _msgSub;

  @override
  void initState() {
    super.initState();
    _msgSub = dictation.messages.listen((m) {
      if (dictation.pillMode) return;
      messengerKey.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));
    });
  }

  @override
  void dispose() {
    _msgSub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, dictation]),
      builder: (context, _) {
        L.apply(settings.uiLanguage);
        return MaterialApp(
          title: 'OpenSpeak',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: messengerKey,
          theme: buildTheme(Brightness.light, accent: settings.accent),
          darkTheme: buildTheme(Brightness.dark, accent: settings.accent),
          themeMode: dictation.pillMode ? ThemeMode.dark : settings.themeMode,
          home: dictation.pillMode ? const PillView() : const HomeShell(),
          builder: (context, child) {
            if (isDesktop && !dictation.pillMode) _syncTitleBar(Theme.of(context));
            return child!;
          },
        );
      },
    );
  }
}
