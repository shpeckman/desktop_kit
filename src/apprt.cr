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
require "./apprt/c/gtk"
require "./apprt/c/adw"
require "./apprt/c/manual"
require "./apprt/glib/error"
require "./apprt/glib/native"
require "./apprt/glib/handles"
require "./apprt/glib/wrapper"
require "./apprt/glib/variant"
require "./apprt/glib/widget"
require "./apprt/glib/signals"
require "./apprt/glib/idle"
require "./apprt/types"
require "./apprt/split_tree"
require "./apprt/ui_thread"
require "./apprt/action"
require "./apprt/actions"
require "./apprt/trigger"
require "./apprt/systemd"
require "./apprt/app"
require "./apprt/binding"
require "./apprt/dialogs"
require "./apprt/content"
require "./apprt/input"
require "./apprt/canvas"
require "./apprt/clipboard"
require "./apprt/surface"
require "./apprt/split_view"
require "./apprt/tab"
require "./apprt/window"

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
