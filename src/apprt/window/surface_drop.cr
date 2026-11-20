# src/apprt/window/surface_drop.cr
module Apprt
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

    # Lets the drag handle and the pane header carry the surface id onto
    # other surfaces, and hands files and text dropped on the surface to the
    # content.
    private def install_drag_and_drop : Nil
      value = C::GValue.new
      C.g_value_init(pointerof(value), C::TYPE_UINT64)
      C.g_value_set_uint64(pointerof(value), @id)
      provider = C.gdk_content_provider_new_for_value(pointerof(value))
      C.g_value_unset(pointerof(value))
      # Header buttons claim their clicks: drags start from free header area.
      {@handle, @header}.each do |widget|
        source = C.gtk_drag_source_new
        C.gtk_drag_source_set_actions(source, C::GdkDragAction::Move)
        C.gtk_drag_source_set_content(source, provider)
        Signals.connect(source, "drag-begin", ->(_drag : Void*) { drag_icon(source) })
        widget.add_controller(source)
      end
      C.g_object_unref(provider)

      # Host targets: Canvas's own target refuses surface moves (`uint64`
      # `GValue`) and refused drags, which bubble up here.
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
  end
end
