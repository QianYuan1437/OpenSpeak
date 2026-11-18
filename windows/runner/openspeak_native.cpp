#include "openspeak_native.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cctype>
#include <map>
#include <string>
#include <vector>

OpenSpeakNative* OpenSpeakNative::instance_ = nullptr;

namespace {

// DWMWA_WINDOW_CORNER_PREFERENCE is only in newer SDKs.
constexpr DWORD kCornerPreference = 33;
constexpr DWORD kCornerDefault = 0;

// Tags our own SendInput events so the hook can skip them while still
// accepting input injected by remote-desktop tools or key remappers.
constexpr ULONG_PTR kOwnInputTag = 0x4F53504B;  // 'OSPK'

DWORD VkFor(const std::string& name) {
  static const std::map<std::string, DWORD> table = {
      {"RightCtrl", VK_RCONTROL}, {"RightAlt", VK_RMENU},
      {"RightShift", VK_RSHIFT},  {"CapsLock", VK_CAPITAL},
      {"ScrollLock", VK_SCROLL},  {"Pause", VK_PAUSE},
      {"Insert", VK_INSERT},      {"Space", VK_SPACE},
      {"Backquote", VK_OEM_3},
  };
  auto it = table.find(name);
  if (it != table.end()) return it->second;
  // Letters and digits ("A".."Z", "0".."9"): the VK code is the ASCII code.
  if (name.size() == 1 && (isupper(static_cast<unsigned char>(name[0])) ||
                           isdigit(static_cast<unsigned char>(name[0])))) {
    return static_cast<DWORD>(name[0]);
  }
  if (name.size() >= 2 && name[0] == 'F') {
    int n = atoi(name.c_str() + 1);
    if (n >= 1 && n <= 24) return VK_F1 + (n - 1);
  }
  return 0;
}

bool IsDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

int64_t GetInt(const flutter::EncodableMap& m, const char* key, int64_t def) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return def;
  if (const int32_t* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const int64_t* l = std::get_if<int64_t>(&it->second)) return *l;
  return def;
}

bool GetBool(const flutter::EncodableMap& m, const char* key) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return false;
  const bool* b = std::get_if<bool>(&it->second);
  return b != nullptr && *b;
}

std::string GetString(const flutter::EncodableMap& m, const char* key) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return "";
  const std::string* s = std::get_if<std::string>(&it->second);
  return s ? *s : "";
}

double GetDouble(const flutter::EncodableMap& m, const char* key, double def) {
  auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return def;
  if (const double* d = std::get_if<double>(&it->second)) return *d;
  if (const int32_t* i = std::get_if<int32_t>(&it->second)) return *i;
  return def;
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
  return w;
}

INPUT KeyInput(WORD vk, bool up) {
  INPUT in = {};
  in.type = INPUT_KEYBOARD;
  in.ki.wVk = vk;
  in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
  in.ki.dwExtraInfo = kOwnInputTag;
  return in;
}

}  // namespace

OpenSpeakNative::OpenSpeakNative(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  instance_ = this;
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "openspeak/native", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    OnMethodCall(call, std::move(result));
  });
}

OpenSpeakNative::~OpenSpeakNative() {
  UnregisterHotkey();
  instance_ = nullptr;
}

void OpenSpeakNative::OnMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();
  if (method == "registerHotkey" && args) {
    result->Success(flutter::EncodableValue(RegisterHotkey(*args)));
  } else if (method == "unregisterHotkey") {
    UnregisterHotkey();
    result->Success();
  } else if (method == "typeText" && args) {
    result->Success(flutter::EncodableValue(TypeText(Utf8ToWide(GetString(*args, "text")))));
  } else if (method == "sendPaste") {
    result->Success(flutter::EncodableValue(SendPaste()));
  } else if (method == "enterPill" && args) {
    EnterPill(GetDouble(*args, "width", 440), GetDouble(*args, "height", 72),
              GetString(*args, "position"), GetDouble(*args, "opacity", 0.85));
    result->Success();
  } else if (method == "exitPill") {
    ExitPill();
    result->Success();
  } else if (method == "setTitleBar" && args) {
    SetTitleBar(GetInt(*args, "color", 0xFFFFFFFF), GetBool(*args, "dark"));
    result->Success();
  } else if (method == "isWindowActive") {
    bool active = !in_pill_ && IsWindowVisible(window_) && !IsIconic(window_) &&
                  GetForegroundWindow() == window_;
    result->Success(flutter::EncodableValue(active));
  } else {
    result->NotImplemented();
  }
}

