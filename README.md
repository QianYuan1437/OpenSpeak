<p align="center">
  <img src="docs/assets/icon.png" width="112" alt="OpenSpeak">
</p>

<h1 align="center">OpenSpeak</h1>

<p align="center">
  开源 · 离线 · 跨平台的语音输入工具 —— 按住快捷键说话，松开即把文字打进任何应用。<br>
  Open-source, offline, cross-platform voice typing for Windows, Linux and Android.
</p>

<p align="center">
  <a href="https://github.com/QianYuan1437/OpenSpeak/releases/latest"><img src="https://img.shields.io/github/v/release/QianYuan1437/OpenSpeak?label=release" alt="release"></a>
  <a href="https://github.com/QianYuan1437/OpenSpeak/actions/workflows/release.yml"><img src="https://github.com/QianYuan1437/OpenSpeak/actions/workflows/release.yml/badge.svg" alt="build"></a>
  <a href="https://qianyuan1437.github.io/OpenSpeak/"><img src="https://img.shields.io/badge/website-pages-5B5BD6" alt="website"></a>
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

---

## 功能

- **完全离线**：基于 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)，音频不出本机。
- **全局听写**（Windows / Linux X11）：任意应用中按住快捷键（默认 **右 Ctrl**）说话，松开即逐字键入；也可切换为“按一下开始、再按一下结束”。录音时屏幕底部出现不抢焦点的小浮条，实时显示识别结果。
- **Android 悬浮球**：任何应用上方的麦克风悬浮球，点击开始/结束或长按说话；结果自动复制，开启无障碍服务后可直接写入输入框。
- **多模型可选**：
  | 模型 | 大小 | 说明 |
  |---|---|---|
  | SenseVoice Small（默认） | 228 MB | 中/英/日/韩/粤自动识别，带标点，CPU 上 5 秒语音约 0.1 秒出字 |
  | Paraformer 中文 Small | 79 MB | 极轻量，适合低配手机 |
  | FireRed-ASR2 CTC | 496 MB | 中英文高精度，建议 GPU |
  | Qwen3-ASR 0.6B | 837 MB | 语音大模型，多语种，建议 GPU |
- **GPU 加速**：检测到 NVIDIA 显卡时可一键下载 CUDA 加速包（cuDNN/cuBLAS 从国内 PyPI 镜像获取），无需安装 CUDA 工具包。
- **创作者麦克风适配**：自动识别 **DJI Mic / Mic Mini**、**Godox MoveLink / Virso**、**影石 Insta360 Mic Air**、RØDE、Hollyland、Saramonic、BOYA 等接收器，插入即自动切换；双发射器可按左/右声道（TX1 / TX2）单独拾音；内置自动增益，领夹麦音量小也能稳定识别。
- **实时预览 + VAD 分句**：Silero VAD 按停顿切句，长段落边说边出字。
- 繁转简、去句末句号、历史记录、深浅色与 8 种主题色、中英文界面。

## 下载

前往 [Releases](https://github.com/QianYuan1437/OpenSpeak/releases)：

| 平台 | 文件 |
|---|---|
| Windows 10/11 x64 | `OpenSpeak-x.y.z-windows-x64-setup.exe`（安装版）或 `…-windows-x64.zip`（绿色版） |
| Linux x64（X11） | `OpenSpeak-x.y.z-linux-amd64.deb` 或 `…-linux-x64.tar.gz` |
| Android 7.0+ | `OpenSpeak-x.y.z-android-arm64-v8a.apk`（绝大多数手机） |

首次启动后在“模型”页一键下载模型（HuggingFace → hf-mirror → GitHub 自动切换）。

> Linux：全局快捷键与自动键入需要 X11 会话，并依赖 `xdotool`、`pulseaudio-utils`（.deb 会自动安装）。Wayland 下可在应用内听写并复制结果。

## 使用

1. 打开 OpenSpeak，下载 SenseVoice 模型。
2. 在任意应用的输入框中 **按住右 Ctrl** 说话，松开后文字自动输入。
3. 关闭窗口后程序驻留托盘，快捷键持续可用；托盘菜单可退出。
4. 设置页可更换麦克风、声道、增益、快捷键、触发方式与输出方式（模拟键入 / 粘贴 / 仅复制）。

## 从源码构建

需要 Flutter 3.41（Dart 3.11）。

```bash
flutter pub get
flutter run -d windows   # 需要 Visual Studio 2022+ 与 Windows 10/11 SDK
flutter run -d linux     # sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libayatana-appindicator3-dev libx11-dev lld xdotool
flutter build apk --split-per-abi
```

测试：`flutter test test/text_test.dart`；识别引擎的集成测试需要本地模型，见 `test/models_test.dart` 顶部说明。

## 目录结构

```
lib/core/      识别引擎（后台 isolate）、录音与麦克风适配、模型/GPU 包下载、听写流程
lib/ui/        界面（听写、历史、模型、设置、录音浮条）
windows/runner/openspeak_native.cpp   全局快捷键（低级键盘钩子）、SendInput 键入、浮条窗口
linux/runner/openspeak_native.cc      X11 全局快捷键、浮条窗口
android/app/src/main/kotlin/…         悬浮球前台服务、无障碍输入服务
.github/workflows/                    CI 构建发布、GPU 运行库打包、Pages
docs/                                 项目主页
```

## 致谢

- [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) —— 离线语音识别引擎与模型转换
- [FunAudioLLM/SenseVoice](https://github.com/FunAudioLLM/SenseVoice)、[FireRedTeam/FireRedASR](https://github.com/FireRedTeam/FireRedASR)、[QwenLM/Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)、[modelscope/FunASR](https://github.com/modelscope/FunASR)（Paraformer）
- [snakers4/silero-vad](https://github.com/snakers4/silero-vad)、[BYVoid/OpenCC](https://github.com/BYVoid/OpenCC)（繁简转换表）
- 交互参考了 Superwhisper、VoiceInk、Handy 等语音输入工具

## License

MIT © QianYuan1437。各模型版权与许可归其原作者所有。
