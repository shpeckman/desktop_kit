# examples/hello.cr
#
# Text entries in windows, tabs and splits, with key bindings, a global
# binding, notifications and configuration reload.
#
#   crystal run examples/hello.cr
#
# Shift+Ctrl+T opens a tab, Shift+Ctrl+O and Shift+Ctrl+E split right and
# down, Ctrl+Alt+arrows move between splits, Shift+Ctrl+Enter zooms a split,
# Shift+Ctrl+W closes it and Shift+Ctrl+B sends a notification that brings
# its split back when clicked. Shift+Ctrl+R or `kill -USR2 <pid>` reloads
# the style; Shift+Ctrl+Alt+H opens a window from anywhere once the desktop
# grants the global shortcut. `examples/ipc.cr` opens a window from another
# process.
require "../src/apprt"

lib LibGtk
  fun gtk_entry_new : Void*
end

module Hello
  Apprt.action Notify, "notify", scope: :split

  STYLES = [
    "entry { font-size: 14pt; }",
    "entry { font-size: 18pt; }",
  ]

  class App < Apprt::App
    @style = 0

    protected def new_surface(context : Apprt::SurfaceContext) : Apprt::Content
      Apprt::WidgetContent.new(Apprt::Widget.new(LibGtk.gtk_entry_new))
    end

    protected def on_startup : Nil
      self.css = STYLES[@style]
      self.bindings = [
        Apprt::Binding.new("ctrl+shift+n", Apprt::Action::NewWindow.new),
        Apprt::Binding.new("ctrl+shift+t", Apprt::Action::NewTab.new),
        Apprt::Binding.new("ctrl+shift+o", Apprt::Action::NewSplit.new(:right)),
        Apprt::Binding.new("ctrl+shift+e", Apprt::Action::NewSplit.new(:down)),
        Apprt::Binding.new("ctrl+alt+left", Apprt::Action::GotoSplit.new(:left)),
        Apprt::Binding.new("ctrl+alt+right", Apprt::Action::GotoSplit.new(:right)),
        Apprt::Binding.new("ctrl+alt+up", Apprt::Action::GotoSplit.new(:up)),
        Apprt::Binding.new("ctrl+alt+down", Apprt::Action::GotoSplit.new(:down)),
        Apprt::Binding.new("ctrl+shift+enter", Apprt::Action::ToggleSplitZoom.new),
        Apprt::Binding.new("ctrl+shift+w", Apprt::Action::CloseSurface.new),
        Apprt::Binding.new("ctrl+shift+b", Notify.new),
        Apprt::Binding.new("ctrl+shift+r", Apprt::Action::ReloadConfig.new),
        Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new),
        Apprt::Binding.new("ctrl+shift+alt+h", Apprt::Action::NewWindow.new, global: true),
      ]
    end

    protected def on_activate : Nil
      new_window
    end

    # Switches between the styles, as a reread configuration would.
    protected def on_reload : Nil
      @style = (@style + 1) % STYLES.size
      self.css = STYLES[@style]
      puts "reloaded: #{STYLES[@style]}"
    end

    protected def on_binding_failed(binding : Apprt::Binding, message : String) : Nil
      puts "#{binding.trigger.label} is not bound: #{message}"
    end

    protected def perform(target : Apprt::Surface, action : Notify) : Bool
      target.notify("Hello", "Split #{target.id} wants attention")
      true
    end
  end
end

exit Hello::App.new("org.example.Hello").run
