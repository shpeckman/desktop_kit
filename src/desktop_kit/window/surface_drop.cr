# src/desktop_kit/window/surface_drop.cr
module DesktopKit
  class Surface
    # The CSS class of the drop indicator per side.
    private DROP_CLASSES = {
      Direction::Left  => "drop-left",
      Direction::Right => "drop-right",
      Direction::Up    => "drop-up",
      Direction::Down  => "drop-down",
    }

    # Scale of the drag icon relative to the surface.
    private DRAG_ICON_SCALE = 0.2

    @surface_drop_target = Pointer(Void).null

    @data_drop_target = Pointer(Void).null

    @handle_source = Pointer(Void).null

    @header_source = Pointer(Void).null

    # Drags the pane header of a floating surface to move it.
    @float_move = Pointer(Void).null

    # The corner a floating surface is resized by.
    @float_grip = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 0))

    # The pointer in the tab area and the bounds as a float drag began.
    @float_drag : {Float64, Float64, Float64, Float64, Bounds}? = nil

    protected def draggable=(draggable : Bool) : Bool
      @handle.visible = draggable
      draggable
    end

    # Styles the surface as a float or a split: a float always shows its
    # header, which moves it instead of carrying it onto other surfaces,
    # shows the resize grip and refuses surfaces dropped on it.
    protected def floating=(floating : Bool) : Bool
      return floating if @closed || floating == @floating
      @floating = floating
      floating ? @host.add_css_class("floating") : @host.remove_css_class("floating")
      apply_style(@app.window_style)
      split_phase = floating ? C::GtkPropagationPhase::None : C::GtkPropagationPhase::Bubble
      C.gtk_event_controller_set_propagation_phase(@header_source, split_phase)
      C.gtk_event_controller_set_propagation_phase(@surface_drop_target, split_phase)
      C.gtk_event_controller_set_propagation_phase(@float_move, floating ? C::GtkPropagationPhase::Bubble : C::GtkPropagationPhase::None)
      @float_grip.visible = floating
      floating
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

    # Lets the drag handle and the pane header carry the surface id onto
    # other surfaces, the header and the grip of a float move and resize it,
    # and hands files and text dropped on the surface to the content.
    private def install_drag_and_drop : Nil
      value = C::GValue.new
      C.g_value_init(pointerof(value), C::TYPE_UINT64)
      C.g_value_set_uint64(pointerof(value), @id)
      provider = C.gdk_content_provider_new_for_value(pointerof(value))
      C.g_value_unset(pointerof(value))
      # Header buttons claim their clicks: drags start from free header area.
      @handle_source = drag_source(@handle, provider)
      @header_source = drag_source(@header, provider)
      C.g_object_unref(provider)

      @float_move = float_drag(@header, resize: false)
      C.gtk_event_controller_set_propagation_phase(@float_move, C::GtkPropagationPhase::None)
      @float_grip.add_css_class("surface-float-grip")
      @float_grip.cursor_name = "se-resize"
      @float_grip.visible = false
      C.gtk_widget_set_halign(@float_grip, C::GtkAlign::End)
      C.gtk_widget_set_valign(@float_grip, C::GtkAlign::End)
      float_drag(@float_grip, resize: true)
      C.gtk_overlay_add_overlay(@overlay, @float_grip)

      # Host targets: Canvas's own target refuses surface moves (`uint64`
      # `GValue`) and refused drags, which bubble up here.
      @surface_drop_target = surfaces = C.gtk_drop_target_new(C::TYPE_UINT64, C::GdkDragAction::Move)
      Signals.connect(surfaces, "motion", ->(x : Float64, y : Float64) : Int32 { own_drag?(surfaces) ? 0 : indicate(x, y) })
      Signals.connect(surfaces, "leave", -> { indicate(nil) })
      Signals.connect(surfaces, "drop", ->(value : Void*, x : Float64, y : Float64) : Bool { drop_surface(value, x, y) })
      @host.add_controller(surfaces)

      @data_drop_target = data = C.gtk_drop_target_new(0_u64, C::GdkDragAction::Copy)
      types = StaticArray[C.gdk_file_list_get_type, C.g_file_get_type, C::TYPE_STRING]
      C.gtk_drop_target_set_gtypes(data, types.to_unsafe, types.size)
      Signals.connect(data, "drop", ->(value : Void*, _x : Float64, _y : Float64) : Bool { drop_data(value) })
      @host.add_controller(data)
    end

    private def drag_source(widget : Widget, provider : Void*) : Void*
      source = C.gtk_drag_source_new
      C.gtk_drag_source_set_actions(source, C::GdkDragAction::Move)
      C.gtk_drag_source_set_content(source, provider)
      Signals.connect(source, "drag-begin", ->(_drag : Void*) { drag_icon(source) })
      widget.add_controller(source)
      source
    end

    # Drags on *widget* move the floating surface, or *resize* it from its
    # bottom-right corner.
    private def float_drag(widget : Widget, *, resize : Bool) : Void*
      drag = C.gtk_gesture_drag_new
      C.gtk_gesture_single_set_button(drag, 1)
      Signals.connect(drag, "drag-begin", ->(x : Float64, y : Float64) { begin_float_drag(widget, x, y) })
      Signals.connect(drag, "drag-update", ->(dx : Float64, dy : Float64) { update_float_drag(widget, dx, dy, resize) })
      Signals.connect(drag, "drag-end", ->(_dx : Float64, _dy : Float64) { @float_drag = nil })
      widget.add_controller(drag)
      drag
    end

    private def begin_float_drag(widget : Widget, x : Float64, y : Float64) : Nil
      @float_drag = nil
      bounds = float_bounds || return
      area = @host.parent || return
      return if C.gtk_widget_translate_coordinates(widget, area, x, y, out area_x, out area_y) == 0
      @float_drag = {x, y, area_x, area_y, bounds}
    end

    # The offsets count in *widget*'s coordinates, which move with the
    # float: they are taken to the tab area, which stays.
    private def update_float_drag(widget : Widget, dx : Float64, dy : Float64, resize : Bool) : Nil
      start_x, start_y, area_x, area_y, bounds = @float_drag || return
      tab = @tab || return
      area = @host.parent || return
      width, height = area.width, area.height
      return if width <= 0 || height <= 0
      return if C.gtk_widget_translate_coordinates(widget, area, start_x + dx, start_y + dy, out x, out y) == 0
      dx = (x - area_x) / width
      dy = (y - area_y) / height
      if resize
        min_width, min_height = tab.float_minimum(self)
        tab.place_float(self, bounds.resized(dx, dy, min_width, min_height))
      else
        tab.place_float(self, bounds.moved(dx, dy))
      end
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

    # Returns whether *target* holds a drag of this surface. Such a drag
    # gets no action rather than `gtk_drop_target_reject`: GTK still emits
    # "drop" on a target that rejected, with no value and no drop.
    private def own_drag?(target : Void*) : Bool
      value = C.gtk_drop_target_get_value(target)
      !value.null? && C.g_value_get_uint64(value) == @id
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
      return false if @floating
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
  end
end
