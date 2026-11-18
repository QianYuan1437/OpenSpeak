import 'dart:io';

/// Recognizer families supported by OpenSpeak (all offline sherpa-onnx models).
enum ModelKind { senseVoice, paraformer, fireRedCtc, qwen3 }

/// A downloadable speech-recognition model.
///
/// [dir] is both the folder name inside the GitHub release archive and the
/// HuggingFace repo name under `csukuangfj/`, so every model can be fetched
/// from either source.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.name,
    required this.descZh,
    required this.descEn,
    required this.kind,
    required this.langs,
    required this.sizeMB,
    required this.dir,
    required this.files,
    this.onHuggingFace = true,
    this.gpuRecommended = false,
    this.mobile = true,
    this.supportsPartial = true,
    this.punctuation = true,
  });

  final String id;
  final String name;
  final String descZh;
  final String descEn;
  final ModelKind kind;
  final String langs;

  /// Approximate download size in MB.
  final int sizeMB;
  final String dir;

  /// Role -> file path relative to [dir]. Roles depend on [kind].
  final Map<String, String> files;

  /// Loose files are mirrored on HuggingFace (faster than the GitHub archive).
  final bool onHuggingFace;
  final bool gpuRecommended;

  /// Small/fast enough for phones.
  final bool mobile;

  /// Cheap enough to re-decode the running utterance for live preview.
  final bool supportsPartial;
  final bool punctuation;

  String get archive => '$dir.tar.bz2';
}

const kModels = <ModelSpec>[
  ModelSpec(
    id: 'sense-voice-int8',
    name: 'SenseVoice Small',
    descZh: '默认推荐。中/英/日/韩/粤语自动识别，自带标点，CPU 上也非常快。',
    descEn: 'Recommended. Auto-detects zh/en/ja/ko/yue, punctuated, very fast on CPU.',
    kind: ModelKind.senseVoice,
    langs: '中 · EN · 日 · 한 · 粤',
    sizeMB: 228,
    dir: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09',
    files: {'model': 'model.int8.onnx', 'tokens': 'tokens.txt'},
  ),
  ModelSpec(
    id: 'sense-voice-fp32',
    name: 'SenseVoice Small (FP32)',
    descZh: '全精度版本，配合 GPU 加速使用效果最好。',
    descEn: 'Full-precision build, best paired with GPU acceleration.',
    kind: ModelKind.senseVoice,
    langs: '中 · EN · 日 · 한 · 粤',
    sizeMB: 886,
    dir: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2025-09-09',
    files: {'model': 'model.onnx', 'tokens': 'tokens.txt'},
    gpuRecommended: true,
    mobile: false,
  ),
  ModelSpec(
    id: 'paraformer-zh-small',
    name: 'Paraformer 中文 Small',
    descZh: '超轻量中文模型（约 80 MB），适合低配手机；不输出标点。',
    descEn: 'Tiny Chinese model (~80 MB) for low-end phones; no punctuation.',
    kind: ModelKind.paraformer,
    langs: '中 · EN',
    sizeMB: 79,
    dir: 'sherpa-onnx-paraformer-zh-small-2024-03-09',
    files: {'model': 'model.int8.onnx', 'tokens': 'tokens.txt'},
    punctuation: false,
  ),
  ModelSpec(
    id: 'fire-red-asr2-ctc',
    name: 'FireRed-ASR2 CTC',
    descZh: '小红书开源的高精度中英文模型，普通话与专有名词更准，建议 GPU。',
    descEn: 'High-accuracy zh/en model from Xiaohongshu; GPU recommended.',
    kind: ModelKind.fireRedCtc,
    langs: '中 · EN',
    sizeMB: 496,
    dir: 'sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25',
    files: {'model': 'model.int8.onnx', 'tokens': 'tokens.txt'},
    onHuggingFace: false,
    gpuRecommended: true,
    mobile: false,
    punctuation: false,
  ),
  ModelSpec(
    id: 'qwen3-asr-0.6b',
    name: 'Qwen3-ASR 0.6B',
    descZh: '通义千问语音大模型，多语种、上下文理解强，速度较慢，强烈建议 GPU。',
    descEn: 'Qwen3 speech LLM: multilingual, context-aware, slower; GPU strongly recommended.',
    kind: ModelKind.qwen3,
    langs: '多语种 / Multilingual',
    sizeMB: 837,
    dir: 'sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25',
    files: {
      'convFrontend': 'conv_frontend.onnx',
      'encoder': 'encoder.int8.onnx',
      'decoder': 'decoder.int8.onnx',
      'tokenizer': 'tokenizer',
    },
    onHuggingFace: false,
    gpuRecommended: true,
    mobile: false,
    supportsPartial: false,
  ),
];

ModelSpec? modelById(String id) {
  for (final m in kModels) {
    if (m.id == id) return m;
  }
  return null;
}

/// Models offered on the current platform.
List<ModelSpec> get platformModels =>
    Platform.isAndroid ? kModels.where((m) => m.mobile).toList() : kModels;
