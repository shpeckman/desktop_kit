# src/apprt/content/canvas.cr
module Apprt
  # When the display showed a frame of a `Canvas`.
  #
  # *frame* is the frame clock's number of the frame (`Canvas#frame`).
  # *presented* is when it reached the screen, on the clock of
  # `CLOCK_MONOTONIC`, and *refresh_interval* the display's refresh period;
  # either is `nil` when the compositor does not tell.
  record FrameTiming, frame : Int64, presented : Time::Span?, refresh_interval : Time::Span?

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
  # other threads. A *threaded* canvas (see `.new`) is the exception.
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
    @threaded : Bool
    # The render thread's job queue and the thread, while a threaded canvas
    # is realized.
    @jobs : Channel(Job)?
    @renderer : Fiber::ExecutionContext::Isolated?
    @rendering = false
    # A frame the render thread finished, shown at the next tick.
    @finished = Pointer(Void).null

    @widget_destroyed = false

    # A frame for the render thread to draw at *width* × *height*.
    private record Job, width : Int32, height : Int32

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
    #
    # A *threaded* canvas draws on a thread of its own: `#on_realize`,
    # `#on_unrealize`, `#on_resize` and `#on_render` run there, never on the
    # GTK thread, and must not call GTK. `#queue_render` may be called from
    # either thread. GTK keeps showing the previous frame until the thread
    # finishes the next; one frame is drawn at a time.
    def initialize(*, api : API = API::All, version : {Int32, Int32}? = nil,
                   depth_buffer : Bool = false, stencil_buffer : Bool = false,
                   input_purpose : InputPurpose = InputPurpose::FreeForm, offload : Bool = false,
                   threaded : Bool = false)
      @api = api
      @threaded = threaded
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
      UIThread.dispatch do
        @render_queued = true
        start_ticking
      end
    end

    # Returns whether the canvas draws on a thread of its own.
    def threaded? : Bool
      @threaded
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

    private def connect_area : Nil
      Signals.connect(@widget, "realize", -> { realize })
      Signals.connect(@widget, "unrealize", -> { unrealize })
      Signals.connect(@area, "resize", ->(width : Int32, height : Int32) { resize(width, height) })
      Signals.connect(@widget, "destroy", -> { destroy })
    end

    private def realize : Nil
      C.gtk_im_context_set_client_widget(@im_context, @widget)
      watch_scale
      context = GLContext.new(api: @api, version: @version)
      @error = nil
      @context = context
      if @threaded
        start_renderer(context)
      else
        context.make_current
        @buffers = CanvasBuffers.new(context, @depth_stencil, @offload)
        on_realize
      end
      queue_render
    rescue ex : GLibError
      @error = message = ex.message
      Log.error { "GL context: #{message}" }
    end

    private def unrealize : Nil
      stop_ticking
      C.gtk_picture_set_paintable(@picture, nil)
      if renderer = @renderer
        stop_renderer(renderer)
      elsif context = @context
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
      unless @finished.null?
        present(@finished, clock)
        @finished = Pointer(Void).null
      end
      if @render_queued && !@rendering
        @render_queued = false
        render(clock)
      end
      report_presented(clock)
      keep = @render_queued || @rendering || !@presenting.empty?
      @tick = 0_u32 unless keep
      keep
    end

    private def render(clock : Void*) : Nil
      context = @context || return
      scale = self.scale
      width = (@logical_width * scale).round.to_i32
      height = (@logical_height * scale).round.to_i32
      return if width <= 0 || height <= 0
      if jobs = @jobs
        @rendering = true
        jobs.send(Job.new(width, height))
      else
        buffers = @buffers || return
        context.make_current
        draw(buffers, width, height) { |texture| present(texture, clock) }
      end
    end

    # Draws a frame of *width* × *height* pixels with the context current
    # and yields its texture, which the block owns, even when `#on_render`
    # raises.
    private def draw(buffers : CanvasBuffers, width : Int32, height : Int32, & : Void* ->) : Nil
      unless width == @width && height == @height
        @width = width
        @height = height
        on_resize(width, height)
      end
      buffer, @buffer_age = buffers.acquire(width, height)
      begin
        on_render
      ensure
        yield buffers.texture(buffer)
      end
    end

    # Shows *texture* from the frame *clock* is drawing and drops it.
    private def present(texture : Void*, clock : Void*) : Nil
      C.gtk_picture_set_paintable(@picture, texture)
      C.g_object_unref(texture)
      @frame = C.gdk_frame_clock_get_frame_counter(clock)
      @presenting << @frame
    end

    # Starts the render thread, which realizes the canvas with *context*.
    # Jobs never block the GTK thread: one frame is drawn at a time and the
    # queue holds it and the close.
    private def start_renderer(context : GLContext) : Nil
      jobs = Channel(Job).new(2)
      @jobs = jobs
      @rendering = false
      @renderer = Fiber::ExecutionContext::Isolated.new("canvas") { run_renderer(context, jobs) }
    end

    # Closes the job queue and waits until the render thread unrealized the
    # canvas.
    private def stop_renderer(renderer : Fiber::ExecutionContext::Isolated) : Nil
      @jobs.try(&.close)
      renderer.wait
    ensure
      @jobs = nil
      @renderer = nil
      @rendering = false
      unless @finished.null?
        C.g_object_unref(@finished)
        @finished = Pointer(Void).null
      end
    end

    private def run_renderer(context : GLContext, jobs : Channel(Job)) : Nil
      context.make_current
      buffers = CanvasBuffers.new(context, @depth_stencil, @offload)
      @buffers = buffers
      logged { on_realize }
      while job = jobs.receive?
        texture = Pointer(Void).null
        logged { draw(buffers, job.width, job.height) { |drawn| texture = drawn } }
        UIThread.post { finished(jobs, texture) }
      end
      logged { on_unrealize }
      buffers.release
      GLContext.clear_current
    end

    # Takes the frame the render thread drew for *jobs*, null if it failed,
    # and shows it at the next tick; a frame of a stopped thread is dropped.
    private def finished(jobs : Channel(Job), texture : Void*) : Nil
      unless jobs.same?(@jobs)
        C.g_object_unref(texture) unless texture.null?
        return
      end
      @rendering = false
      @finished = texture
      start_ticking if !texture.null? || @render_queued
    end

    # Runs a hook on the render thread, logging what it raises.
    private def logged(&) : Nil
      yield
    rescue ex
      Log.error(exception: ex) { "canvas render thread" }
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
  end
end
