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
require "../src/desktop_kit"

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

  DesktopKit.action ToggleLook, "toggle-look", payload: {look: Look}

  # Icons the surfaces take in turn.
  ICONS = %w(utilities-terminal text-editor accessories-text-editor system-run)

  CSS = <<-CSS
    textview { font-size: 12pt; background: none; }
    CSS

  class App < DesktopKit::App
    @looks = Look.values.to_set
    @count = 0

    protected def new_surface(context : DesktopKit::SurfaceContext) : DesktopKit::Content
      view = LibGtk.gtk_text_view_new
      LibGtk.gtk_text_view_set_monospace(view, 1)
      LibGtk.gtk_text_view_set_left_margin(view, 12)
      LibGtk.gtk_text_view_set_top_margin(view, 8)
      pane = Pane.new(DesktopKit::Widget.new(view), @count += 1)
      post { pane.name_surface }
      pane
    end

    protected def on_startup : Nil
      self.css = CSS
      self.window_style = style
      self.commands = DesktopKit::Command.defaults + Look.values.map do |look|
        DesktopKit::Command.new("Toggle #{look.to_s.underscore.tr("_", " ").capitalize}", ToggleLook.new(look), "style look")
      end
      self.key_tables = {
        "resize" => [
          DesktopKit::Binding.new("h", DesktopKit::Action::ResizeSplit.new(:left, 20)),
          DesktopKit::Binding.new("l", DesktopKit::Action::ResizeSplit.new(:right, 20)),
          DesktopKit::Binding.new("k", DesktopKit::Action::ResizeSplit.new(:up, 20)),
          DesktopKit::Binding.new("j", DesktopKit::Action::ResizeSplit.new(:down, 20)),
          DesktopKit::Binding.new("esc", DesktopKit::Action::DeactivateKeyTable.new),
        ],
      }
      self.bindings = [
        DesktopKit::Binding.new("ctrl+shift+p", DesktopKit::Action::ToggleCommandPalette.new),
        DesktopKit::Binding.new("ctrl+a>c", DesktopKit::Action::NewTab.new),
        DesktopKit::Binding.new("ctrl+a>r", DesktopKit::Action::NewSplit.new(:right)),
        DesktopKit::Binding.new("ctrl+a>d", DesktopKit::Action::NewSplit.new(:down)),
        DesktopKit::Binding.new("ctrl+a>z", DesktopKit::Action::ToggleSplitZoom.new),
        DesktopKit::Binding.new("ctrl+a>x", DesktopKit::Action::CloseSurface.new),
        DesktopKit::Binding.new("ctrl+a>n", DesktopKit::Action::GotoTab.new(DesktopKit::Action::GotoTab::NEXT)),
        DesktopKit::Binding.new("ctrl+a>p", DesktopKit::Action::GotoTab.new(DesktopKit::Action::GotoTab::PREVIOUS)),
        DesktopKit::Binding.new("ctrl+a>h", DesktopKit::Action::GotoSplit.new(:left)),
        DesktopKit::Binding.new("ctrl+a>l", DesktopKit::Action::GotoSplit.new(:right)),
        DesktopKit::Binding.new("ctrl+a>k", DesktopKit::Action::GotoSplit.new(:up)),
        DesktopKit::Binding.new("ctrl+a>j", DesktopKit::Action::GotoSplit.new(:down)),
        DesktopKit::Binding.new("ctrl+a>e", DesktopKit::Action::ActivateKeyTable.new("resize")),
        DesktopKit::Binding.new("ctrl+q", DesktopKit::Action::Quit.new),
      ]
    end

    protected def on_activate : Nil
      new_window
    end

    protected def on_window(window : DesktopKit::Window) : Nil
      window.subtitle = System.hostname
      window.pack_end(DesktopKit::Action::ToggleCommandPalette.new, "system-search-symbolic", "Command Palette")
      window.background_blur = true
    end

    protected def perform(target : DesktopKit::App, action : ToggleLook) : Bool
      @looks.includes?(action.look) ? @looks.delete(action.look) : @looks.add(action.look)
      self.window_style = style
      true
    end

    private def style : DesktopKit::WindowStyle
      DesktopKit::WindowStyle.new(
        pane_headers: @looks.includes?(Look::PaneHeaders),
        cards: @looks.includes?(Look::Cards),
        tabs_in_header: @looks.includes?(Look::TabsInHeader),
        opacity: @looks.includes?(Look::Translucent) ? 0.85 : 1.0,
        unfocused_opacity: @looks.includes?(Look::DimUnfocused) ? 0.6 : 1.0)
    end
  end

  # A text view that gives its surface a numbered title and an icon.
  class Pane < DesktopKit::WidgetContent
    def initialize(widget : DesktopKit::Widget, @number : Int32)
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
