# src/apprt/canvas.cr
module Apprt
  # Content drawn with OpenGL that takes the keyboard, the mouse and input
  # method text.
  #
  # Subclasses draw in `#on_render` and override the other hooks they need.
  # The GL context is current in `#on_realize`, `#on_unrealize`,
  # `#on_resize` and `#on_render`; `#on_render` draws into the bound
  # framebuffer, whose contents `#buffer_age` describes. A canvas
  # unrealizes and realizes again when its surface moves between splits, so
  # GL objects are made in `#on_realize` and freed in `#on_unrealize`.
  #
  # A canvas draws a frame when it is shown, resized or moved to another
  # scale, and after `#queue_render`; GTK shows the last frame meanwhile.
  # The framebuffer matches the display's pixels, fractional scales too.
  # Positions and sizes are in framebuffer pixels: logical pixels times
  # `#scale`. Use a canvas on the GTK thread only; `App#post` reaches it from
  # other threads.
  #
  # ```
  # class Clear < Apprt::Canvas
  #   protected def on_render : Nil
  #     LibGL.glClearColor(0.1, 0.1, 0.1, 1.0)
  #     LibGL.glClear(LibGL::COLOR_BUFFER_BIT)
  #   end
  # end
  # ```
  # When the display showed a frame of a `Canvas`.
  #
  # *frame* is the frame clock's number of the frame (`Canvas#frame`).
  # *presented* is when it reached the screen, on the clock of
  # `CLOCK_MONOTONIC`, and *refresh_interval* the display's refresh period;
  # either is `nil` when the compositor does not tell.
  record FrameTiming, frame : Int64, presented : Time::Span?, refresh_interval : Time::Span?

  abstract class Canvas < Content
    # OpenGL flavours.
    @[Flags]
    enum API : UInt8
      GL   = 1
      GLES = 2
    end

    # What the canvas takes as text input; input methods and on-screen
    # keyboards adapt to it.
    enum InputPurpose
      # Any text.
      FreeForm
      # Letters only.
      Alpha
      # Digits only.
      Digits
      # A number.
      Number
      # A phone number.
      Phone
      # A URL.
      Url
      # An email address.
      Email
      # A person's name.
      Name
      # A hidden password.
      Password
      # A hidden PIN.
      Pin
      # A terminal: keys go to a program, which may not show them as text.
      Terminal
    end

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

    # :nodoc:
    getter widget : Widget

    # Returns the framebuffer width; 0 until the first `#on_resize`.
    getter width : Int32 = 0

    # Returns the framebuffer height; 0 until the first `#on_resize`.
    getter height : Int32 = 0

    # Returns why GTK could not make the GL context, or `nil`.
    getter error : String?

    # Returns how many frames ago the framebuffer `#on_render` draws into
    # was last drawn: 1 when it holds the previous frame, 0 when its
    # contents are undefined. Only the colors are kept; depth and stencil
    # are undefined.
    getter buffer_age : Int32 = 0

    # Returns the number of the frame clock frame the canvas last drew, as
    # `FrameTiming#frame` reports it; 0 before the first frame.
    getter frame : Int64 = 0

    @area : Widget
    @picture : Widget
    @api : API
    @version : {Int32, Int32}?
    @depth_stencil : Bool
    @offload : Bool
    @context : GLContext?
    @buffers : CanvasBuffers?
    @logical_width = 0
    @logical_height = 0
    @render_queued = false
    @tick = 0_u32
    @scale_handler = 0_u64
    @scale_surface = Pointer(Void).null
    @presenting = [] of Int64

    @key_controller : Void*
    @click_gesture : Void*
    @scroll_controller : Void*
    @motion_controller : Void*
    @im_context : Void*
    @widget_destroyed = false
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

    private RENDER_TICK = ->(_widget : Void*, clock : Void*, data : Void*) do
      Handles.get(data, Canvas).tick(clock) ? 1 : 0
    end

    # Creates the canvas. GTK picks an OpenGL flavour among *api* that offers
    # at least *version* (`{major, minor}`), with depth and stencil buffers
    # when asked. *input_purpose* tells the input method what text the
    # canvas takes.
    #
    # With *offload*, frames go to GTK as DMA-BUFs where the driver can
    # export them, and the compositor may show them on a subsurface without
    # GTK copying them; `#dmabuf?` tells whether the last frame went so.
    def initialize(*, api : API = API::All, version : {Int32, Int32}? = nil,
                   depth_buffer : Bool = false, stencil_buffer : Bool = false,
                   input_purpose : InputPurpose = InputPurpose::FreeForm, offload : Bool = false)
      @api = api
      @version = version
      @depth_stencil = depth_buffer || stencil_buffer
      @offload = offload
      @widget = Widget.new(C.gtk_overlay_new)
      @area = Widget.new(C.gtk_drawing_area_new)
      @picture = Widget.new(C.gtk_picture_new)
      C.gtk_overlay_set_child(@widget, @area)
      frame = offload ? Widget.new(C.gtk_graphics_offload_new(@picture)) : @picture
      C.gtk_overlay_add_overlay(@widget, frame)
      C.gtk_widget_set_can_target(frame, 0)
      C.gtk_widget_set_can_target(@picture, 0)
      C.gtk_picture_set_can_shrink(@picture, 1)
      C.gtk_picture_set_content_fit(@picture, C::GtkContentFit::Fill)
      @picture.add_css_class("canvas-frame")
      area = @widget
      area.hexpand = true
      area.vexpand = true
      area.focusable = true
      area.focus_on_click = true
      @im_context = C.gtk_im_multicontext_new
      set_input_purpose(input_purpose)
      @key_controller = C.gtk_event_controller_key_new
      @click_gesture = C.gtk_gesture_click_new
      @scroll_controller = C.gtk_event_controller_scroll_new(C::GtkEventControllerScrollFlags::BothAxes)
      @motion_controller = C.gtk_event_controller_motion_new
      @drop_target = C.gtk_drop_target_async_new(nil, DragAction::All.to_gdk)
      connect_area
      connect_keys
      connect_im
      connect_pointer
      connect_drops
    end

    # Returns the OpenGL flavour in use, or `nil` while there is no context.
    def api : API?
      @context.try(&.api)
    end

    # Returns whether the last frame went to GTK as a DMA-BUF; always false
    # without *offload* (see `.new`).
    def dmabuf? : Bool
      @buffers.try(&.dmabuf?) || false
    end

    # Returns the GL context the canvas draws with, or `nil` while it has
    # none.
    def gl_context : GLContext?
      @context
    end

    # Returns the framebuffer pixels per logical pixel, which may be
    # fractional (1.25, 1.5).
    def scale : Float64
      return 1.0 if @widget_destroyed || @scale_surface.null?
      C.gdk_surface_get_scale(@scale_surface)
    end

    # Asks for `#on_render` before the next frame.
    def queue_render : Nil
      @render_queued = true
      start_ticking
    end

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
    # Called with the GL context current once GTK made it; makes the GL
    # objects the canvas draws with.
    protected def on_realize : Nil
    end

    # :showdoc:
    #
    # Called with the GL context current before GTK drops it; frees the GL
    # objects.
    protected def on_unrealize : Nil
    end

    # :showdoc:
    #
    # Draws a frame into the bound framebuffer.
    protected abstract def on_render : Nil

    # :showdoc:
    #
    # Called when the framebuffer size changes, before the next
    # `#on_render`.
    protected def on_resize(width : Int32, height : Int32) : Nil
    end

    # :showdoc:
    #
    # Called once the display showed the frame *timing* names, or dropped
    # it; frames GTK replaced before showing them are never reported.
    protected def on_presented(timing : FrameTiming) : Nil
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
      value = C::GValue.new
      C.g_value_init(pointerof(value), C.g_type_from_name("GtkInputPurpose"))
      C.g_value_set_enum(pointerof(value), C::GtkInputPurpose.new(purpose.value).value)
      C.g_object_set_property(@im_context, "input-purpose", pointerof(value))
      C.g_value_unset(pointerof(value))
    end

    private def connect_area : Nil
      Signals.connect(@widget, "realize", -> { realize })
      Signals.connect(@widget, "unrealize", -> { unrealize })
      Signals.connect(@area, "resize", ->(width : Int32, height : Int32) { resize(width, height) })
      Signals.connect(@widget, "destroy", -> { destroy })
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

    private def realize : Nil
      C.gtk_im_context_set_client_widget(@im_context, @widget)
      watch_scale
      context = GLContext.new(api: @api, version: @version)
      @error = nil
      @context = context
      context.make_current
      @buffers = CanvasBuffers.new(context, @depth_stencil, @offload)
      on_realize
      queue_render
    rescue ex : GLibError
      @error = message = ex.message
      Log.error { "GL context: #{message}" }
    end

    private def unrealize : Nil
      stop_ticking
      C.gtk_picture_set_paintable(@picture, nil)
      if context = @context
        context.make_current
        begin
          on_unrealize
        ensure
          @buffers.try(&.release)
          GLContext.clear_current
        end
      end
    ensure
      @context = nil
      @buffers = nil
      @width = @height = 0
      @presenting.clear
      unwatch_scale
      C.gtk_im_context_set_client_widget(@im_context, nil)
    end

    # The canvas holds the only reference to its input method.
    private def destroy : Nil
      return if @widget_destroyed
      @widget_destroyed = true
      C.g_object_unref(@im_context)
    end

    private def resize(width : Int32, height : Int32) : Nil
      @logical_width = width
      @logical_height = height
      queue_render
    end

    # Follows the scale of the window's surface, which changes when it
    # moves to another output.
    private def watch_scale : Nil
      native = C.gtk_widget_get_native(@widget)
      surface = native.null? ? Pointer(Void).null : C.gtk_native_get_surface(native)
      return if surface.null?
      @scale_surface = surface
      @scale_handler = Signals.notify(surface, "scale", -> { queue_render })
    end

    private def unwatch_scale : Nil
      Signals.disconnect(@scale_surface, @scale_handler) unless @scale_surface.null?
      @scale_surface = Pointer(Void).null
      @scale_handler = 0_u64
    end

    private def start_ticking : Nil
      return unless @tick == 0 && !@widget_destroyed && @widget.realized? && @context
      @tick = C.gtk_widget_add_tick_callback(@widget, RENDER_TICK, Handles.retain(self), Handles::RELEASE)
    end

    private def stop_ticking : Nil
      return if @tick == 0
      C.gtk_widget_remove_tick_callback(@widget, @tick)
      @tick = 0_u32
    end

    # Draws the queued frame and reports the shown ones; returns whether
    # the canvas needs further ticks.
    protected def tick(clock : Void*) : Bool
      if @render_queued
        @render_queued = false
        render(clock)
      end
      report_presented(clock)
      keep = @render_queued || !@presenting.empty?
      @tick = 0_u32 unless keep
      keep
    end

    private def render(clock : Void*) : Nil
      context = @context || return
      buffers = @buffers || return
      scale = self.scale
      width = (@logical_width * scale).round.to_i32
      height = (@logical_height * scale).round.to_i32
      return if width <= 0 || height <= 0
      context.make_current
      unless width == @width && height == @height
        @width = width
        @height = height
        on_resize(width, height)
      end
      buffer, @buffer_age = buffers.acquire(width, height)
      begin
        on_render
      ensure
        texture = buffers.texture(buffer)
        C.gtk_picture_set_paintable(@picture, texture)
        C.g_object_unref(texture)
        @frame = C.gdk_frame_clock_get_frame_counter(clock)
        @presenting << @frame
      end
    end

    private def report_presented(clock : Void*) : Nil
      @presenting.reject! do |frame|
        timings = C.gdk_frame_clock_get_timings(clock, frame)
        next true if timings.null?
        next false if C.gdk_frame_timings_get_complete(timings) == 0
        on_presented(FrameTiming.new(frame, microseconds(C.gdk_frame_timings_get_presentation_time(timings)),
          microseconds(C.gdk_frame_timings_get_refresh_interval(timings))))
        true
      end
    end

    private def microseconds(value : Int64) : Time::Span?
      value.microseconds unless value == 0
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
      repeat = pressed && !@held_keycodes.add?(keycode)
      @held_keycodes.delete(keycode) unless pressed
      if pressed && text.nil?
        code = C.gdk_keyval_to_unicode(keyval)
        text = code.chr.to_s if code >= 0x20 && code != 0x7f
      end
      text = nil unless pressed
      if event.null?
        code = C.gdk_keyval_to_unicode(C.gdk_keyval_to_lower(keyval))
        unshifted = code.chr unless code == 0
        return KeyEvent.new(pressed, keyval, keycode, mods, Mods::None, text, unshifted, MODIFIER_KEYS.has_key?(keyval),
          composing, repeat: repeat, base: unshifted)
      end
      layout = C.gdk_key_event_get_layout(event)
      unshifted, shifted, base = layout_chars(keycode, layout)
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
