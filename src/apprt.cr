# src/apprt.cr
#
# apprt - a native application runtime for Crystal programs on Linux:
# GTK 4 and libadwaita windows, tabs, splits and surfaces, actions, desktop
# notifications, global shortcuts, DBus IPC and systemd integration.
require "./apprt/c/glib"
require "./apprt/c/gobject"
require "./apprt/c/gio"
require "./apprt/c/gdk"
require "./apprt/c/gtk"
require "./apprt/c/adw"
require "./apprt/c/manual"

# Native application runtime: GTK 4 and libadwaita windows, tabs, splits and
# surfaces driven by typed actions.
module Apprt
  VERSION = "0.1.0"
end
