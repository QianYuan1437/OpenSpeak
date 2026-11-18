import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Start OpenSpeak at sign-in, hidden in the tray.
///
/// Windows: the `OpenSpeak` value under HKCU\...\Run (the same value the
/// installer's "start at sign-in" task writes). Linux: an XDG autostart entry.
class Autostart {
  static bool get supported => Platform.isWindows || Platform.isLinux;

  static const _runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'OpenSpeak';

  static String get _command => '"${Platform.resolvedExecutable}" --hidden';

  static File get _desktopFile =>
      File(p.join(Platform.environment['HOME'] ?? '', '.config', 'autostart', 'openspeak.desktop'));

  static bool get enabled {
    if (Platform.isWindows) return _Registry.read(_runKey, _valueName) != null;
    if (Platform.isLinux) return _desktopFile.existsSync();
    return false;
  }

  static Future<void> setEnabled(bool on) async {
    if (Platform.isWindows) {
      on ? _Registry.write(_runKey, _valueName, _command) : _Registry.delete(_runKey, _valueName);
    } else if (Platform.isLinux) {
      final f = _desktopFile;
      if (on) {
        await f.parent.create(recursive: true);
        await f.writeAsString('[Desktop Entry]\n'
            'Type=Application\n'
            'Name=OpenSpeak\n'
            'Exec=$_command\n'
            'Icon=openspeak\n'
            'X-GNOME-Autostart-enabled=true\n');
      } else if (await f.exists()) {
        await f.delete();
      }
    }
  }
}

/// Minimal HKEY_CURRENT_USER string-value access via advapi32.
class _Registry {
  static const _hkcu = 0x80000001;
  static const _keyRead = 0x20019;
  static const _keyWrite = 0x20006;
  static const _regSz = 1;

  static final _lib = DynamicLibrary.open('advapi32.dll');
  static final _open = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
      int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>('RegOpenKeyExW');
  static final _query = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
      int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>)>(
      'RegQueryValueExW');
  static final _set = _lib.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<Uint8>, Uint32),
      int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)>('RegSetValueExW');
  static final _delete = _lib.lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>), int Function(int, Pointer<Utf16>)>(
      'RegDeleteValueW');
  static final _close = _lib.lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

  static T? _withKey<T>(String path, int access, T? Function(int key) body) {
    return using((arena) {
      final key = arena<IntPtr>();
      if (_open(_hkcu, path.toNativeUtf16(allocator: arena), 0, access, key) != 0) return null;
      try {
        return body(key.value);
      } finally {
        _close(key.value);
      }
    });
  }

  static String? read(String path, String name) => _withKey(path, _keyRead, (key) {
        return using((arena) {
          final size = arena<Uint32>()..value = 2048;
          final buf = arena<Uint8>(2048);
          if (_query(key, name.toNativeUtf16(allocator: arena), nullptr, nullptr, buf, size) != 0) return null;
          return buf.cast<Utf16>().toDartString();
        });
      });

  static bool write(String path, String name, String value) =>
      _withKey(path, _keyWrite, (key) {
        return using((arena) {
          final data = value.toNativeUtf16(allocator: arena);
          return _set(key, name.toNativeUtf16(allocator: arena), 0, _regSz, data.cast(), (value.length + 1) * 2) == 0;
        });
      }) ??
      false;

  static bool delete(String path, String name) =>
      _withKey(path, _keyWrite, (key) => using((arena) => _delete(key, name.toNativeUtf16(allocator: arena)) == 0)) ??
      false;
}
