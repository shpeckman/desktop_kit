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
require "../src/desktop_kit"

lib LibGtk
  fun gtk_entry_new : Void*
end

module Hello
  DesktopKit.action Notify, "notify", scope: :split

  STYLES = [
    "entry { font-size: 14pt; }",
    "entry { font-size: 18pt; }",
  ]

  class App < DesktopKit::App
    @style = 0

    protected def new_surface(context : DesktopKit::SurfaceContext) : DesktopKit::Content
      DesktopKit::WidgetContent.new(DesktopKit::Widget.new(LibGtk.gtk_entry_new))
    end

    protected def on_startup : Nil
      self.css = STYLES[@style]
      self.bindings = [
        DesktopKit::Binding.new("ctrl+shift+n", DesktopKit::Action::NewWindow.new),
        DesktopKit::Binding.new("ctrl+shift+t", DesktopKit::Action::NewTab.new),
        DesktopKit::Binding.new("ctrl+shift+o", DesktopKit::Action::NewSplit.new(:right)),
        DesktopKit::Binding.new("ctrl+shift+e", DesktopKit::Action::NewSplit.new(:down)),
        DesktopKit::Binding.new("ctrl+alt+left", DesktopKit::Action::GotoSplit.new(:left)),
        DesktopKit::Binding.new("ctrl+alt+right", DesktopKit::Action::GotoSplit.new(:right)),
        DesktopKit::Binding.new("ctrl+alt+up", DesktopKit::Action::GotoSplit.new(:up)),
        DesktopKit::Binding.new("ctrl+alt+down", DesktopKit::Action::GotoSplit.new(:down)),
        DesktopKit::Binding.new("ctrl+shift+enter", DesktopKit::Action::ToggleSplitZoom.new),
        DesktopKit::Binding.new("ctrl+shift+w", DesktopKit::Action::CloseSurface.new),
        DesktopKit::Binding.new("ctrl+shift+b", Notify.new),
        DesktopKit::Binding.new("ctrl+shift+r", DesktopKit::Action::ReloadConfig.new),
        DesktopKit::Binding.new("ctrl+q", DesktopKit::Action::Quit.new),
        DesktopKit::Binding.new("ctrl+shift+alt+h", DesktopKit::Action::NewWindow.new, global: true),
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

    protected def on_binding_failed(binding : DesktopKit::Binding, message : String) : Nil
      puts "#{binding.trigger.label} is not bound: #{message}"
    end

    protected def perform(target : DesktopKit::Surface, action : Notify) : Bool
      target.notify("Hello", "Split #{target.id} wants attention")
      true
    end
  end
end

exit Hello::App.new("org.example.Hello").run
