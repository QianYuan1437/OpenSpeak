#include "openspeak_native.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#ifdef GDK_WINDOWING_X11
#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <gdk/gdkx.h>
#endif

namespace {

struct NativeState {
  GtkWindow* window = nullptr;
  FlMethodChannel* channel = nullptr;
  // Hotkey
  int keycode = 0;
  unsigned int modifiers = 0;
  unsigned int self_mask = 0;
  bool filter_installed = false;
  // Pill
  bool in_pill = false;
  int saved_x = 0, saved_y = 0, saved_w = 0, saved_h = 0;
};

NativeState g_state;

#ifdef GDK_WINDOWING_X11

Display* x_display() {
  GdkDisplay* d = gdk_display_get_default();
  if (!GDK_IS_X11_DISPLAY(d)) return nullptr;
  return GDK_DISPLAY_XDISPLAY(d);
}

KeySym keysym_for(const std::string& name) {
  static const std::map<std::string, KeySym> table = {
      {"RightCtrl", XK_Control_R}, {"RightAlt", XK_Alt_R},
      {"RightShift", XK_Shift_R},  {"CapsLock", XK_Caps_Lock},
      {"ScrollLock", XK_Scroll_Lock}, {"Pause", XK_Pause},
      {"Insert", XK_Insert},       {"Space", XK_space},
      {"Backquote", XK_grave},
  };
  auto it = table.find(name);
  if (it != table.end()) return it->second;
  if (name.size() >= 2 && name[0] == 'F') {
    int n = atoi(name.c_str() + 1);
    if (n >= 1 && n <= 24) return XK_F1 + (n - 1);
  }
  return NoSymbol;
}

// Lock-key combinations that must also be grabbed so NumLock/CapsLock being
// on does not break the hotkey.
const unsigned int kLockMasks[] = {0, LockMask, Mod2Mask, LockMask | Mod2Mask};

// A modifier used as the hotkey (e.g. Right Ctrl) may be pressed while its
// twin is already down, so also grab the combination carrying its own mask.
unsigned int self_mask(KeySym sym) {
  switch (sym) {
    case XK_Control_R: return ControlMask;
    case XK_Shift_R: return ShiftMask;
    case XK_Alt_R: return Mod1Mask;
    default: return 0;
  }
}

std::vector<unsigned int> combos(unsigned int mods, unsigned int self) {
  std::vector<unsigned int> out;
  for (unsigned int extra : kLockMasks) {
    out.push_back(mods | extra);
    if (self != 0 && (mods & self) == 0) out.push_back(mods | self | extra);
  }
  return out;
}

void ungrab() {
  Display* dpy = x_display();
  if (!dpy || g_state.keycode == 0) return;
  Window root = DefaultRootWindow(dpy);
  for (unsigned int m : combos(g_state.modifiers, g_state.self_mask)) {
    XUngrabKey(dpy, g_state.keycode, m, root);
  }
  XFlush(dpy);
  g_state.keycode = 0;
}

void send_event(const char* method) {
  if (g_state.channel == nullptr) return;
  fl_method_channel_invoke_method(g_state.channel, method, nullptr, nullptr,
                                  nullptr, nullptr);
}

GdkFilterReturn key_filter(GdkXEvent* gxevent, GdkEvent* event, gpointer data) {
  XEvent* xe = static_cast<XEvent*>(gxevent);
  if (g_state.keycode == 0) return GDK_FILTER_CONTINUE;
  if ((xe->type == KeyPress || xe->type == KeyRelease) &&
      static_cast<int>(xe->xkey.keycode) == g_state.keycode) {
    send_event(xe->type == KeyPress ? "hotkeyDown" : "hotkeyUp");
    return GDK_FILTER_REMOVE;
  }
  return GDK_FILTER_CONTINUE;
}

bool grab(const std::string& key, bool ctrl, bool alt, bool shift, bool meta) {
  Display* dpy = x_display();
  if (!dpy) return false;  // Wayland session: no global grabs.
  ungrab();
  KeySym sym = keysym_for(key);
  if (sym == NoSymbol) return false;
  int code = XKeysymToKeycode(dpy, sym);
  if (code == 0) return false;
  unsigned int mods = (ctrl ? ControlMask : 0) | (alt ? Mod1Mask : 0) |
                      (shift ? ShiftMask : 0) | (meta ? Mod4Mask : 0);
  GdkDisplay* gd = gdk_display_get_default();
  Window root = DefaultRootWindow(dpy);
  unsigned int self = self_mask(sym);
  gdk_x11_display_error_trap_push(gd);
  for (unsigned int m : combos(mods, self)) {
    XGrabKey(dpy, code, m, root, False, GrabModeAsync, GrabModeAsync);
  }
  XSync(dpy, False);
  if (gdk_x11_display_error_trap_pop(gd) != 0) {
    // Someone else owns this combination.
    gdk_x11_display_error_trap_push(gd);
    for (unsigned int m : combos(mods, self)) XUngrabKey(dpy, code, m, root);
    XSync(dpy, False);
    gdk_x11_display_error_trap_pop_ignored(gd);
    return false;
  }
  // Report a held key as one press + one release instead of auto-repeat pairs.
  Bool supported = False;
  XkbSetDetectableAutoRepeat(dpy, True, &supported);
  g_state.keycode = code;
  g_state.modifiers = mods;
  g_state.self_mask = self;
  if (!g_state.filter_installed) {
    // Like keybinder: grabbed key events arrive on the root window.
    gdk_window_add_filter(gdk_get_default_root_window(), key_filter, nullptr);
    g_state.filter_installed = true;
  }
  return true;
}

#endif  // GDK_WINDOWING_X11

// Capsule-shaped input/paint region built from one rectangle per scanline.
cairo_region_t* capsule_region(int w, int h) {
  cairo_region_t* region = cairo_region_create();
  double r = h / 2.0;
  for (int y = 0; y < h; y++) {
    double dy = r - (y + 0.5);
    int inset = static_cast<int>(r - std::sqrt(std::max(0.0, r * r - dy * dy)));
    cairo_rectangle_int_t row = {inset, y, w - 2 * inset, 1};
    cairo_region_union_rectangle(region, &row);
  }
  return region;
}

void enter_pill(int w, int h, const std::string& position, double opacity) {
  GtkWindow* win = g_state.window;
  if (!g_state.in_pill) {
    gtk_window_get_position(win, &g_state.saved_x, &g_state.saved_y);
    gtk_window_get_size(win, &g_state.saved_w, &g_state.saved_h);
  }
  g_state.in_pill = true;
  gtk_widget_hide(GTK_WIDGET(win));
  GdkGeometry geo;
  geo.min_width = w;
  geo.min_height = h;
  gtk_window_set_geometry_hints(win, nullptr, &geo, GDK_HINT_MIN_SIZE);
  gtk_window_set_decorated(win, FALSE);
  gtk_window_set_keep_above(win, TRUE);
  gtk_window_set_accept_focus(win, FALSE);
  gtk_window_set_focus_on_map(win, FALSE);
  gtk_window_set_skip_taskbar_hint(win, TRUE);
  gtk_window_set_skip_pager_hint(win, TRUE);
  gtk_window_set_type_hint(win, GDK_WINDOW_TYPE_HINT_NOTIFICATION);
  gtk_window_resize(win, w, h);

  // Bottom-centre of the monitor under the pointer, above any panel.
  GdkDisplay* display = gdk_display_get_default();
  GdkSeat* seat = gdk_display_get_default_seat(display);
  int px = 0, py = 0;
  gdk_device_get_position(gdk_seat_get_pointer(seat), nullptr, &px, &py);
  GdkMonitor* mon = gdk_display_get_monitor_at_point(display, px, py);
  GdkRectangle wa;
  gdk_monitor_get_workarea(mon, &wa);
  int margin = 72;
  int y = position == "top"      ? wa.y + margin
          : position == "bottom" ? wa.y + wa.height - h - margin
                                 : wa.y + (wa.height - h) / 2;
  gtk_window_move(win, wa.x + (wa.width - w) / 2, y);
  gtk_widget_show(GTK_WIDGET(win));
  // Translucent capsule (opacity needs a compositing window manager).
  cairo_region_t* shape = capsule_region(w, h);
  gtk_widget_shape_combine_region(GTK_WIDGET(win), shape);
  cairo_region_destroy(shape);
  gtk_widget_set_opacity(GTK_WIDGET(win), std::clamp(opacity, 0.3, 1.0));
}

void exit_pill(int min_w, int min_h) {
  if (!g_state.in_pill) return;
  GtkWindow* win = g_state.window;
  g_state.in_pill = false;
  gtk_widget_hide(GTK_WIDGET(win));
  gtk_widget_shape_combine_region(GTK_WIDGET(win), nullptr);
  gtk_widget_set_opacity(GTK_WIDGET(win), 1.0);
  gtk_window_set_keep_above(win, FALSE);
  gtk_window_set_decorated(win, TRUE);
  gtk_window_set_accept_focus(win, TRUE);
  gtk_window_set_focus_on_map(win, TRUE);
  gtk_window_set_skip_taskbar_hint(win, FALSE);
  gtk_window_set_skip_pager_hint(win, FALSE);
  gtk_window_set_type_hint(win, GDK_WINDOW_TYPE_HINT_NORMAL);
  GdkGeometry geo;
  geo.min_width = min_w;
  geo.min_height = min_h;
  gtk_window_set_geometry_hints(win, nullptr, &geo, GDK_HINT_MIN_SIZE);
  if (g_state.saved_w > 0) {
    gtk_window_resize(win, g_state.saved_w, g_state.saved_h);
    gtk_window_move(win, g_state.saved_x, g_state.saved_y);
  }
}

int64_t arg_int(FlValue* args, const char* key, int64_t def) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return def;
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr) return def;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) return fl_value_get_int(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return (int64_t)fl_value_get_float(v);
  return def;
}

