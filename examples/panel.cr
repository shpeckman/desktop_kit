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
require "../src/apprt"

lib LibGtk
  fun gtk_entry_new : Void*
end

module QuickPanel
  APP_ID = "org.example.QuickPanel"

  PANEL = Apprt::Panel.new(edge: :top, height: 400, layer: :overlay,
    hide_on_focus_loss: true, name: "quick")

  TOGGLE = Apprt::Action::TogglePanel.new(PANEL.name)

  class App < Apprt::App
    def initialize
      super(APP_ID)
    end

    protected def new_surface(context : Apprt::SurfaceContext) : Apprt::Content
      Apprt::WidgetContent.new(Apprt::Widget.new(LibGtk.gtk_entry_new))
    end

    protected def on_startup : Nil
      self.bindings = [
        Apprt::Binding.new("ctrl+shift+alt+space", TOGGLE, global: true),
        Apprt::Binding.new("Escape", TOGGLE),
        Apprt::Binding.new("ctrl+shift+t", Apprt::Action::NewTab.new),
        Apprt::Binding.new("ctrl+shift+o", Apprt::Action::NewSplit.new(:right)),
      ]
    end

    protected def on_activate : Nil
      unless panels?
        STDERR.puts "This desktop cannot show panels."
        quit
        return
      end
      new_panel(PANEL, shown: false) if windows.empty?
      puts "Running hidden; press #{Apprt::Trigger.parse("ctrl+shift+alt+space").label} or run with `toggle`."
    end

    protected def on_binding_failed(binding : Apprt::Binding, message : String) : Nil
      puts "#{binding.trigger.label} is not bound: #{message}"
    end
  end
end

if ARGV.first? == "toggle"
  begin
    Apprt::IPC.send(QuickPanel::APP_ID, QuickPanel::TOGGLE)
  rescue ex : Apprt::GLibError | ArgumentError
    STDERR.puts "#{QuickPanel::APP_ID}: #{ex.message}"
    exit 1
  end
else
  exit QuickPanel::App.new.run
end
