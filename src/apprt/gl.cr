# src/apprt/gl.cr
module Apprt
  # :nodoc:
  # The OpenGL calls the canvas makes itself, through libepoxy's function
  # pointers (the library GTK resolves GL with).
  @[Link(pkg_config: "epoxy")]
  lib GL
    FRAMEBUFFER                = 0x8D40_u32
    RENDERBUFFER               = 0x8D41_u32
    TEXTURE_2D                 = 0x0DE1_u32
    TEXTURE_MIN_FILTER         = 0x2801_u32
    TEXTURE_MAG_FILTER         = 0x2800_u32
    NEAREST                    =     0x2600
    RGBA                       = 0x1908_u32
    RGBA8                      =     0x8058
    UNSIGNED_BYTE              = 0x1401_u32
    COLOR_ATTACHMENT0          = 0x8CE0_u32
    DEPTH_STENCIL_ATTACHMENT   = 0x821A_u32
    DEPTH24_STENCIL8           = 0x88F0_u32
    FRAMEBUFFER_COMPLETE       = 0x8CD5_u32
    SYNC_GPU_COMMANDS_COMPLETE = 0x9117_u32

    fun epoxy_gl_version : Int32
    fun epoxy_is_desktop_gl : Int32

    $epoxy_glGenFramebuffers : (Int32, UInt32* -> Void)
    $epoxy_glDeleteFramebuffers : (Int32, UInt32* -> Void)
    $epoxy_glBindFramebuffer : (UInt32, UInt32 -> Void)
    $epoxy_glFramebufferTexture2D : (UInt32, UInt32, UInt32, UInt32, Int32 -> Void)
    $epoxy_glFramebufferRenderbuffer : (UInt32, UInt32, UInt32, UInt32 -> Void)
    $epoxy_glCheckFramebufferStatus : (UInt32 -> UInt32)
    $epoxy_glGenTextures : (Int32, UInt32* -> Void)
    $epoxy_glDeleteTextures : (Int32, UInt32* -> Void)
    $epoxy_glBindTexture : (UInt32, UInt32 -> Void)
    $epoxy_glTexImage2D : (UInt32, Int32, Int32, Int32, Int32, Int32, UInt32, UInt32, Void* -> Void)
    $epoxy_glTexParameteri : (UInt32, UInt32, Int32 -> Void)
    $epoxy_glGenRenderbuffers : (Int32, UInt32* -> Void)
    $epoxy_glDeleteRenderbuffers : (Int32, UInt32* -> Void)
    $epoxy_glBindRenderbuffer : (UInt32, UInt32 -> Void)
    $epoxy_glRenderbufferStorage : (UInt32, UInt32, Int32, Int32 -> Void)
    $epoxy_glViewport : (Int32, Int32, Int32, Int32 -> Void)
    $epoxy_glFenceSync : (UInt32, UInt32 -> Void*)
    $epoxy_glDeleteSync : (Void* -> Void)
    $epoxy_glFlush : (-> Void)
  end

  # An OpenGL context on the application's display, for drawing off screen.
  #
  # Every context shares its objects (textures, buffers, programs) with
  # the others of the display, a canvas's too. Use it on the GTK thread
  # only, while the application runs.
  class GLContext < Wrapper
    # Creates and realizes a context of one of *api*'s flavours that offers
    # at least *version* (`{major, minor}`). Raises `GLibError` when the
    # display has no such context.
    def self.new(*, api : Canvas::API = Canvas::API::All, version : {Int32, Int32}? = nil) : self
      display = C.gdk_display_get_default
      raise GLibError.new("apprt", 0, "no display") if display.null?
      context = take(GLibError.check! { |error| C.gdk_display_create_gl_context(display, error) })
      C.gdk_gl_context_set_allowed_apis(context, C::GdkGLAPI.new(api.value.to_u32))
      version.try { |(major, minor)| C.gdk_gl_context_set_required_version(context, major, minor) }
      GLibError.check! { |error| C.gdk_gl_context_realize(context, error) }
      context
    end

    # Makes no context current on this thread.
    def self.clear_current : Nil
      C.gdk_gl_context_clear_current
    end

    # Returns the flavour the context uses.
    def api : Canvas::API
      Canvas::API.new(C.gdk_gl_context_get_api(self).value.to_u8)
    end

    # Makes the context current on this thread.
    def make_current : Nil
      C.gdk_gl_context_make_current(self)
    end

    # Whether the context is the current one.
    def current? : Bool
      C.gdk_gl_context_get_current == to_unsafe
    end
  end

  # :nodoc:
  # The color buffers a `Canvas` draws into and hands GTK as textures, with
  # one depth and stencil renderbuffer shared by all of them. A buffer is
  # busy from `#acquire` until GTK drops its texture; GTK may still hold
  # it after `#release`, so a released pool deletes it then, from the
  # context it was made with.
  class CanvasBuffers
    class Buffer
      getter texture = 0_u32
      getter framebuffer = 0_u32
      getter width : Int32
      getter height : Int32
      # The pool's frame count when the buffer was last drawn; 0 if never.
      property drawn = 0_i64
      property? busy = false
      property? orphaned = false
      property sync = Pointer(Void).null

      def initialize(@context : GLContext, @width : Int32, @height : Int32, depth : UInt32)
        GL.epoxy_glGenTextures.call(1, pointerof(@texture))
        GL.epoxy_glBindTexture.call(GL::TEXTURE_2D, @texture)
        GL.epoxy_glTexParameteri.call(GL::TEXTURE_2D, GL::TEXTURE_MIN_FILTER, GL::NEAREST)
        GL.epoxy_glTexParameteri.call(GL::TEXTURE_2D, GL::TEXTURE_MAG_FILTER, GL::NEAREST)
        GL.epoxy_glTexImage2D.call(GL::TEXTURE_2D, 0, GL::RGBA8, width, height, 0, GL::RGBA, GL::UNSIGNED_BYTE, Pointer(Void).null)
        GL.epoxy_glBindTexture.call(GL::TEXTURE_2D, 0_u32)
        GL.epoxy_glGenFramebuffers.call(1, pointerof(@framebuffer))
        GL.epoxy_glBindFramebuffer.call(GL::FRAMEBUFFER, @framebuffer)
        GL.epoxy_glFramebufferTexture2D.call(GL::FRAMEBUFFER, GL::COLOR_ATTACHMENT0, GL::TEXTURE_2D, @texture, 0)
        unless depth == 0
          GL.epoxy_glFramebufferRenderbuffer.call(GL::FRAMEBUFFER, GL::DEPTH_STENCIL_ATTACHMENT, GL::RENDERBUFFER, depth)
        end
        status = GL.epoxy_glCheckFramebufferStatus.call(GL::FRAMEBUFFER)
        GL.epoxy_glBindFramebuffer.call(GL::FRAMEBUFFER, 0_u32)
        Log.warn { "canvas framebuffer incomplete: 0x#{status.to_s(16)}" } unless status == GL::FRAMEBUFFER_COMPLETE
      end

      # Called when GTK drops the buffer's texture.
      def released : Nil
        @busy = false
        delete_later if @orphaned
      end

      # Deletes the GL objects with the buffer's own context current, then
      # restores the context that was current.
      def delete_later : Nil
        previous = C.gdk_gl_context_get_current
        @context.make_current
        delete
        previous.null? ? GLContext.clear_current : C.gdk_gl_context_make_current(previous)
      end

      # Deletes the GL objects; the buffer's context must be current.
      def delete : Nil
        GL.epoxy_glDeleteSync.call(@sync) unless @sync.null?
        @sync = Pointer(Void).null
        GL.epoxy_glDeleteFramebuffers.call(1, pointerof(@framebuffer))
        GL.epoxy_glDeleteTextures.call(1, pointerof(@texture))
      end
    end

    private RELEASED = ->(data : Void*) do
      buffer = Handles.get(data, Buffer)
      Handles.release(data)
      UIThread.dispatch { buffer.released }
      nil
    end

    @buffers = [] of Buffer
    @depth = 0_u32
    @width = 0
    @height = 0
    # Frames drawn since the pool was made.
    @frames = 0_i64

    def initialize(@context : GLContext, @depth_stencil : Bool)
    end

    # Returns a free buffer of *width* × *height* pixels, bound as the draw
    # framebuffer, and its age: how many frames ago it was last drawn, 0
    # when its contents are undefined. The context must be current.
    def acquire(width : Int32, height : Int32) : {Buffer, Int32}
      resize(width, height) unless width == @width && height == @height
      free = @buffers.reject(&.busy?)
      buffer = free.max_by?(&.drawn) || Buffer.new(@context, width, height, @depth).tap { |made| @buffers << made }
      age = buffer.drawn == 0 ? 0 : (@frames + 1 - buffer.drawn).to_i32
      buffer.busy = true
      @frames += 1
      buffer.drawn = @frames
      GL.epoxy_glBindFramebuffer.call(GL::FRAMEBUFFER, buffer.framebuffer)
      GL.epoxy_glViewport.call(0, 0, width, height)
      {buffer, age}
    end

    # Fences the drawn *buffer* and returns a new `GdkGLTexture` of it; the
    # caller owns the texture. The context must be current.
    def texture(buffer : Buffer) : Void*
      GL.epoxy_glBindFramebuffer.call(GL::FRAMEBUFFER, 0_u32)
      GL.epoxy_glDeleteSync.call(buffer.sync) unless buffer.sync.null?
      buffer.sync = fences? ? GL.epoxy_glFenceSync.call(GL::SYNC_GPU_COMMANDS_COMPLETE, 0_u32) : Pointer(Void).null
      GL.epoxy_glFlush.call
      builder = C.gdk_gl_texture_builder_new
      C.gdk_gl_texture_builder_set_context(builder, @context)
      C.gdk_gl_texture_builder_set_id(builder, buffer.texture)
      C.gdk_gl_texture_builder_set_width(builder, buffer.width)
      C.gdk_gl_texture_builder_set_height(builder, buffer.height)
      C.gdk_gl_texture_builder_set_format(builder, C::GdkMemoryFormat::R8g8b8a8Premultiplied)
      C.gdk_gl_texture_builder_set_sync(builder, buffer.sync) unless buffer.sync.null?
      texture = C.gdk_gl_texture_builder_build(builder, RELEASED, Handles.retain(buffer))
      C.g_object_unref(builder)
      texture
    end

    # Deletes the free buffers and the renderbuffer and leaves the busy
    # buffers to be deleted once GTK drops them. The context must be
    # current.
    def release : Nil
      @buffers.each { |buffer| buffer.busy? ? buffer.orphaned = true : buffer.delete }
      @buffers.clear
      GL.epoxy_glDeleteRenderbuffers.call(1, pointerof(@depth)) unless @depth == 0
      @depth = 0_u32
    end

    private def resize(width : Int32, height : Int32) : Nil
      release
      @width = width
      @height = height
      return unless @depth_stencil
      GL.epoxy_glGenRenderbuffers.call(1, pointerof(@depth))
      GL.epoxy_glBindRenderbuffer.call(GL::RENDERBUFFER, @depth)
      GL.epoxy_glRenderbufferStorage.call(GL::RENDERBUFFER, GL::DEPTH24_STENCIL8, width, height)
      GL.epoxy_glBindRenderbuffer.call(GL::RENDERBUFFER, 0_u32)
    end

    # Fence syncs need OpenGL 3.2 or OpenGL ES 3.0.
    private def fences? : Bool
      GL.epoxy_gl_version >= (GL.epoxy_is_desktop_gl != 0 ? 32 : 30)
    end
  end
end