double arg_double(FlValue* args, const char* key, double def) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return def;
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr) return def;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) return fl_value_get_int(v);
  return def;
}

bool arg_bool(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return false;
  FlValue* v = fl_value_lookup_string(args, key);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(v);
}

std::string arg_string(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return "";
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return "";
  return fl_value_get_string(v);
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer user_data) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "registerHotkey") == 0) {
    bool ok = false;
#ifdef GDK_WINDOWING_X11
    ok = grab(arg_string(args, "key"), arg_bool(args, "ctrl"), arg_bool(args, "alt"),
              arg_bool(args, "shift"), arg_bool(args, "meta"));
#endif
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(ok)));
  } else if (strcmp(method, "unregisterHotkey") == 0) {
#ifdef GDK_WINDOWING_X11
    ungrab();
#endif
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "enterPill") == 0) {
    enter_pill(arg_int(args, "width", 440), arg_int(args, "height", 72),
               arg_string(args, "position"), arg_double(args, "opacity", 0.85));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "exitPill") == 0) {
    exit_pill(arg_int(args, "minWidth", 760), arg_int(args, "minHeight", 540));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "isWindowActive") == 0) {
    GtkWindow* win = g_state.window;
    bool active = gtk_widget_get_visible(GTK_WIDGET(win)) && gtk_window_is_active(win) &&
                  !g_state.in_pill;
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(active)));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void openspeak_native_init(GtkWindow* window, FlView* view) {
  g_state.window = window;
  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_state.channel = fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                                          "openspeak/native", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_state.channel, method_call_cb, nullptr,
                                            nullptr);
}
