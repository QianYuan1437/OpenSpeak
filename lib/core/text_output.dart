import 'dart:io';

import 'package:flutter/services.dart';

import 'native_bridge.dart';
import 'settings.dart';

/// Result of delivering text to the focused application.
enum OutputResult { typed, pasted, copied, failed }

/// Delivers recognized text to whatever app has keyboard focus.
class TextOutput {
  TextOutput(this.bridge);
  final NativeBridge bridge;
  bool? _xdotool;

  Future<bool> get hasXdotool async {
    if (!Platform.isLinux) return false;
    return _xdotool ??= (await Process.run('which', ['xdotool'])).exitCode == 0;
  }

  Future<OutputResult> deliver(String text, OutputMode mode) async {
    if (text.isEmpty) return OutputResult.failed;
    if (Platform.isAndroid) {
      await bridge.copyText(text);
      if (await bridge.insertText(text)) return OutputResult.typed;
      return OutputResult.copied;
    }
    switch (mode) {
      case OutputMode.type:
        if (await _type(text)) return OutputResult.typed;
        return _paste(text);
      case OutputMode.paste:
        return _paste(text);
      case OutputMode.clipboard:
        await Clipboard.setData(ClipboardData(text: text));
        return OutputResult.copied;
    }
  }

  Future<bool> _type(String text) async {
    if (Platform.isWindows) return bridge.typeText(text);
    if (Platform.isLinux && await hasXdotool) {
      final r = await Process.run(
          'xdotool', ['type', '--clearmodifiers', '--delay', '1', '--', text]);
      return r.exitCode == 0;
    }
    return false;
  }

  Future<OutputResult> _paste(String text) async {
    final previous = await Clipboard.getData(Clipboard.kTextPlain);
    await Clipboard.setData(ClipboardData(text: text));
    var ok = false;
    if (Platform.isWindows) {
      ok = await bridge.sendPaste();
    } else if (Platform.isLinux && await hasXdotool) {
      ok = (await Process.run('xdotool', ['key', '--clearmodifiers', 'ctrl+v']))
              .exitCode ==
          0;
    }
    if (!ok) return OutputResult.copied;
    // Give the target app time to read the clipboard, then restore it.
    if (previous?.text != null) {
      Future.delayed(const Duration(milliseconds: 600),
          () => Clipboard.setData(ClipboardData(text: previous!.text!)));
    }
    return OutputResult.pasted;
  }
}

/// Light post-processing applied before output.
String postProcess(String text, {required bool stripTrailingPeriod}) {
  var t = text.trim();
  if (stripTrailingPeriod && t.isNotEmpty) {
    final last = t[t.length - 1];
    if (last == '。' || last == '.') t = t.substring(0, t.length - 1);
  }
  return t;
}
