#ifndef RUNNER_OPENSPEAK_NATIVE_H_
#define RUNNER_OPENSPEAK_NATIVE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Registers the "openspeak/native" method channel: X11 global hotkey with
// press/release events and the focus-less recording pill window mode.
void openspeak_native_init(GtkWindow* window, FlView* view);

#endif  // RUNNER_OPENSPEAK_NATIVE_H_