// Title bar ------------------------------------------------------------------

void OpenSpeakNative::SetTitleBar(int64_t argb, bool dark) {
  // DWMWA_USE_IMMERSIVE_DARK_MODE: follow the app theme, not the system one.
  BOOL use_dark = dark ? TRUE : FALSE;
  DwmSetWindowAttribute(window_, 20, &use_dark, sizeof(use_dark));
  // Windows 11: paint the caption, its text and the border in the page
  // colours so the title bar blends in (Windows 10 ignores these).
  const COLORREF caption = RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
  const COLORREF text = dark ? RGB(236, 236, 243) : RGB(27, 27, 36);
  constexpr DWORD kBorderColor = 34, kCaptionColor = 35, kTextColor = 36;
  DwmSetWindowAttribute(window_, kCaptionColor, &caption, sizeof(caption));
  DwmSetWindowAttribute(window_, kTextColor, &text, sizeof(text));
  DwmSetWindowAttribute(window_, kBorderColor, &caption, sizeof(caption));
}

// Hotkey ---------------------------------------------------------------------

bool OpenSpeakNative::RegisterHotkey(const flutter::EncodableMap& args) {
  DWORD vk = VkFor(GetString(args, "key"));
  if (vk == 0) return false;
  vk_ = vk;
  need_ctrl_ = GetBool(args, "ctrl");
  need_alt_ = GetBool(args, "alt");
  need_shift_ = GetBool(args, "shift");
  need_win_ = GetBool(args, "meta");
  key_down_ = false;
  if (hook_ == nullptr) {
    hook_ = SetWindowsHookEx(WH_KEYBOARD_LL, KeyboardProc, GetModuleHandle(nullptr), 0);
  }
  return hook_ != nullptr;
}

void OpenSpeakNative::UnregisterHotkey() {
  if (hook_ != nullptr) {
    UnhookWindowsHookEx(hook_);
    hook_ = nullptr;
  }
  vk_ = 0;
}

