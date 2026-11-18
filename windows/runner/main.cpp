#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "openspeak_native.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single instance: a second launch (e.g. from the taskbar while the window
  // sits in the tray) asks the running instance to show itself and exits.
  HANDLE instance_mutex = ::CreateMutexW(nullptr, FALSE, L"Local\\OpenSpeak.SingleInstance");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"OpenSpeak")) {
      DWORD pid = 0;
      ::GetWindowThreadProcessId(existing, &pid);
      // We are the foreground process; let the running one take focus.
      ::AllowSetForegroundWindow(pid);
      ::PostMessageW(existing, OpenSpeakNative::kActivateMessage, 0, 0);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1000, 700);
  if (!window.Create(L"OpenSpeak", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
