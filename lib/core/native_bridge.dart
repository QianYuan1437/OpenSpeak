import 'dart:async';

import 'package:flutter/services.dart';

import 'settings.dart';

/// Events pushed from the native side (hotkeys, Android bubble, a second
/// desktop launch asking this instance to show itself).
enum NativeEvent { hotkeyDown, hotkeyUp, bubbleTap, bubblePressStart, bubblePressEnd, activate }

/// Thin wrapper over the `openspeak/native` method channel implemented in
/// the Windows/Linux runners and the Android host.
class NativeBridge {
  NativeBridge._() {
    _ch.setMethodCallHandler((call) async {
      final ev = switch (call.method) {
        'hotkeyDown' => NativeEvent.hotkeyDown,
        'hotkeyUp' => NativeEvent.hotkeyUp,
        'bubbleTap' => NativeEvent.bubbleTap,
        'bubblePressStart' => NativeEvent.bubblePressStart,
        'bubblePressEnd' => NativeEvent.bubblePressEnd,
        'activate' => NativeEvent.activate,
        _ => null,
      };
      if (ev != null) _events.add(ev);
      return null;
    });
  }

  static final instance = NativeBridge._();
  static const _ch = MethodChannel('openspeak/native');
  final _events = StreamController<NativeEvent>.broadcast();

  Stream<NativeEvent> get events => _events.stream;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  // Desktop -----------------------------------------------------------------

  Future<bool> registerHotkey(Hotkey h) async =>
      await _call<bool>('registerHotkey', h.toJson()) ?? false;

  Future<void> unregisterHotkey() => _call('unregisterHotkey');

  /// Types Unicode text into the focused window (Windows SendInput).
  Future<bool> typeText(String text) async =>
      await _call<bool>('typeText', {'text': text}) ?? false;

  /// Sends the platform paste shortcut to the focused window.
  Future<bool> sendPaste() async => await _call<bool>('sendPaste') ?? false;

  /// Shows the window as a small translucent always-on-top capsule without
  /// taking focus. [position]: 'center' | 'top' | 'bottom'.
  Future<void> enterPill(double width, double height,
          {String position = 'center', double opacity = 0.85}) =>
      _call('enterPill', {'width': width, 'height': height, 'position': position, 'opacity': opacity});

  /// Hides the pill and restores the normal window geometry (hidden).
  Future<void> exitPill() => _call('exitPill', {'minWidth': 760, 'minHeight': 540});

  /// Whether the main window is currently visible and focused.
  /// Colours the native title bar like the page (Windows 11) and picks its
  /// light/dark variant from the app theme instead of the system theme.
  Future<void> setTitleBar(int argb, {required bool dark}) =>
      _call('setTitleBar', {'color': argb, 'dark': dark});

  Future<bool> isWindowActive() async => await _call<bool>('isWindowActive') ?? false;

  // Android -----------------------------------------------------------------

  Future<bool> canDrawOverlays() async =>
      await _call<bool>('canDrawOverlays') ?? false;

  Future<void> requestOverlayPermission() => _call('requestOverlayPermission');

  Future<bool> startBubble() async => await _call<bool>('startBubble') ?? false;

  Future<void> stopBubble() => _call('stopBubble');

  /// state: idle | listening | processing | done | error
  Future<void> setBubbleState(String state, {double level = 0, String? text}) =>
      _call('bubbleState', {'state': state, 'level': level, 'text': text});

  Future<void> copyText(String text) => _call('copyText', {'text': text});

  /// Inserts into the focused field via the accessibility service.
  Future<bool> insertText(String text) async =>
      await _call<bool>('insertText', {'text': text}) ?? false;

  Future<bool> accessibilityEnabled() async =>
      await _call<bool>('accessibilityEnabled') ?? false;

  Future<void> openAccessibilitySettings() => _call('openAccessibilitySettings');

  Future<void> moveTaskToBack() => _call('moveTaskToBack');
}
