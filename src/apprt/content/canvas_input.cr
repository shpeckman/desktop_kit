# src/apprt/content/canvas_input.cr
module Apprt
  abstract class Canvas < Content
    private MODIFIER_KEYS = {
      0xffe1_u32 => Mods::Shift, # Shift_L
      0xffe2_u32 => Mods::Shift, # Shift_R
      0xffe3_u32 => Mods::Ctrl,  # Control_L
      0xffe4_u32 => Mods::Ctrl,  # Control_R
      0xffe7_u32 => Mods::Super, # Meta_L
      0xffe8_u32 => Mods::Super, # Meta_R
      0xffe9_u32 => Mods::Alt,   # Alt_L
      0xffea_u32 => Mods::Alt,   # Alt_R
      0xffeb_u32 => Mods::Super, # Super_L
      0xffec_u32 => Mods::Super, # Super_R
    }

    # Controller ivars use `@im_`/`_controller`/`_gesture` names:
    # subclasses share the ivar namespace (a subclass `@keys` collided).
    @key_controller : Void*
    @click_gesture : Void*
    @scroll_controller : Void*
    @motion_controller : Void*
    @im_context : Void*
    @im_composing = false
    @im_in_key = false
    @im_key_composing = false
    @im_key_text : String?
    @held_keycodes = Set(UInt32).new
    @drop_target : Void*
    @drop : Drop?
    @drag : Drag?
    @pointer_x = 0.0
    @pointer_y = 0.0

    # Tells the input method where the text cursor is, so that its popups
    # open beside it.
    def ime_cursor(x : Float64, y : Float64, width : Float64, height : Float64) : Nil
      return if @widget_destroyed
      scale = self.scale
      area = C::GdkRectangle.new(x: (x / scale).round.to_i32, y: (y / scale).round.to_i32,
        width: (width / scale).round.to_i32, height: (height / scale).round.to_i32)
      C.gtk_im_context_set_cursor_location(@im_context, pointerof(area))
    end

    protected def show_on_screen_keyboard : Bool
      !@widget_destroyed && C.gtk_im_context_activate_osk(@im_context, nil) != 0
    end

    # :showdoc:
    #
    # Handles a key and returns whether the canvas used it; GTK passes unused
    # keys on to the widgets around the canvas.
    protected def on_key(event : KeyEvent) : Bool
      false
    end

    # :showdoc:
    #
    # Called when the text an input method is composing changes; `nil` ends
    # the composition.
    protected def on_preedit(text : String?) : Nil
    end

    # :showdoc:
    #
    # Called with text an input method finished outside a key, such as the
    # end of a composition.
    protected def on_commit(text : String) : Nil
    end

    # :showdoc:
    #
    # Called when the canvas takes or loses the keyboard focus.
    protected def on_focus(focused : Bool) : Nil
    end

    # :showdoc:
    #
    # Called when a mouse button goes down or up. A press focuses the canvas
    # first.
    protected def on_mouse_button(event : MouseButtonEvent) : Nil
    end

    # :showdoc:
    #
    # Called when the pointer enters the canvas, with its position.
    protected def on_mouse_enter(event : MouseMotionEvent) : Nil
    end

    # :showdoc:
    #
    # Called when the pointer moves over the canvas.
    protected def on_mouse_motion(event : MouseMotionEvent) : Nil
    end

    # :showdoc:
    #
    # Called when the pointer leaves the canvas.
    protected def on_mouse_leave : Nil
    end

    # :showdoc:
    #
    # Called when the user scrolls over the canvas.
    protected def on_scroll(event : ScrollEvent) : Nil
    end

    # :showdoc:
    #
    # Called when a drag enters the canvas; returns whether the canvas takes
    # part in it. A refused drag reaches the surface, which hands files and
    # text to `Content#on_drop`. Refuses every drag by default.
    protected def on_drop_accept(drop : Drop) : Bool
      false
    end

    # :showdoc:
    #
    # Called as an accepted drag enters and moves over the canvas at *x*, *y*
    # (device pixels, like pointer events); returns the action a drop there
    # would perform, `DragAction::None` to refuse it there. Copies when the
    # source allows it by default.
    protected def on_drop_motion(drop : Drop, x : Float64, y : Float64) : DragAction
      drop.actions & DragAction::Copy
    end

    # :showdoc:
    #
    # Called when an accepted drag leaves the canvas without dropping.
    protected def on_drop_leave(drop : Drop) : Nil
    end

    # :showdoc:
    #
    # Called when the user drops an accepted drag at *x*, *y*; returns
    # whether the canvas takes the drop, which it then reads with
    # `Drop#read` and ends with `Drop#finish`. Refuses by default.
    protected def on_drop(drop : Drop, x : Float64, y : Float64) : Bool
      false
    end

    # :showdoc:
    #
    # Called once a drag started with `#drag` ends, with the action the
    # target performed, `DragAction::None` when it was cancelled or failed.
    # A `DragAction::Move` asks the canvas to delete the data.
    protected def on_drag_end(drag : Drag, action : DragAction) : Nil
    end

    # Starts dragging data of *mime_types* with the pointer, allowing
    # *actions*, and returns the drag, or `nil` while the canvas is not on
    # screen. Call it while a mouse button is held, from a pointer hook.
    #
    # The block receives a `Drag::Request` each time a target asks for one
    # of the types. *icon* is shown under the pointer.
    def drag(mime_types : Enumerable(String), actions : DragAction = DragAction::Copy,
             icon : Drag::Icon? = nil, &handler : Drag::Request ->) : Drag?
      types = mime_types.to_a
      native = C.gtk_widget_get_native(@widget)
      return if native.null?
      surface = C.gtk_native_get_surface(native)
      return if surface.null?
      seat = C.gdk_display_get_default_seat(C.gdk_display_get_default)
      return if seat.null?
      C.gtk_widget_translate_coordinates(@widget, native, @pointer_x, @pointer_y, out x, out y)
      C.gtk_native_get_surface_transform(native, out offset_x, out offset_y)
      content = DragContent.new(DragContent::Source.new(types, handler))
      pointer = C.gdk_drag_begin(surface, C.gdk_seat_get_pointer(seat), content, actions.to_gdk, x + offset_x, y + offset_y)
      C.g_object_unref(content)
      return if pointer.null?
      drag = Drag.new(pointer, types)
      @drag = drag
      icon.try { |image| drag_icon(pointer, image) }
      Signals.connect(drag, "dnd-finished", -> { drag_ended(drag, true) })
      Signals.connect(drag, "cancel", ->(_reason : C::GdkDragCancelReason) { drag_ended(drag, false) })
      drag
    end

    private def set_input_purpose(purpose : InputPurpose) : Nil
      # `input-purpose` has no setter: GValue. GIR has no `get_type` for
      # GtkInputPurpose: GType by name.
      value = C::GValue.new
      C.g_value_init(pointerof(value), C.g_type_from_name("GtkInputPurpose"))
      C.g_value_set_enum(pointerof(value), C::GtkInputPurpose.new(purpose.value).value)
      C.g_object_set_property(@im_context, "input-purpose", pointerof(value))
      C.g_value_unset(pointerof(value))
    end

    private def connect_keys : Nil
      Signals.connect(@key_controller, "key-pressed", ->(keyval : UInt32, keycode : UInt32, state : UInt32) : Bool {
        key(true, keyval, keycode, state)
      })
      Signals.connect(@key_controller, "key-released", ->(keyval : UInt32, keycode : UInt32, state : UInt32) {
        key(false, keyval, keycode, state)
        nil
      })
      @widget.add_controller(@key_controller)
      focus = C.gtk_event_controller_focus_new
      Signals.connect(focus, "enter", -> { focus_changed(true) })
      Signals.connect(focus, "leave", -> { focus_changed(false) })
      @widget.add_controller(focus)
    end

    private def connect_im : Nil
      Signals.connect(@im_context, "preedit-start", -> { @im_composing = true; nil })
      Signals.connect(@im_context, "preedit-changed", -> { preedit_changed })
      Signals.connect(@im_context, "preedit-end", -> { @im_composing = false; on_preedit(nil) })
      Signals.connect(@im_context, "commit", ->(text : String) { commit(text) })
    end

    private def connect_pointer : Nil
      C.gtk_gesture_single_set_button(@click_gesture, 0)
      Signals.connect(@click_gesture, "pressed", ->(_count : Int32, x : Float64, y : Float64) { button(true, x, y) })
      Signals.connect(@click_gesture, "released", ->(_count : Int32, x : Float64, y : Float64) { button(false, x, y) })
      @widget.add_controller(@click_gesture)
      Signals.connect(@motion_controller, "enter", ->(x : Float64, y : Float64) { on_mouse_enter(motion(x, y)) })
      Signals.connect(@motion_controller, "motion", ->(x : Float64, y : Float64) { on_mouse_motion(motion(x, y)) })
      Signals.connect(@motion_controller, "leave", -> { on_mouse_leave })
      @widget.add_controller(@motion_controller)
      Signals.connect(@scroll_controller, "scroll", ->(dx : Float64, dy : Float64) : Bool { scroll(dx, dy); true })
      @widget.add_controller(@scroll_controller)
    end

    # Runs the key through the input method, then hands it to `#on_key`
    # unless the input method used it for a composition.
    private def key(pressed : Bool, keyval : UInt32, keycode : UInt32, state : UInt32) : Bool
      event = C.gtk_event_controller_get_current_event(@key_controller)
      was_composing = @im_composing
      filtered = false
      unless event.null?
        @im_in_key = true
        @im_key_composing = was_composing
        begin
          filtered = C.gtk_im_context_filter_keypress(@im_context, event) != 0
        ensure
          @im_in_key = false
        end
      end
      text = @im_key_text
      @im_key_text = nil
      return true if filtered && (@im_composing || was_composing || text.nil?)
      handled = on_key(key_event(event, pressed, keyval, keycode, state, text, was_composing))
      if handled && pressed && @im_composing
        C.gtk_im_context_reset(@im_context)
        @im_composing = false
        on_preedit(nil)
      end
      handled
    end

    private def key_event(event : Void*, pressed : Bool, keyval : UInt32, keycode : UInt32, state : UInt32,
                          text : String?, composing : Bool) : KeyEvent
      mods = Mods.from_gdk(C::GdkModifierType.new(state))
      if mod = MODIFIER_KEYS[keyval]?
        mods = pressed ? mods | mod : mods & ~mod
      end
      # GTK has no repeat flag: a press of a held keycode is a repeat.
      repeat = pressed && !@held_keycodes.add?(keycode)
      @held_keycodes.delete(keycode) unless pressed
      if pressed && text.nil?
        code = C.gdk_keyval_to_unicode(keyval)
        text = code.chr.to_s if code >= 0x20 && code != 0x7f
      end
      text = nil unless pressed
      # Emitted events (specs) have no current GdkEvent: lowercased keyval
      # stands in for `unshifted`/`base`.
      if event.null?
        code = C.gdk_keyval_to_unicode(C.gdk_keyval_to_lower(keyval))
        unshifted = code.chr unless code == 0
        return KeyEvent.new(pressed, keyval, keycode, mods, Mods::None, text, unshifted, MODIFIER_KEYS.has_key?(keyval),
          composing, repeat: repeat, base: unshifted)
      end
      layout = C.gdk_key_event_get_layout(event)
      unshifted, shifted, base = layout_chars(keycode, layout)
      # Lock states from the device: GDK 4 state has no lock masks.
      device = C.gdk_event_get_device(event)
      KeyEvent.new(pressed, keyval, keycode, mods, Mods.from_gdk(C.gdk_key_event_get_consumed_modifiers(event)), text,
        unshifted, C.gdk_key_event_is_modifier(event) != 0, composing,
        repeat: repeat, layout: layout, shifted: shifted, base: base,
        caps_lock: !device.null? && C.gdk_device_get_caps_lock_state(device) != 0,
        num_lock: !device.null? && C.gdk_device_get_num_lock_state(device) != 0)
    end

    # Returns the characters of *keycode* at levels 0 and 1 of *layout* and
    # at level 0 of the first layout.
    private def layout_chars(keycode : UInt32, layout : UInt32) : {Char?, Char?, Char?}
      unshifted = shifted = base = nil
      return {unshifted, shifted, base} if C.gdk_display_map_keycode(@widget.display, keycode, out keys, out keyvals, out count) == 0
      begin
        count.times do |index|
          key = keys[index]
          next unless key.level <= 1
          code = C.gdk_keyval_to_unicode(keyvals[index])
          next if code == 0
          if key.group == layout
            key.level == 0 ? (unshifted = code.chr) : (shifted = code.chr)
          end
          base = code.chr if key.group == 0 && key.level == 0
        end
      ensure
        C.g_free(keys.as(Void*))
        C.g_free(keyvals.as(Void*))
      end
      {unshifted, shifted, base}
    end

    private def preedit_changed : Nil
      C.gtk_im_context_get_preedit_string(@im_context, out text, Pointer(Void*).null, out cursor)
      on_preedit(Native.take_string?(text).try(&.presence))
    end

    # Text committed during a key the input method was not composing for
    # belongs to that key; other text arrives on its own.
    private def commit(text : String) : Nil
      if @im_in_key && !@im_key_composing
        @im_key_text = @im_key_text.try(&.+(text)) || text
      else
        @im_composing = false
        on_preedit(nil)
        on_commit(text)
      end
    end

    private def connect_drops : Nil
      target = @drop_target
      Signals.connect(target, "accept", ->(drop : Void*) : Bool { drop_accept(drop) })
      Signals.connect(target, "drag-enter", ->(drop : Void*, x : Float64, y : Float64) : Int32 { drop_motion(drop, x, y) })
      Signals.connect(target, "drag-motion", ->(drop : Void*, x : Float64, y : Float64) : Int32 { drop_motion(drop, x, y) })
      Signals.connect(target, "drag-leave", ->(drop : Void*) { drop_for(drop).try { |current| on_drop_leave(current) }; @drop = nil })
      Signals.connect(target, "drop", ->(drop : Void*, x : Float64, y : Float64) : Bool { drop_perform(drop, x, y) })
      @widget.add_controller(target)
    end

    # Returns the drop of the drag in progress, made on its first signal.
    private def drop_for(pointer : Void*) : Drop
      current = @drop
      return current if current && current.to_unsafe == pointer
      @drop = Drop.from_raw(pointer)
    end

    # Takes part in drags with MIME types that the content accepts; the
    # surface's own drags carry none.
    private def drop_accept(pointer : Void*) : Bool
      # Surface moves (`uint64` GValue, no MIME types) and refused drags
      # bubble to the surface host's drop targets.
      drop = drop_for(pointer)
      return true if !drop.mime_types.empty? && on_drop_accept(drop)
      @drop = nil
      false
    end

    private def drop_motion(pointer : Void*, x : Float64, y : Float64) : Int32
      scale = self.scale
      action = on_drop_motion(drop_for(pointer), x * scale, y * scale) & drop_for(pointer).actions
      first = {DragAction::Copy, DragAction::Move, DragAction::Link}.find { |one| action.includes?(one) }
      (first || DragAction::None).value.to_i32
    end

    private def drop_perform(pointer : Void*, x : Float64, y : Float64) : Bool
      drop = drop_for(pointer)
      @drop = nil
      scale = self.scale
      on_drop(drop, x * scale, y * scale)
    end

    private def drag_icon(drag : Void*, icon : Drag::Icon) : Nil
      raise ArgumentError.new("icon pixels do not match its size") unless icon.pixels.size == icon.width * icon.height * 4
      bytes = Stream.bytes(icon.pixels)
      texture = C.gdk_memory_texture_new(icon.width, icon.height, C::GdkMemoryFormat::R8g8b8a8, bytes, icon.width * 4)
      C.g_bytes_unref(bytes)
      C.gtk_drag_icon_set_from_paintable(drag, texture, icon.hot_x, icon.hot_y)
      C.g_object_unref(texture)
    end

    private def drag_ended(drag : Drag, finished : Bool) : Nil
      return unless drag.end!
      action = finished ? drag.action : DragAction::None
      C.gdk_drag_drop_done(drag, finished ? 1 : 0)
      @drag = nil if @drag == drag
      on_drag_end(drag, action)
    end

    private def focus_changed(focused : Bool) : Nil
      @held_keycodes.clear
      focused ? C.gtk_im_context_focus_in(@im_context) : C.gtk_im_context_focus_out(@im_context)
      on_focus(focused)
    end

    private def button(pressed : Bool, x : Float64, y : Float64) : Nil
      @widget.grab_focus if pressed
      @pointer_x = x
      @pointer_y = y
      scale = self.scale
      button = MouseButton.new(C.gtk_gesture_single_get_current_button(@click_gesture).to_i32)
      on_mouse_button(MouseButtonEvent.new(pressed, button, x * scale, y * scale, mods(@click_gesture),
        C.gtk_event_controller_get_current_event_time(@click_gesture)))
    end

    private def motion(x : Float64, y : Float64) : MouseMotionEvent
      @pointer_x = x
      @pointer_y = y
      scale = self.scale
      MouseMotionEvent.new(x * scale, y * scale, mods(@motion_controller),
        C.gtk_event_controller_get_current_event_time(@motion_controller))
    end

    private def scroll(dx : Float64, dy : Float64) : Nil
      precise = C.gtk_event_controller_scroll_get_unit(@scroll_controller).surface?
      factor = precise ? scale.to_f : 1.0
      on_scroll(ScrollEvent.new(dx * factor, dy * factor, precise, mods(@scroll_controller)))
    end

    private def mods(controller : Void*) : Mods
      Mods.from_gdk(C.gtk_event_controller_get_current_event_state(controller))
    end
  end
end
