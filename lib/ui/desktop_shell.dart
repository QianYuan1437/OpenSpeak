import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../core/dictation.dart';
import '../core/native_bridge.dart';
import 'i18n.dart';

/// Window + system tray behaviour for Windows/Linux: closing the window keeps
/// OpenSpeak running in the tray so the global hotkey stays available.
class DesktopShell with WindowListener, TrayListener {
  DesktopShell._();
  static final _instance = DesktopShell._();

  static Future<void> init({bool forceShow = false}) async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1000, 700),
      minimumSize: Size(760, 540),
      center: true,
      title: 'OpenSpeak',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (forceShow || !settings.startHidden) {
        await windowManager.show();
        await windowManager.focus();
      }
    });
    await windowManager.setPreventClose(true);
    windowManager.addListener(_instance);
    await _instance._initTray();
    dictation.addListener(_instance._syncTray);
    dictation.bridge.events.where((e) => e == NativeEvent.activate).listen((_) {
      if (!dictation.pillMode) showMain();
    });
  }

  DictationState? _trayState;

  Future<void> _initTray() async {
    await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray/tray.ico' : 'assets/tray/tray.png');
    if (!Platform.isLinux) await trayManager.setToolTip('OpenSpeak');
    trayManager.addListener(this);
    await _buildMenu();
  }

  Future<void> _buildMenu() async {
    final listening = dictation.state == DictationState.listening;
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: t('打开 OpenSpeak', 'Open OpenSpeak')),
      MenuItem(
          key: 'toggle',
          label: listening ? t('停止听写', 'Stop dictation') : t('开始听写', 'Start dictation')),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: t('退出', 'Quit')),
    ]));
  }

  void _syncTray() {
    final s = dictation.state;
    if (s == _trayState) return;
    final wasListening = _trayState == DictationState.listening;
    _trayState = s;
    final listening = s == DictationState.listening;
    if (listening != wasListening) {
      _buildMenu();
      trayManager.setIcon(listening
          ? (Platform.isWindows ? 'assets/tray/tray_rec.ico' : 'assets/tray/tray_rec.png')
          : (Platform.isWindows ? 'assets/tray/tray.ico' : 'assets/tray/tray.png'));
    }
  }

  static Future<void> showMain() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() => windowManager.hide();

  @override
  void onTrayIconMouseDown() => showMain();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await showMain();
      case 'toggle':
        await dictation.toggle(external: true);
      case 'quit':
        await dictation.capture.stop();
        await trayManager.destroy();
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
        exit(0);
    }
  }
}
