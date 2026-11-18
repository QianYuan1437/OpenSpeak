#ifndef RUNNER_OPENSPEAK_NATIVE_H_
#define RUNNER_OPENSPEAK_NATIVE_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

// Implements the "openspeak/native" channel on Windows: a low-level keyboard
// hook for the push-to-talk hotkey, Unicode text injection via SendInput and
// the focus-less always-on-top "pill" window mode.
class OpenSpeakNative {
 public:
  OpenSpeakNative(flutter::BinaryMessenger* messenger, HWND window);
  ~OpenSpeakNative();

  // Lets the pill mode override window_manager's minimum size. Returns a
  // result when the message was handled.
  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

  static constexpr UINT kHotkeyMessage = WM_APP + 0x51;
  // Posted by a second OpenSpeak process asking this one to show itself.
  static constexpr UINT kActivateMessage = WM_APP + 0x52;

 private:
  void OnMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool RegisterHotkey(const flutter::EncodableMap& args);
  void UnregisterHotkey();
  bool TypeText(const std::wstring& text);
  bool SendPaste();
  void EnterPill(double width, double height, const std::string& position, double opacity);
  void ExitPill();
  void SetTitleBar(int64_t argb, bool dark);

  static LRESULT CALLBACK KeyboardProc(int code, WPARAM wparam, LPARAM lparam);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // Hotkey state (only one hotkey at a time).
  HHOOK hook_ = nullptr;
  DWORD vk_ = 0;
  bool need_ctrl_ = false, need_alt_ = false, need_shift_ = false, need_win_ = false;
  bool key_down_ = false;

  // Pill state.
  bool in_pill_ = false;
  WINDOWPLACEMENT saved_placement_{sizeof(WINDOWPLACEMENT)};
  LONG_PTR saved_style_ = 0;
  LONG_PTR saved_ex_style_ = 0;

  static OpenSpeakNative* instance_;
};

#endif  // RUNNER_OPENSPEAK_NATIVE_H_