LRESULT CALLBACK OpenSpeakNative::KeyboardProc(int code, WPARAM wparam, LPARAM lparam) {
  OpenSpeakNative* self = instance_;
  if (code == HC_ACTION && self != nullptr && self->vk_ != 0) {
    const auto* k = reinterpret_cast<KBDLLHOOKSTRUCT*>(lparam);
    // Ignore our own SendInput traffic (tagged), but not other injected input.
    if (k->dwExtraInfo != kOwnInputTag && k->vkCode == self->vk_) {
      bool down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
      bool mods_ok = (!self->need_ctrl_ || IsDown(VK_CONTROL)) &&
                     (!self->need_alt_ || IsDown(VK_MENU)) &&
                     (!self->need_shift_ || IsDown(VK_SHIFT)) &&
                     (!self->need_win_ || IsDown(VK_LWIN) || IsDown(VK_RWIN));
      if (down && (mods_ok || self->key_down_)) {
        if (!self->key_down_) {
          self->key_down_ = true;
          PostMessage(self->window_, kHotkeyMessage, 1, 0);
        }
        return 1;  // swallow, including auto-repeat
      }
      if (!down && self->key_down_) {
        self->key_down_ = false;
        PostMessage(self->window_, kHotkeyMessage, 0, 0);
        return 1;
      }
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

// Text output ----------------------------------------------------------------

bool OpenSpeakNative::TypeText(const std::wstring& text) {
  if (text.empty()) return true;
  std::vector<INPUT> inputs;
  inputs.reserve(text.size() * 2);
  for (wchar_t ch : text) {
    if (ch == L'\r') continue;
    if (ch == L'\n') {
      inputs.push_back(KeyInput(VK_RETURN, false));
      inputs.push_back(KeyInput(VK_RETURN, true));
      continue;
    }
    INPUT in = {};
    in.type = INPUT_KEYBOARD;
    in.ki.wScan = ch;
    in.ki.dwFlags = KEYEVENTF_UNICODE;
    in.ki.dwExtraInfo = kOwnInputTag;
    inputs.push_back(in);
    in.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    inputs.push_back(in);
  }
  UINT sent = SendInput((UINT)inputs.size(), inputs.data(), sizeof(INPUT));
  return sent == inputs.size();
}

bool OpenSpeakNative::SendPaste() {
  INPUT inputs[] = {KeyInput(VK_CONTROL, false), KeyInput('V', false),
                    KeyInput('V', true), KeyInput(VK_CONTROL, true)};
  return SendInput(4, inputs, sizeof(INPUT)) == 4;
}

// Pill window ----------------------------------------------------------------

void OpenSpeakNative::EnterPill(double width, double height, const std::string& position,
                                double opacity) {
  if (!in_pill_) {
    saved_placement_.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(window_, &saved_placement_);
    saved_style_ = GetWindowLongPtr(window_, GWL_STYLE);
    saved_ex_style_ = GetWindowLongPtr(window_, GWL_EXSTYLE);
  }
  in_pill_ = true;

  POINT cursor;
  GetCursorPos(&cursor);
  HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {sizeof(MONITORINFO)};
  GetMonitorInfo(monitor, &info);
  double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  int w = static_cast<int>(width * scale);
  int h = static_cast<int>(height * scale);
  const RECT& wa = info.rcWork;
  int x = wa.left + (wa.right - wa.left - w) / 2;
  int margin = static_cast<int>(72 * scale);
  int y = position == "top"      ? wa.top + margin
          : position == "bottom" ? wa.bottom - h - margin
                                 : wa.top + (wa.bottom - wa.top - h) / 2;

  SetWindowLongPtr(window_, GWL_STYLE, WS_POPUP);
  SetWindowLongPtr(window_, GWL_EXSTYLE,
                   WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_LAYERED);
  // Whole-window translucency + capsule outline.
  BYTE alpha = static_cast<BYTE>(std::clamp(opacity, 0.3, 1.0) * 255);
  SetLayeredWindowAttributes(window_, 0, alpha, LWA_ALPHA);
  DWORD corner = kCornerDefault;
  DwmSetWindowAttribute(window_, kCornerPreference, &corner, sizeof(corner));
  SetWindowRgn(window_, CreateRoundRectRgn(0, 0, w + 1, h + 1, h, h), FALSE);
  SetWindowPos(window_, HWND_TOPMOST, x, y, w, h,
               SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
}

void OpenSpeakNative::ExitPill() {
  if (!in_pill_) return;
  ShowWindow(window_, SW_HIDE);
  in_pill_ = false;
  SetWindowRgn(window_, nullptr, FALSE);
  SetWindowLongPtr(window_, GWL_STYLE, saved_style_ & ~WS_VISIBLE);
  SetWindowLongPtr(window_, GWL_EXSTYLE, saved_ex_style_);
  WINDOWPLACEMENT p = saved_placement_;
  p.showCmd = SW_HIDE;
  SetWindowPlacement(window_, &p);
  SetWindowPos(window_, HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_HIDEWINDOW);
}

std::optional<LRESULT> OpenSpeakNative::HandleMessage(HWND hwnd, UINT message,
                                                      WPARAM wparam, LPARAM lparam) {
  if (message == kHotkeyMessage) {
    channel_->InvokeMethod(wparam ? "hotkeyDown" : "hotkeyUp", nullptr);
    return 0;
  }
  if (message == kActivateMessage) {
    channel_->InvokeMethod("activate", nullptr);
    return 0;
  }
  if (in_pill_ && message == WM_GETMINMAXINFO) {
    auto* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
    mmi->ptMinTrackSize.x = 1;
    mmi->ptMinTrackSize.y = 1;
    return 0;
  }
  if (in_pill_ && message == WM_MOUSEACTIVATE) {
    return MA_NOACTIVATE;
  }
  return std::nullopt;
}
