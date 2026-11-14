# examples/workspace.cr
#
# A workspace in the card style: pane headers with icons, tabs in the
# header bar, a translucent blurred window, dimmed unfocused splits, the
# command palette, tmux-like key sequences and a key table.
#
#   crystal run examples/workspace.cr
#
# Shift+Ctrl+P or the search button opens the command palette, which also
# toggles each part of the style. Ctrl+A starts a sequence: then C opens a
# tab, R and D split right and down, Z zooms, X closes the split, N and P
# move to the next and previous tab, H, J, K and L move between splits,
# and E enters the resize table, where H, J, K and L resize the split
# until Esc.
require "../src/apprt"

lib LibGtk
  fun gtk_text_view_new : Void*
  fun gtk_text_view_set_monospace(view : Void*, monospace : Int32)
  fun gtk_text_view_set_left_margin(view : Void*, margin : Int32)
  fun gtk_text_view_set_top_margin(view : Void*, margin : Int32)
end

module Workspace
  # The parts of the window style the palette toggles.
  enum Look
    PaneHeaders
    Cards
    TabsInHeader
    Translucent
    DimUnfocused
  end

  Apprt.action ToggleLook, "toggle-look", payload: {look: Look}

  # Icons the surfaces take in turn.
  ICONS = %w(utilities-terminal text-editor accessories-text-editor system-run)

  CSS = <<-CSS
    textview { font-size: 12pt; background: none; }
    CSS

  class App < Apprt::App
    @looks = Look.values.to_set
    @count = 0

    protected def new_surface(context : Apprt::SurfaceContext) : Apprt::Content
      view = LibGtk.gtk_text_view_new
      LibGtk.gtk_text_view_set_monospace(view, 1)
      LibGtk.gtk_text_view_set_left_margin(view, 12)
      LibGtk.gtk_text_view_set_top_margin(view, 8)
      pane = Pane.new(Apprt::Widget.new(view), @count += 1)
      post { pane.name_surface }
      pane
    end

    protected def on_startup : Nil
      self.css = CSS
      self.window_style = style
      self.commands = Apprt::Command.defaults + Look.values.map do |look|
        Apprt::Command.new("Toggle #{look.to_s.underscore.tr("_", " ").capitalize}", ToggleLook.new(look), "style look")
      end
      self.key_tables = {
        "resize" => [
          Apprt::Binding.new("h", Apprt::Action::ResizeSplit.new(:left, 20)),
          Apprt::Binding.new("l", Apprt::Action::ResizeSplit.new(:right, 20)),
          Apprt::Binding.new("k", Apprt::Action::ResizeSplit.new(:up, 20)),
          Apprt::Binding.new("j", Apprt::Action::ResizeSplit.new(:down, 20)),
          Apprt::Binding.new("esc", Apprt::Action::DeactivateKeyTable.new),
        ],
      }
      self.bindings = [
        Apprt::Binding.new("ctrl+shift+p", Apprt::Action::ToggleCommandPalette.new),
        Apprt::Binding.new("ctrl+a>c", Apprt::Action::NewTab.new),
        Apprt::Binding.new("ctrl+a>r", Apprt::Action::NewSplit.new(:right)),
        Apprt::Binding.new("ctrl+a>d", Apprt::Action::NewSplit.new(:down)),
        Apprt::Binding.new("ctrl+a>z", Apprt::Action::ToggleSplitZoom.new),
        Apprt::Binding.new("ctrl+a>x", Apprt::Action::CloseSurface.new),
        Apprt::Binding.new("ctrl+a>n", Apprt::Action::GotoTab.new(Apprt::Action::GotoTab::NEXT)),
        Apprt::Binding.new("ctrl+a>p", Apprt::Action::GotoTab.new(Apprt::Action::GotoTab::PREVIOUS)),
        Apprt::Binding.new("ctrl+a>h", Apprt::Action::GotoSplit.new(:left)),
        Apprt::Binding.new("ctrl+a>l", Apprt::Action::GotoSplit.new(:right)),
        Apprt::Binding.new("ctrl+a>k", Apprt::Action::GotoSplit.new(:up)),
        Apprt::Binding.new("ctrl+a>j", Apprt::Action::GotoSplit.new(:down)),
        Apprt::Binding.new("ctrl+a>e", Apprt::Action::ActivateKeyTable.new("resize")),
        Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new),
      ]
    end

    protected def on_activate : Nil
      new_window
    end

    protected def on_window(window : Apprt::Window) : Nil
      window.subtitle = System.hostname
      window.pack_end(Apprt::Action::ToggleCommandPalette.new, "system-search-symbolic", "Command Palette")
      window.background_blur = true
    end

    protected def perform(target : Apprt::App, action : ToggleLook) : Bool
      @looks.includes?(action.look) ? @looks.delete(action.look) : @looks.add(action.look)
      self.window_style = style
      true
    end

    private def style : Apprt::WindowStyle
      Apprt::WindowStyle.new(
        pane_headers: @looks.includes?(Look::PaneHeaders),
        cards: @looks.includes?(Look::Cards),
        tabs_in_header: @looks.includes?(Look::TabsInHeader),
        opacity: @looks.includes?(Look::Translucent) ? 0.85 : 1.0,
        unfocused_opacity: @looks.includes?(Look::DimUnfocused) ? 0.6 : 1.0)
    end
  end

  # A text view that gives its surface a numbered title and an icon.
  class Pane < Apprt::WidgetContent
    def initialize(widget : Apprt::Widget, @number : Int32)
      super(widget)
    end

    # Names the surface; the surface exists once `App#new_surface` returned.
    def name_surface : Nil
      surface.title = "Pane #{@number}"
      surface.icon = ICONS[(@number - 1) % ICONS.size]
    end
  end
end

exit Workspace::App.new("org.example.Workspace").run
