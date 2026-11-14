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

    # :nodoc:
    # The style of the drag handle and the drop indicator, which the app
    # loads at application priority.
    STYLE = <<-CSS
      .surface-drag-handle {
        background-color: alpha(@window_fg_color, 0.15);
        opacity: 0;
        transition: opacity 0.1s;
      }
      .surface-drag-handle:hover { opacity: 1; }
      .surface-drop-indicator { opacity: 0; }
      .surface-drop-indicator.drop-left { opacity: 1; background: linear-gradient(to right, alpha(@accent_bg_color, 0.3) 50%, transparent 50%); }
      .surface-drop-indicator.drop-right { opacity: 1; background: linear-gradient(to left, alpha(@accent_bg_color, 0.3) 50%, transparent 50%); }
      .surface-drop-indicator.drop-up { opacity: 1; background: linear-gradient(to bottom, alpha(@accent_bg_color, 0.3) 50%, transparent 50%); }
      .surface-drop-indicator.drop-down { opacity: 1; background: linear-gradient(to top, alpha(@accent_bg_color, 0.3) 50%, transparent 50%); }
      CSS

    # The CSS class of the drop indicator per side.
    private DROP_CLASSES = {
      Direction::Left  => "drop-left",
      Direction::Right => "drop-right",
      Direction::Up    => "drop-up",
      Direction::Down  => "drop-down",
    }

    # Scale of the drag icon relative to the surface.
    private DRAG_ICON_SCALE = 0.2

    @tab : Tab?
    @closed = false
    @surface_drop_target = Pointer(Void).null
    @data_drop_target = Pointer(Void).null

    protected def initialize(@app : App, @content : Content)
      raise ArgumentError.new("the content already belongs to a surface") if @content.surface?
      @id = @@last_id += 1
      @host = Widget.new(C.g_object_ref_sink(C.adw_bin_new))
      @host.add_css_class("surface")
      @host.hexpand = true
      @host.vexpand = true
      @handle = Widget.new(C.gtk_center_box_new)
      @drop_indicator = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 0))
      layout
      install_drag_and_drop
      focus = C.gtk_event_controller_focus_new
      Signals.connect(focus, "enter", -> { focus_changed(true) })
      Signals.connect(focus, "leave", -> { focus_changed(false) })
      @host.add_controller(focus)
      @notifications = Notifications.new(@app.to_unsafe, @id)
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
    # its tab until it gets the focus and asks for the user's attention
    # while its window is inactive (`Window#urgent=`).
    def ring_bell : Nil
      return if @closed
      @host.native.try do |native|
        surface = C.gtk_native_get_surface(native)
        C.gdk_surface_beep(surface) unless surface.null?
      end
      return if @focused || @bell_ringing
      @bell_ringing = true
      @tab.try(&.bell)
      window.try(&.urgent=(true))
    end

    # Focuses the surface: selects its tab and moves the keyboard focus to
    # it, ending a zoom on another surface.
    def focus : Nil
      @tab.try(&.activate(self))
    end

    # Focuses the surface and raises its window.
    def present : Nil
      tab = @tab || return
      tab.activate(self)
      tab.window.try(&.present)
    end

    # Shows a desktop notification from the surface; clicking it presents
    # the surface. Sending the same *title* and *body* again replaces it.
    #
    # One sent while the surface is focused is withdrawn after a few seconds;
    # all are withdrawn once the surface gets the focus or closes.
    def notify(title : String, body : String) : Nil
      @notifications.send(title, body, @focused) unless @closed
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

    # Shows the drag handle while the surface shares its tab.
    protected def draggable=(draggable : Bool) : Bool
      @handle.visible = draggable
      draggable
    end

    # Returns the side of the surface nearest to (*x*, *y*), in surface
    # coordinates of a *width* by *height* surface.
    protected def self.drop_side(x : Float64, y : Float64, width : Float64, height : Float64) : Direction
      left = width > 0 ? x / width : 0.5
      up = height > 0 ? y / height : 0.5
      {
        {Direction::Left, left}, {Direction::Right, 1.0 - left},
        {Direction::Up, up}, {Direction::Down, 1.0 - up},
      }.min_by(&.[1])[0]
    end

    # Moves the keyboard focus to the content when it is on screen.
    protected def grab_focus : Nil
      @content.widget.grab_focus if !@closed && @host.mapped?
    end

    # Stacks the content under the drag handle and the drop indicator.
    private def layout : Nil
      overlay = C.gtk_overlay_new
      C.gtk_overlay_set_child(overlay, @content.widget)
      image = C.gtk_image_new_from_icon_name("view-more-horizontal-symbolic")
      C.gtk_center_box_set_center_widget(@handle, image)
      @handle.add_css_class("surface-drag-handle")
      @handle.cursor_name = "grab"
      @handle.visible = false
      C.gtk_widget_set_valign(@handle, C::GtkAlign::Start)
      C.gtk_overlay_add_overlay(overlay, @handle)
      @drop_indicator.add_css_class("surface-drop-indicator")
      C.gtk_widget_set_can_target(@drop_indicator, 0)
      C.gtk_overlay_add_overlay(overlay, @drop_indicator)
      C.adw_bin_set_child(@host, overlay)
    end

    # Lets the drag handle carry the surface id onto other surfaces, and
    # hands files and text dropped on the surface to the content.
    private def install_drag_and_drop : Nil
      source = C.gtk_drag_source_new
      C.gtk_drag_source_set_actions(source, C::GdkDragAction::Move)
      value = C::GValue.new
      C.g_value_init(pointerof(value), C::TYPE_UINT64)
      C.g_value_set_uint64(pointerof(value), @id)
      provider = C.gdk_content_provider_new_for_value(pointerof(value))
      C.g_value_unset(pointerof(value))
      C.gtk_drag_source_set_content(source, provider)
      C.g_object_unref(provider)
      Signals.connect(source, "drag-begin", ->(_drag : Void*) { drag_icon(source) })
      @handle.add_controller(source)

      @surface_drop_target = surfaces = C.gtk_drop_target_new(C::TYPE_UINT64, C::GdkDragAction::Move)
      Signals.notify(surfaces, "value", -> { reject_self(surfaces) })
      Signals.connect(surfaces, "motion", ->(x : Float64, y : Float64) : Int32 { indicate(x, y) })
      Signals.connect(surfaces, "leave", -> { indicate(nil) })
      Signals.connect(surfaces, "drop", ->(value : Void*, x : Float64, y : Float64) : Bool { drop_surface(value, x, y) })
      @host.add_controller(surfaces)

      @data_drop_target = data = C.gtk_drop_target_new(0_u64, C::GdkDragAction::Copy)
      types = StaticArray[C.gdk_file_list_get_type, C.g_file_get_type, C::TYPE_STRING]
      C.gtk_drop_target_set_gtypes(data, types.to_unsafe, types.size)
      Signals.connect(data, "drop", ->(value : Void*, _x : Float64, _y : Float64) : Bool { drop_data(value) })
      @host.add_controller(data)
    end

    private def drag_icon(source : Void*) : Nil
      width = @host.width.to_f
      height = @host.height.to_f
      return if width <= 0 || height <= 0
      paintable = C.gtk_widget_paintable_new(@host)
      snapshot = C.gtk_snapshot_new
      C.gtk_snapshot_scale(snapshot, DRAG_ICON_SCALE, DRAG_ICON_SCALE)
      C.gdk_paintable_snapshot(paintable, snapshot, width, height)
      icon = C.gtk_snapshot_free_to_paintable(snapshot, Pointer(Void).null)
      unless icon.null?
        C.gtk_drag_source_set_icon(source, icon, (width * DRAG_ICON_SCALE / 2).to_i, (height * DRAG_ICON_SCALE / 2).to_i)
        C.g_object_unref(icon)
      end
      C.g_object_unref(paintable)
    end

    # Refuses a drag of this surface onto itself.
    private def reject_self(target : Void*) : Nil
      value = C.gtk_drop_target_get_value(target)
      C.gtk_drop_target_reject(target) if !value.null? && C.g_value_get_uint64(value) == @id
    end

    private def indicate(x : Float64, y : Float64) : Int32
      indicate(Surface.drop_side(x, y, @host.width.to_f, @host.height.to_f))
      C::GdkDragAction::Move.value.to_i32
    end

    # Highlights the half of the surface on *side*, or none.
    private def indicate(side : Direction?) : Nil
      DROP_CLASSES.each do |direction, css_class|
        if direction == side
          @drop_indicator.add_css_class(css_class)
        else
          @drop_indicator.remove_css_class(css_class)
        end
      end
    end

    private def drop_surface(value : Void*, x : Float64, y : Float64) : Bool
      indicate(nil)
      source = @app.surface(C.g_value_get_uint64(value)) || return false
      tab = @tab || return false
      return false if source == self || source.closed?
      tab.insert(source, self, Surface.drop_side(x, y, @host.width.to_f, @host.height.to_f))
      true
    end

    private def drop_data(value : Void*) : Bool
      return false if @closed
      type = value.as(C::GValue*).value.g_type
      if type == C::TYPE_STRING
        text = Native.string?(C.g_value_get_string(value)) || return false
        @content.drop(text)
      elsif type == C.g_file_get_type
        path = file_path(C.g_value_get_object(value)) || return false
        @content.drop([path])
      else
        list = C.gdk_file_list_get_files(C.g_value_get_boxed(value))
        paths = [] of Path
        node = list
        until node.null?
          file_path(node.value.data).try { |path| paths << path }
          node = node.value.next_
        end
        C.g_slist_free(list) unless list.null?
        !paths.empty? && @content.drop(paths)
      end
    end

    private def file_path(file : Void*) : Path?
      return if file.null?
      Native.take_string?(C.g_file_get_path(file)).try { |path| Path.new(path) }
    end

    private def focus_changed(focused : Bool) : Nil
      @focused = focused
      return unless focused
      @notifications.clear
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
      @notifications.clear
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
