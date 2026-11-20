# examples/panel.cr
#
# A drop-down quick panel: a text entry that slides over the top of the
# screen, above other windows, and hides again when it loses the focus.
# It needs a desktop with the wlr layer shell protocol, such as KDE Plasma,
# sway, Hyprland or niri.
#
#   crystal run examples/panel.cr            starts the app, hidden
#   crystal run examples/panel.cr -- toggle  shows or hides it from another
#                                            process
#
# Shift+Ctrl+Alt+Space toggles it from anywhere once the desktop grants the
# global shortcut; Escape hides it, Shift+Ctrl+T opens a tab and
# Shift+Ctrl+O splits.
require "../src/desktop_kit"

lib LibGtk
  fun gtk_entry_new : Void*
end

module QuickPanel
  APP_ID = "org.example.QuickPanel"

  PANEL = DesktopKit::Panel.new(edge: :top, height: 400, layer: :overlay,
    hide_on_focus_loss: true, name: "quick")

  TOGGLE = DesktopKit::Action::TogglePanel.new(PANEL.name)

  class App < DesktopKit::App
    def initialize
      super(APP_ID)
    end

    protected def new_surface(context : DesktopKit::SurfaceContext) : DesktopKit::Content
      DesktopKit::WidgetContent.new(DesktopKit::Widget.new(LibGtk.gtk_entry_new))
    end

    protected def on_startup : Nil
      self.bindings = [
        DesktopKit::Binding.new("ctrl+shift+alt+space", TOGGLE, global: true),
        DesktopKit::Binding.new("Escape", TOGGLE),
        DesktopKit::Binding.new("ctrl+shift+t", DesktopKit::Action::NewTab.new),
        DesktopKit::Binding.new("ctrl+shift+o", DesktopKit::Action::NewSplit.new(:right)),
      ]
    end

    protected def on_activate : Nil
      unless panels?
        STDERR.puts "This desktop cannot show panels."
        quit
        return
      end
      new_panel(PANEL, shown: false) if windows.empty?
      puts "Running hidden; press #{DesktopKit::Trigger.parse("ctrl+shift+alt+space").label} or run with `toggle`."
    end

    protected def on_binding_failed(binding : DesktopKit::Binding, message : String) : Nil
      puts "#{binding.trigger.label} is not bound: #{message}"
    end
  end
end

if ARGV.first? == "toggle"
  begin
    DesktopKit::IPC.send(QuickPanel::APP_ID, QuickPanel::TOGGLE)
  rescue ex : DesktopKit::GLibError | ArgumentError
    STDERR.puts "#{QuickPanel::APP_ID}: #{ex.message}"
    exit 1
  end
else
  exit QuickPanel::App.new.run
end
