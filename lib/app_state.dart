import 'core/dictation.dart';
import 'core/gpu.dart';
import 'core/model_manager.dart';
import 'core/ollama.dart';
import 'core/perf_monitor.dart';
import 'core/settings.dart';
import 'core/updater.dart';

/// App-wide singletons, created once in `main()`.
late final Settings settings;
late final ModelManager models;
late final GpuManager gpu;
late final Dictation dictation;
late final PerfMonitor perf;
late final Updater updater;
late final OllamaManager ollama;

/// CI passes the build name (e.g. 0.1.0-dev.12) via --dart-define.
const kAppVersion = String.fromEnvironment('OPENSPEAK_VERSION', defaultValue: '0.1.0');
const kRepo = 'QianYuan1437/OpenSpeak';
const kRepoUrl = 'https://github.com/$kRepo';
