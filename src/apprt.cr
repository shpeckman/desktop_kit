# src/apprt.cr
#
# apprt - a native application runtime for Crystal programs on Linux:
# GTK 4 and libadwaita windows, tabs, splits and surfaces, actions, desktop
# notifications, global shortcuts, DBus IPC and systemd integration.
require "log"
require "./apprt/c/glib"
require "./apprt/c/gobject"
require "./apprt/c/gio"
require "./apprt/c/gdk"
require "./apprt/c/gdkwayland"
require "./apprt/c/gtk"
require "./apprt/c/adw"
require "./apprt/c/manual"
require "./apprt/c/wayland"
require "./apprt/glib/error"
require "./apprt/glib/native"
require "./apprt/glib/handles"
require "./apprt/glib/wrapper"
require "./apprt/glib/variant"
require "./apprt/glib/widget"
require "./apprt/glib/signals"
require "./apprt/glib/idle"
require "./apprt/glib/stream"
require "./apprt/source"
require "./apprt/types"
require "./apprt/icon"
require "./apprt/key"
require "./apprt/split_tree"
require "./apprt/ui_thread"
require "./apprt/action"
require "./apprt/actions"
require "./apprt/trigger"
require "./apprt/systemd"
require "./apprt/wayland"
require "./apprt/winproto"
require "./apprt/app"
require "./apprt/bell"
require "./apprt/config_errors"
require "./apprt/binding"
require "./apprt/dialogs"
require "./apprt/content"
require "./apprt/input"
require "./apprt/drag"
require "./apprt/gl"
require "./apprt/canvas"
require "./apprt/clipboard"
require "./apprt/surface"
require "./apprt/split_view"
require "./apprt/tab"
require "./apprt/window"
require "./apprt/window_style"
require "./apprt/undo_stack"
require "./apprt/progress"
require "./apprt/command_palette"
require "./apprt/preferences"
require "./apprt/notifications"
require "./apprt/ipc"
require "./apprt/portal"
require "./apprt/global_shortcuts"
require "./apprt/open_uri"
require "./apprt/user_idle"
require "./apprt/dbus"

# Native application runtime: GTK 4 and libadwaita windows, tabs, splits and
# surfaces driven by typed actions.
#
# Exceptions raised by callbacks that GTK runs are logged to the `"apprt"`
# `::Log` source.
module Apprt
  VERSION = "0.1.0"

  # :nodoc:
  Log = ::Log.for("apprt")
end
