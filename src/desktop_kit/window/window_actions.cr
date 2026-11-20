# src/desktop_kit/window/window_actions.cr
module DesktopKit
  class Window
    protected def toggle_maximized : Nil
      self.maximized = !maximized?
    end

    protected def toggle_fullscreen : Nil
      self.fullscreen = !fullscreen?
    end

    # Hides the decorations, or restores the ones they replaced.
    protected def toggle_decorations : Nil
      if @decoration.none?
        self.decoration = @restored_decoration
      else
        @restored_decoration = @decoration
        self.decoration = :none
      end
    end

    # Opens a command palette over *commands*, showing the shortcuts of
    # *bindings*, or closes the open one.
    protected def toggle_command_palette(commands : Array(Command), bindings : Array(Binding)) : Nil
      if (palette = @palette) && !palette.closed?
        palette.close
      else
        palette = CommandPalette.new(self, @app, commands, bindings)
        palette.present
        @palette = palette
      end
    end

    # Returns the open command palette.
    protected def command_palette : CommandPalette?
      @palette.try { |palette| palette unless palette.closed? }
    end

    protected def toggle_overview : Nil
      C.adw_tab_overview_set_open(@overview, C.adw_tab_overview_get_open(@overview) != 0 ? 0 : 1)
    end

    protected def default_size(width : Int32, height : Int32) : Nil
      C.gtk_window_set_default_size(@widget, width, height)
    end

    # Sets the size `#reset_size` returns to, and resizes to it.
    protected def initial_size(width : Int32, height : Int32) : Nil
      @initial_size = {width, height}
      default_size(width, height)
    end

    # Resizes to the initial size, unless the window is maximized or
    # fullscreen.
    protected def reset_size : Bool
      return false if maximized? || fullscreen?
      default_size(*@initial_size)
      true
    end

    # Switches the background between the window style's opacity and
    # opaque; false when the style is opaque already.
    protected def toggle_opaque : Bool
      return false unless @app.window_style.opacity < 1.0
      @opaque = !@opaque
      @opaque ? @widget.add_css_class("opaque") : @widget.remove_css_class("opaque")
      true
    end

    protected def shown? : Bool
      !@closed && @widget.visible?
    end

    protected def shown=(shown : Bool) : Bool
      return shown if @closed
      shown ? present : (@widget.visible = false)
      shown
    end

    # Sets the smallest size; 0 leaves a dimension unlimited.
    protected def min_size(width : Int32, height : Int32) : Nil
      @widget.size_request(width > 0 ? width : -1, height > 0 ? height : -1)
    end

    # Grows or shrinks the window so that its only surface gets *width* by
    # *height* pixels. Does nothing while the window is maximized or
    # fullscreen, or shows more than one surface.
    protected def resize(width : Int32, height : Int32) : Bool
      return false if maximized? || fullscreen?
      return false unless page_count == 1
      surfaces = tabs.first?.try(&.surfaces) || return false
      return false unless surfaces.size == 1
      host = surfaces.first.host
      return false unless host.mapped?
      default_size(@widget.width + width - host.width, @widget.height + height - host.height)
      true
    end
  end

  abstract class App
    protected def perform(target : Window, action : Action::CloseWindow) : Bool
      target.close
      true
    end

    protected def perform(target : Window, action : Action::ToggleMaximize) : Bool
      target.toggle_maximized
      true
    end

    protected def perform(target : Window, action : Action::ToggleFullscreen) : Bool
      target.toggle_fullscreen
      true
    end

    protected def perform(target : Window, action : Action::ToggleWindowDecorations) : Bool
      target.toggle_decorations
      true
    end

    protected def perform(target : Window, action : Action::ToggleTabOverview) : Bool
      target.toggle_overview
      true
    end

    protected def perform(target : Window, action : Action::GotoWindow) : Bool
      return false if @windows.size < 2
      index = @windows.index(target) || return false
      step = action.direction.next? ? 1 : -1
      @windows[(index + step) % @windows.size].present
      true
    end

    protected def perform(target : Window, action : Action::SetWindowTitle) : Bool
      target.title_override = action.title
      true
    end

    protected def perform(target : Window, action : Action::InitialSize) : Bool
      target.initial_size(action.width.to_i32, action.height.to_i32)
      true
    end

    protected def perform(target : Window, action : Action::ResetWindowSize) : Bool
      target.reset_size
    end

    protected def perform(target : Window, action : Action::ToggleBackgroundOpacity) : Bool
      target.toggle_opaque
    end

    protected def perform(target : Window, action : Action::ActivateKeyTable) : Bool
      target.activate_key_table(action.table, once: false)
    end

    protected def perform(target : Window, action : Action::ActivateKeyTableOnce) : Bool
      target.activate_key_table(action.table, once: true)
    end

    protected def perform(target : Window, action : Action::DeactivateKeyTable) : Bool
      target.deactivate_key_table
    end

    protected def perform(target : Window, action : Action::DeactivateAllKeyTables) : Bool
      target.deactivate_all_key_tables
    end

    protected def perform(target : App, action : Action::ToggleVisibility) : Bool
      return false if @windows.empty?
      shown = @windows.none?(&.shown?)
      @windows.each { |window| window.shown = shown }
      true
    end

    protected def perform(target : App, action : Action::ShowGtkInspector) : Bool
      C.gtk_window_set_interactive_debugging(1)
      true
    end

    protected def perform(target : Window, action : Action::SizeLimit) : Bool
      target.min_size(action.min_width.to_i32, action.min_height.to_i32)
      true
    end

    protected def perform(target : Window, action : Action::ResizeWindow) : Bool
      target.resize(action.width.to_i32, action.height.to_i32)
    end

    protected def perform(target : Window, action : Action::SetWindowTheme) : Bool
      self.appearance = action.appearance
      true
    end

    protected def perform(target : Window, action : Action::NewTab) : Bool
      target.new_tab
      true
    end

    protected def perform(target : Window, action : Action::GotoTab) : Bool
      target.goto_tab(action.index)
    end
  end
end
