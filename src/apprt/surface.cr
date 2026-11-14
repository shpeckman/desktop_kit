# src/apprt/surface.cr
module Apprt
  # A pane of a tab showing one `Content`.
  #
  # The runtime opens surfaces for new windows, tabs and splits and asks
  # `App#new_surface` for their content. A surface lives until it closes. Use
  # it on the GTK thread only.
  class Surface
    @@last_id = 0_u64

    # Returns the identifier, unique within the process; `App#surface` finds
    # the surface by it.
    getter id : UInt64

    getter content : Content

    # The title the content reports.
    getter title : String = ""

    # The title the user chose; shown instead of `#title` while set.
    getter title_override : String?

    # Whether closing the surface asks the user first.
    property? confirm_close : Bool = false

    # Returns the CSS name of the pointer shown over the surface, such as
    # `"text"`, or `nil` for the default pointer.
    getter cursor : String?

    # Whether the pointer shows over the surface.
    getter? mouse_visible : Bool = true

    # Whether the bell rang while the surface was not focused; it rings until
    # the surface gets the focus.
    getter? bell_ringing : Bool = false

    # Whether the surface holds its window's keyboard focus.
    getter? focused : Bool = false

    @tab : Tab?
    @closed = false

    protected def initialize(@app : App, @content : Content)
      raise ArgumentError.new("the content already belongs to a surface") if @content.surface?
      @id = @@last_id += 1
      @host = Widget.new(C.g_object_ref_sink(C.adw_bin_new))
      @host.add_css_class("surface")
      @host.hexpand = true
      @host.vexpand = true
      C.adw_bin_set_child(@host, @content.widget)
      focus = C.gtk_event_controller_focus_new
      Signals.connect(focus, "enter", -> { focus_changed(true) })
      Signals.connect(focus, "leave", -> { focus_changed(false) })
      @host.add_controller(focus)
      @content.surface = self
    end

    def title=(title : String) : String
      @title = title
      @tab.try(&.sync_title)
      title
    end

    # Sets the title the user chose; `nil` restores `#title`.
    def title_override=(title : String?) : String?
      @title_override = title
      @tab.try(&.sync_title)
      title
    end

    # Returns the tab showing the surface, or `nil` once it is closed.
    def tab : Tab?
      @tab
    end

    # Returns the window showing the surface, or `nil` once it is closed.
    def window : Window?
      @tab.try(&.window)
    end

    def closed? : Bool
      @closed
    end

    # Sets the pointer shown over the surface by its CSS name, such as
    # `"text"` or `"pointer"`; `nil` restores the default pointer.
    def cursor=(name : String?) : String?
      @cursor = name
      sync_cursor
      name
    end

    # Shows or hides the pointer over the surface.
    def mouse_visible=(visible : Bool) : Bool
      @mouse_visible = visible
      sync_cursor
      visible
    end

    # Rings the bell: beeps and, unless the surface is focused, marks it and
    # its tab until it gets the focus.
    def ring_bell : Nil
      return if @closed
      @host.native.try do |native|
        surface = C.gtk_native_get_surface(native)
        C.gdk_surface_beep(surface) unless surface.null?
      end
      return if @focused || @bell_ringing
      @bell_ringing = true
      @tab.try(&.bell)
    end

    # Focuses the surface: selects its tab and moves the keyboard focus to
    # it, ending a zoom on another surface.
    def focus : Nil
      @tab.try(&.activate(self))
    end

    # Opens a new surface beside this one, in *direction*, focuses it and
    # returns it. Raises `RuntimeError` when the surface is closed.
    def split(direction : Direction) : Surface
      tab = @tab || raise RuntimeError.new("the surface is closed")
      tab.split(self, direction)
    end

    # Closes the surface, asking the user first when `#confirm_close?`.
    # Closing the last surface of a tab closes the tab.
    def close : Nil
      tab = @tab || return
      return tab.remove(self) unless confirm_close?
      kind = tab.surfaces.size > 1 ? Dialogs::Close::Split : Dialogs::Close::Tab
      Dialogs.confirm_close(@host, kind) { |confirmed| tab.remove(self) if confirmed }
    end

    # The title shown for the surface, or nil when it has none.
    protected def shown_title : String?
      @title_override || (@title unless @title.empty?)
    end

    # The widget the surface's splits place: a bin around the content's
    # widget, holding a reference of its own so that it survives the split
    # rebuilds that unparent it.
    protected def host : Widget
      @host
    end

    protected def tab=(tab : Tab?) : Tab?
      @tab = tab
    end

    # Moves the keyboard focus to the content when it is on screen.
    protected def grab_focus : Nil
      @content.widget.grab_focus if !@closed && @host.mapped?
    end

    private def focus_changed(focused : Bool) : Nil
      @focused = focused
      return unless focused
      if @bell_ringing
        @bell_ringing = false
        @tab.try(&.sync_title)
      end
      @tab.try(&.focused(self))
    end

    private def sync_cursor : Nil
      @content.widget.cursor_name = @mouse_visible ? @cursor : "none" unless @closed
    end

    # Forgets the surface once its tab dropped it.
    protected def release : Nil
      return if @closed
      @closed = true
      @tab = nil
      @app.unregister(self)
      C.g_object_unref(@host)
    end
  end

  abstract class App
    protected def perform(target : Surface, action : Action::NewSplit) : Bool
      target.split(action.direction)
      true
    end

    protected def perform(target : Surface, action : Action::GotoSplit) : Bool
      target.tab.try(&.goto(target, action.direction)) || false
    end

    protected def perform(target : Surface, action : Action::ResizeSplit) : Bool
      target.tab.try(&.resize(target, action.direction, action.amount)) || false
    end

    protected def perform(target : Surface, action : Action::EqualizeSplits) : Bool
      target.tab.try(&.equalize) || false
    end

    protected def perform(target : Surface, action : Action::ToggleSplitZoom) : Bool
      target.tab.try(&.toggle_zoom(target)) || false
    end

    protected def perform(target : Surface, action : Action::CloseSurface) : Bool
      target.close
      true
    end

    protected def perform(target : Surface, action : Action::SetTitle) : Bool
      target.title = action.title
      true
    end

    protected def perform(target : Surface, action : Action::RingBell) : Bool
      target.ring_bell
      true
    end

    protected def perform(target : Surface, action : Action::MouseVisibility) : Bool
      target.mouse_visible = action.visible
      true
    end

    protected def perform(target : Surface, action : Action::PromptTitle) : Bool
      kind = action.kind
      case kind
      in .surface?
        Dialogs.prompt_title(target.host, kind, target.title_override) { |title| target.title_override = title }
      in .tab?
        tab = target.tab || return false
        Dialogs.prompt_title(target.host, kind, tab.title_override) { |title| tab.title_override = title }
      in .window?
        window = target.window || return false
        Dialogs.prompt_title(target.host, kind, window.title_override) { |title| window.title_override = title }
      end
      true
    end
  end
end
