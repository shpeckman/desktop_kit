# src/apprt/content/gl.cr
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

    EGL_GL_TEXTURE_2D_KHR    = 0x30B1_u32
    EGL_GL_TEXTURE_LEVEL_KHR =     0x30BC
    EGL_NONE                 =     0x3038

    fun epoxy_gl_version : Int32
    fun epoxy_is_desktop_gl : Int32
    fun epoxy_has_egl : Int32
    fun epoxy_has_egl_extension(display : Void*, extension : UInt8*) : Int32

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

    $epoxy_eglGetCurrentDisplay : (-> Void*)
    $epoxy_eglGetCurrentContext : (-> Void*)
    $epoxy_eglCreateImageKHR : (Void*, Void*, UInt32, Void*, Int32* -> Void*)
    $epoxy_eglDestroyImageKHR : (Void*, Void* -> UInt32)
    $epoxy_eglExportDMABUFImageQueryMESA : (Void*, Void*, Int32*, Int32*, UInt64* -> UInt32)
    $epoxy_eglExportDMABUFImageMESA : (Void*, Void*, Int32*, Int32*, Int32* -> UInt32)
  end

  # :nodoc:
  # The DMA-BUF planes of a GL texture, exported through
  # `EGL_MESA_image_dma_buf_export`. The buffer owns the file descriptors.
  struct Dmabuf
    MAX_PLANES = 4
    EXTENSIONS = {"EGL_KHR_gl_texture_2D_image", "EGL_MESA_image_dma_buf_export"}

    getter fourcc : UInt32
    getter modifier : UInt64
    getter planes : Int32
    getter fds : StaticArray(Int32, 4)
    getter strides : StaticArray(Int32, 4)
    getter offsets : StaticArray(Int32, 4)

    def initialize(@fourcc, @modifier, @planes, @fds, @strides, @offsets)
    end

    # Returns whether the current context can export textures.
    def self.supported? : Bool
      return false if GL.epoxy_has_egl == 0
      display = GL.epoxy_eglGetCurrentDisplay.call
      return false if display.null? || GL.epoxy_eglGetCurrentContext.call.null?
      EXTENSIONS.all? { |name| GL.epoxy_has_egl_extension(display, name) != 0 }
    end

    # Exports *texture* of the current context, or returns `nil` when EGL
    # refuses.
    def self.export(texture : UInt32) : Dmabuf?
      display = GL.epoxy_eglGetCurrentDisplay.call
      context = GL.epoxy_eglGetCurrentContext.call
      attributes = StaticArray[GL::EGL_GL_TEXTURE_LEVEL_KHR, 0, GL::EGL_NONE]
      image = GL.epoxy_eglCreateImageKHR.call(display, context, GL::EGL_GL_TEXTURE_2D_KHR,
        Pointer(Void).new(texture.to_u64), attributes.to_unsafe)
      return if image.null?
      begin
        fourcc = 0
        planes = 0
        modifiers = StaticArray(UInt64, 4).new(0_u64)
        return if GL.epoxy_eglExportDMABUFImageQueryMESA.call(display, image, pointerof(fourcc), pointerof(planes), Pointer(UInt64).null) == 0
        return unless 0 < planes <= MAX_PLANES
        return if GL.epoxy_eglExportDMABUFImageQueryMESA.call(display, image, pointerof(fourcc), pointerof(planes), modifiers.to_unsafe) == 0
        fds = StaticArray(Int32, 4).new(-1)
        strides = StaticArray(Int32, 4).new(0)
        offsets = StaticArray(Int32, 4).new(0)
        return if GL.epoxy_eglExportDMABUFImageMESA.call(display, image, fds.to_unsafe, strides.to_unsafe, offsets.to_unsafe) == 0
        new(fourcc.to_u32!, modifiers[0], planes, fds, strides, offsets)
      ensure
        GL.epoxy_eglDestroyImageKHR.call(display, image)
      end
    end

    # Closes the file descriptors.
    def close : Nil
      seen = StaticArray(Int32, 4).new(-1)
      @planes.times do |plane|
        fd = @fds[plane]
        next if fd < 0 || seen.includes?(fd)
        seen[plane] = fd
        LibC.close(fd)
      end
    end
  end

  # An OpenGL context on the application's display, for drawing off screen.
  #
  # Every context shares its objects (textures, buffers, programs) with
  # the others of the display, a canvas's too. Create it on the GTK thread,
  # while the application runs; it is current on one thread at a time.
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
  # busy from `#acquire` until GTK drops its texture. GTK drops textures on
  # any thread, so returned buffers wait in a locked list until the thread
  # drawing with the pool collects them. GTK may still hold a buffer after
  # `#release`; a released pool deletes it then, on the GTK thread, from the
  # context it was made with.
  class CanvasBuffers
    class Buffer
      getter pool : CanvasBuffers
      getter texture = 0_u32
      getter framebuffer = 0_u32
      getter width : Int32
      getter height : Int32
      # The pool's frame count when the buffer was last drawn; 0 if never.
      property drawn = 0_i64
      property? busy = false
      property? orphaned = false
      property sync = Pointer(Void).null
      # The texture's DMA-BUF export, when offloading.
      getter dmabuf : Dmabuf?

      def initialize(@pool : CanvasBuffers, @context : GLContext, @width : Int32, @height : Int32, depth : UInt32, offload : Bool)
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
        @dmabuf = Dmabuf.export(@texture) if offload
      end

      # Closes the DMA-BUF export; later frames go as GL textures.
      def drop_dmabuf : Nil
        @dmabuf.try(&.close)
        @dmabuf = nil
      end

      # Deletes the GL objects with the buffer's own context current, then
      # restores the context that was current. GDK's thread may hold the
      # only reference to that context, dropped when another one becomes
      # current, so it is referenced meanwhile.
      def delete_later : Nil
        previous = C.gdk_gl_context_get_current
        C.g_object_ref(previous) unless previous.null?
        @context.make_current
        delete
        if previous.null?
          GLContext.clear_current
        else
          C.gdk_gl_context_make_current(previous)
          C.g_object_unref(previous)
        end
      end

      # Deletes the GL objects; the buffer's context must be current.
      def delete : Nil
        GL.epoxy_glDeleteSync.call(@sync) unless @sync.null?
        @sync = Pointer(Void).null
        GL.epoxy_glDeleteFramebuffers.call(1, pointerof(@framebuffer))
        GL.epoxy_glDeleteTextures.call(1, pointerof(@texture))
        drop_dmabuf
      end
    end

    private RELEASED = ->(data : Void*) do
      buffer = Handles.get(data, Buffer)
      Handles.release(data)
      buffer.pool.returned(buffer)
      nil
    end

    @buffers = [] of Buffer
    @depth = 0_u32
    @width = 0
    @height = 0
    # Frames drawn since the pool was made.
    @frames = 0_i64
    # Buffers whose textures GTK dropped, and whether `#release` closed the
    # pool; both guarded by @lock.
    @returned = [] of Buffer
    @closed = false
    @lock = Mutex.new

    # Returns whether the last texture was a `GdkDmabufTexture`.
    getter? dmabuf = false

    # With *offload*, buffers are exported as DMA-BUFs when the context
    # supports it (EGL with `EGL_MESA_image_dma_buf_export`); the context
    # must be current.
    def initialize(@context : GLContext, @depth_stencil : Bool, offload : Bool)
      @offload = offload && Dmabuf.supported?
    end

    # Returns a free buffer of *width* × *height* pixels, bound as the draw
    # framebuffer, and its age: how many frames ago it was last drawn, 0
    # when its contents are undefined. The context must be current.
    def acquire(width : Int32, height : Int32) : {Buffer, Int32}
      collect
      resize(width, height) unless width == @width && height == @height
      free = @buffers.reject(&.busy?)
      buffer = free.max_by?(&.drawn) || Buffer.new(self, @context, width, height, @depth, @offload).tap { |made| @buffers << made }
      age = buffer.drawn == 0 ? 0 : (@frames + 1 - buffer.drawn).to_i32
      buffer.busy = true
      @frames += 1
      buffer.drawn = @frames
      GL.epoxy_glBindFramebuffer.call(GL::FRAMEBUFFER, buffer.framebuffer)
      GL.epoxy_glViewport.call(0, 0, width, height)
      {buffer, age}
    end

    # Fences the drawn *buffer* and returns a new texture of it: a
    # `GdkDmabufTexture` when the buffer is exported and GDK takes it, else a
    # `GdkGLTexture`. The caller owns the texture. The context must be
    # current.
    def texture(buffer : Buffer) : Void*
      GL.epoxy_glBindFramebuffer.call(GL::FRAMEBUFFER, 0_u32)
      if @offload && (dmabuf = buffer.dmabuf)
        GL.epoxy_glFlush.call
        texture = dmabuf_texture(buffer, dmabuf)
        @dmabuf = !texture.null?
        return texture if @dmabuf
      end
      @dmabuf = false
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

    # Builds a `GdkDmabufTexture` of *buffer*'s export; on failure, logs
    # once, stops offloading and returns null. GDK relies on the implicit
    # synchronisation of the DMA-BUF, so the texture carries no fence.
    private def dmabuf_texture(buffer : Buffer, dmabuf : Dmabuf) : Void*
      builder = C.gdk_dmabuf_texture_builder_new
      C.gdk_dmabuf_texture_builder_set_display(builder, C.gdk_gl_context_get_display(@context))
      C.gdk_dmabuf_texture_builder_set_width(builder, buffer.width.to_u32)
      C.gdk_dmabuf_texture_builder_set_height(builder, buffer.height.to_u32)
      C.gdk_dmabuf_texture_builder_set_fourcc(builder, dmabuf.fourcc)
      C.gdk_dmabuf_texture_builder_set_modifier(builder, dmabuf.modifier)
      C.gdk_dmabuf_texture_builder_set_premultiplied(builder, 1)
      C.gdk_dmabuf_texture_builder_set_n_planes(builder, dmabuf.planes.to_u32)
      dmabuf.planes.times do |plane|
        C.gdk_dmabuf_texture_builder_set_fd(builder, plane.to_u32, dmabuf.fds[plane])
        C.gdk_dmabuf_texture_builder_set_stride(builder, plane.to_u32, dmabuf.strides[plane].to_u32)
        C.gdk_dmabuf_texture_builder_set_offset(builder, plane.to_u32, dmabuf.offsets[plane].to_u32)
      end
      error = Pointer(C::GError).null
      data = Handles.retain(buffer)
      texture = C.gdk_dmabuf_texture_builder_build(builder, RELEASED, data, pointerof(error))
      C.g_object_unref(builder)
      return texture unless texture.null?
      Handles.release(data)
      message = error.null? ? "unsupported format" : GLibError.take(error).message
      Log.warn { "canvas DMA-BUF offload off: #{message}" }
      @offload = false
      buffer.drop_dmabuf
      @buffers.each { |other| other.drop_dmabuf unless other.busy? }
      Pointer(Void).null
    end

    # Called, on any thread, when GTK drops *buffer*'s texture.
    def returned(buffer : Buffer) : Nil
      closed = @lock.synchronize do
        @returned << buffer unless @closed
        @closed
      end
      UIThread.dispatch { buffer.delete_later } if closed
    end

    # Deletes the free buffers and the renderbuffer and leaves the busy
    # buffers to be deleted once GTK drops them. The context must be
    # current.
    def release : Nil
      discard
      returned = @lock.synchronize do
        @closed = true
        @returned.dup.tap { @returned.clear }
      end
      returned.each(&.delete)
    end

    # Frees the buffers GTK returned, deleting those `#discard` orphaned.
    private def collect : Nil
      returned = @lock.synchronize { @returned.dup.tap { @returned.clear } }
      returned.each { |buffer| buffer.orphaned? ? buffer.delete : (buffer.busy = false) }
    end

    private def discard : Nil
      collect
      @buffers.each { |buffer| buffer.busy? ? buffer.orphaned = true : buffer.delete }
      @buffers.clear
      GL.epoxy_glDeleteRenderbuffers.call(1, pointerof(@depth)) unless @depth == 0
      @depth = 0_u32
    end

    private def resize(width : Int32, height : Int32) : Nil
      discard
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
