import 'core/dictation.dart';
import 'core/gpu.dart';
import 'core/model_manager.dart';
import 'core/perf_monitor.dart';
import 'core/settings.dart';

/// App-wide singletons, created once in `main()`.
late final Settings settings;
late final ModelManager models;
late final GpuManager gpu;
late final Dictation dictation;
late final PerfMonitor perf;

const kAppVersion = '0.1.0';
const kRepoUrl = 'https://github.com/QianYuan1437/OpenSpeak';
