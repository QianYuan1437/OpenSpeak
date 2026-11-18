import 'dart:async';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'core/audio_capture.dart' show isDesktop;
import 'core/dictation.dart';
import 'core/gpu.dart';
import 'core/model_manager.dart';
import 'core/settings.dart';
import 'ui/desktop_shell.dart';
import 'ui/home_shell.dart';
import 'ui/i18n.dart';
import 'ui/pill_view.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  settings = Settings();
  await settings.load();
  L.apply(settings.uiLanguage);
  models = ModelManager();
  await models.init();
  gpu = GpuManager();
  await gpu.init();
  dictation = Dictation(settings, models, gpu);
  if (isDesktop) await DesktopShell.init();
  runApp(const OpenSpeakApp());
  unawaited(dictation.init());
}

final messengerKey = GlobalKey<ScaffoldMessengerState>();

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
        );
      },
    );
  }
}
