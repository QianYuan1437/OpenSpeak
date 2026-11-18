import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/settings.dart';
import 'i18n.dart';
import 'theme.dart';

/// Shows the hotkey as key caps; click it and press the new key or
/// combination to change it. A right-hand Ctrl / Alt / Shift can be used on
/// its own; letters and digits need a modifier. Esc or clicking elsewhere
/// cancels. The global hotkey is paused while recording.
class HotkeyRecorder extends StatefulWidget {
  const HotkeyRecorder({super.key, required this.value, required this.onChanged});

  final Hotkey value;
  final ValueChanged<Hotkey> onChanged;

  @override
  State<HotkeyRecorder> createState() => _HotkeyRecorderState();
}

class _HotkeyRecorderState extends State<HotkeyRecorder> {
  final _focus = FocusNode(debugLabel: 'hotkey-recorder');
  bool _recording = false;
  final _held = <LogicalKeyboardKey>{};
  bool _pressedOther = false;

  static final _ctrl = {LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight};
  static final _alt = {LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight};
  static final _shift = {LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight};
  static final _meta = {LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight};
  static final _rightMods = {
    LogicalKeyboardKey.controlRight: 'RightCtrl',
    LogicalKeyboardKey.altRight: 'RightAlt',
    LogicalKeyboardKey.shiftRight: 'RightShift',
  };
  static final _named = {
    LogicalKeyboardKey.capsLock: 'CapsLock',
    LogicalKeyboardKey.scrollLock: 'ScrollLock',
    LogicalKeyboardKey.pause: 'Pause',
    LogicalKeyboardKey.insert: 'Insert',
    LogicalKeyboardKey.space: 'Space',
    LogicalKeyboardKey.backquote: 'Backquote',
  };
  static final _fKeys = [
    LogicalKeyboardKey.f1, LogicalKeyboardKey.f2, LogicalKeyboardKey.f3, LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5, LogicalKeyboardKey.f6, LogicalKeyboardKey.f7, LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9, LogicalKeyboardKey.f10, LogicalKeyboardKey.f11, LogicalKeyboardKey.f12,
    LogicalKeyboardKey.f13, LogicalKeyboardKey.f14, LogicalKeyboardKey.f15, LogicalKeyboardKey.f16,
    LogicalKeyboardKey.f17, LogicalKeyboardKey.f18, LogicalKeyboardKey.f19, LogicalKeyboardKey.f20,
    LogicalKeyboardKey.f21, LogicalKeyboardKey.f22, LogicalKeyboardKey.f23, LogicalKeyboardKey.f24,
  ];

  bool _isModifier(LogicalKeyboardKey k) =>
      _ctrl.contains(k) || _alt.contains(k) || _shift.contains(k) || _meta.contains(k);

  /// Name understood by the native hotkey code, or null if unsupported.
  static String? _nameOf(LogicalKeyboardKey k) {
    final named = _named[k];
    if (named != null) return named;
    final f = _fKeys.indexOf(k);
    if (f >= 0) return 'F${f + 1}';
    final id = k.keyId;
    if (id >= LogicalKeyboardKey.keyA.keyId && id <= LogicalKeyboardKey.keyZ.keyId) {
      return String.fromCharCode(0x41 + id - LogicalKeyboardKey.keyA.keyId);
    }
    if (id >= LogicalKeyboardKey.digit0.keyId && id <= LogicalKeyboardKey.digit9.keyId) {
      return String.fromCharCode(0x30 + id - LogicalKeyboardKey.digit0.keyId);
    }
    return null;
  }

  Hotkey _with(String key, Set<LogicalKeyboardKey> mods) => Hotkey(key,
      ctrl: mods.any(_ctrl.contains),
      alt: mods.any(_alt.contains),
      shift: mods.any(_shift.contains),
      meta: mods.any(_meta.contains));

  Future<void> _start() async {
    await dictation.bridge.unregisterHotkey();
    _held.clear();
    _pressedOther = false;
    setState(() => _recording = true);
    _focus.requestFocus();
  }

  Future<void> _stop([Hotkey? result]) async {
    if (!_recording) return;
    setState(() => _recording = false);
    _focus.unfocus();
    if (result != null) {
      widget.onChanged(result); // registers the new hotkey
    } else {
      await dictation.applyHotkey();
    }
  }

  void _hint(String zh, String en) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t(zh, en)), duration: const Duration(seconds: 3)));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!_recording) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (e is KeyDownEvent) {
      if (k == LogicalKeyboardKey.escape && _held.isEmpty) {
        _stop();
      } else if (_isModifier(k)) {
        setState(() => _held.add(k));
      } else {
        _pressedOther = true;
        final name = _nameOf(k);
        final letterOrDigit = name != null && name.length == 1;
        if (name == null) {
          _hint('不支持这个按键，请换一个', 'That key is not supported, try another');
        } else if (letterOrDigit && _held.isEmpty) {
          _hint('字母和数字需要搭配 Ctrl / Alt / Shift / Win', 'Letters and digits need Ctrl / Alt / Shift / Win');
        } else {
          _stop(_with(name, _held));
        }
      }
    } else if (e is KeyUpEvent && _isModifier(k)) {
      if (!_pressedOther) {
        // Only modifiers were pressed: a right-hand one becomes the key.
        final right = _rightMods.containsKey(k) ? k : _held.where(_rightMods.containsKey).firstOrNull;
        if (right != null) {
          _stop(_with(_rightMods[right]!, _held.difference({right})));
          return KeyEventResult.handled;
        }
        if (_held.length == 1) {
          _hint('单独的左侧修饰键会和常用快捷键冲突，请用右侧的 Ctrl / Alt / Shift，或组合键',
              'A left modifier alone clashes with common shortcuts; use a right-hand one or a combination');
        }
      }
      setState(() => _held.remove(k));
      if (_held.isEmpty) _pressedOther = false;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    if (_recording) dictation.applyHotkey();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = Platform.isWindows ? 'Win' : 'Super';
    final caps = _recording
        ? [
            if (_held.any(_ctrl.contains)) 'Ctrl',
            if (_held.any(_alt.contains)) 'Alt',
            if (_held.any(_shift.contains)) 'Shift',
            if (_held.any(_meta.contains)) meta,
          ]
        : widget.value.label.split(' + ');
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      onFocusChange: (has) {
        if (!has) _stop();
      },
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(140, kControlHeight),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          side: _recording ? BorderSide(color: scheme.primary, width: 1.6) : null,
          backgroundColor: _recording ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
        ),
        onPressed: _recording ? () => _stop() : _start,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_recording ? Icons.radio_button_checked_rounded : Icons.keyboard_rounded,
              size: 18, color: _recording ? kListening : scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          if (_recording && caps.isEmpty)
            Text(t('按下快捷键…', 'Press keys…'), style: TextStyle(color: scheme.primary))
          else
            for (var i = 0; i < caps.length; i++) ...[
              if (i > 0) Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Text('+', style: TextStyle(color: scheme.outline)),
              ),
              _KeyCap(caps[i]),
            ],
          if (_recording && caps.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text('+', style: TextStyle(color: scheme.outline)),
            ),
            Text('…', style: TextStyle(color: scheme.primary)),
          ],
        ]),
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).inputDecorationTheme.fillColor,
        borderRadius: BorderRadius.circular(6),
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant, width: 2),
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          left: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          right: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurface)),
    );
  }
}
