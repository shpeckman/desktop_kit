# src/apprt/canvas.cr
module Apprt
  # Content drawn with OpenGL that takes the keyboard, the mouse and input
  # method text.
  #
  # Subclasses draw in `#on_render` and override the other hooks they need.
  # The GL context is current in `#on_realize`, `#on_unrealize` and
  # `#on_render`; `#on_render` draws into the bound framebuffer. A canvas
  # unrealizes and realizes again when its surface moves between splits, so
  # GL objects are made in `#on_realize` and freed in `#on_unrealize`.
  #
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
  abstract class Canvas < Content
    # OpenGL flavours.
    @[Flags]
    enum API : UInt8
      GL   = 1
      GLES = 2
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

    # Creates the canvas. GTK picks an OpenGL flavour among *api* that offers
    # at least *version* (`{major, minor}`), with depth and stencil buffers
    # when asked.
    def initialize(*, api : API = API::All, version : {Int32, Int32}? = nil,
                   depth_buffer : Bool = false, stencil_buffer : Bool = false)
      @widget = Widget.new(C.gtk_gl_area_new)
      area = @widget
      C.gtk_gl_area_set_allowed_apis(area, C::GdkGLAPI.new(api.value.to_u32))
      version.try { |(major, minor)| C.gtk_gl_area_set_required_version(area, major, minor) }
      C.gtk_gl_area_set_has_depth_buffer(area, depth_buffer ? 1 : 0)
      C.gtk_gl_area_set_has_stencil_buffer(area, stencil_buffer ? 1 : 0)
      area.hexpand = true
      area.vexpand = true
      area.focusable = true
      area.focus_on_click = true
      @im_context = C.gtk_im_multicontext_new
      @key_controller = C.gtk_event_controller_key_new
      @click_gesture = C.gtk_gesture_click_new
      @scroll_controller = C.gtk_event_controller_scroll_new(C::GtkEventControllerScrollFlags::BothAxes)
      @motion_controller = C.gtk_event_controller_motion_new
      connect_area
      connect_keys
      connect_im
      connect_pointer
    end

    # Returns the OpenGL flavour in use, or `nil` while there is no context.
    def api : API?
      return if @widget_destroyed || @error || !@widget.realized?
      api = API.new(C.gtk_gl_area_get_api(@widget).value.to_u8)
      api unless api.none?
    end

    # Returns the framebuffer pixels per logical pixel.
    def scale : Int32
      @widget_destroyed ? 1 : @widget.scale_factor
    end

    # Asks GTK to call `#on_render` before the next frame.
    def queue_render : Nil
      C.gtk_gl_area_queue_render(@widget) unless @widget_destroyed
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

    private def connect_area : Nil
      area = @widget
      Signals.connect(area, "realize", -> { realize })
      Signals.connect(area, "unrealize", -> { unrealize })
      Signals.connect(area, "render", ->(_context : Void*) : Bool { on_render if @error.nil?; true })
      Signals.connect(area, "resize", ->(width : Int32, height : Int32) { resize(width, height) })
      Signals.connect(area, "destroy", -> { destroy })
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
      Signals.connect(@motion_controller, "motion", ->(x : Float64, y : Float64) {
        scale = self.scale
        on_mouse_motion(MouseMotionEvent.new(x * scale, y * scale, mods(@motion_controller)))
      })
      Signals.connect(@motion_controller, "leave", -> { on_mouse_leave })
      @widget.add_controller(@motion_controller)
      Signals.connect(@scroll_controller, "scroll", ->(dx : Float64, dy : Float64) : Bool { scroll(dx, dy); true })
      @widget.add_controller(@scroll_controller)
    end

    private def realize : Nil
      C.gtk_im_context_set_client_widget(@im_context, @widget)
      C.gtk_gl_area_make_current(@widget)
      error = C.gtk_gl_area_get_error(@widget)
      if error.null?
        @error = nil
        on_realize
      else
        @error = message = String.new(error.value.message)
        Log.error { "GL context: #{message}" }
      end
    end

    private def unrealize : Nil
      if @error.nil?
        C.gtk_gl_area_make_current(@widget)
        on_unrealize
      end
    ensure
      C.gtk_im_context_set_client_widget(@im_context, nil)
    end

    # The canvas holds the only reference to its input method.
    private def destroy : Nil
      return if @widget_destroyed
      @widget_destroyed = true
      C.g_object_unref(@im_context)
    end

    private def resize(width : Int32, height : Int32) : Nil
      @width = width
      @height = height
      on_resize(width, height)
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
      modifier = event.null? ? MODIFIER_KEYS.has_key?(keyval) : C.gdk_key_event_is_modifier(event) != 0
      consumed = event.null? ? Mods::None : Mods.from_gdk(C.gdk_key_event_get_consumed_modifiers(event))
      if pressed && text.nil?
        code = C.gdk_keyval_to_unicode(keyval)
        text = code.chr.to_s if code >= 0x20 && code != 0x7f
      end
      text = nil unless pressed
      code = event.null? ? C.gdk_keyval_to_unicode(C.gdk_keyval_to_lower(keyval)) : layout_code(event, keycode)
      KeyEvent.new(pressed, keyval, keycode, mods, consumed, text, (code.chr unless code == 0), modifier, composing)
    end

    # Returns the character code of *keycode* at level 0 of the event's
    # layout, or 0.
    private def layout_code(event : Void*, keycode : UInt32) : UInt32
      layout = C.gdk_key_event_get_layout(event).to_i32
      return 0_u32 if C.gdk_display_map_keycode(@widget.display, keycode, out keys, out keyvals, out count) == 0
      begin
        count.times do |index|
          key = keys[index]
          return C.gdk_keyval_to_unicode(keyvals[index]) if key.group == layout && key.level == 0
        end
        0_u32
      ensure
        C.g_free(keys.as(Void*))
        C.g_free(keyvals.as(Void*))
      end
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

    private def focus_changed(focused : Bool) : Nil
      focused ? C.gtk_im_context_focus_in(@im_context) : C.gtk_im_context_focus_out(@im_context)
      on_focus(focused)
    end

    private def button(pressed : Bool, x : Float64, y : Float64) : Nil
      @widget.grab_focus if pressed
      scale = self.scale
      button = MouseButton.new(C.gtk_gesture_single_get_current_button(@click_gesture).to_i32)
      on_mouse_button(MouseButtonEvent.new(pressed, button, x * scale, y * scale, mods(@click_gesture)))
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
