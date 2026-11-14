# src/apprt/winproto.cr
module Apprt
  # :nodoc:
  # The Wayland extras of one realized window, after the `Window` of
  # Ghostty's src/apprt/gtk/winproto/wayland.zig: KDE server decorations,
  # background blur (`ext_background_effect_v1`) and urgency through
  # `xdg_activation_v1`. `.attach` returns nil off Wayland. Use it on the
  # GTK thread only.
  class Winproto
    # Modes of `org_kde_kwin_server_decoration_manager`.
    enum Mode : UInt32
      None
      Client
      Server
    end

    # One rectangle of a blur region, in surface coordinates.
    record Slice, x : Int32, y : Int32, width : Int32, height : Int32

    # Radius of the rounded corners of a floating client-side decorated
    # window, which the blur region follows.
    CORNER_RADIUS = 15

    # From this GTK version on, GTK binds `ext_background_effect_v1` for its
    # own surfaces, and a second object for the same surface is a protocol
    # error.
    GTK_BACKGROUND_EFFECT = {4, 23, 3}

    # Toplevel states without rounded corners.
    private SQUARE_STATES = C::GdkToplevelState::Fullscreen | C::GdkToplevelState::Maximized | C::GdkToplevelState::Tiled

    @decoration : Wayland::Proxy?
    @effect : Wayland::Proxy?
    @token : Wayland::Proxy?
    @slices : Array(Slice)?

    # Returns the extras of the realized *window*, or nil when it is not on
    # Wayland.
    def self.attach(window : Widget) : Winproto?
      native = window.native || return
      surface = C.gtk_native_get_surface(native)
      return if surface.null?
      globals = Wayland.globals(window.display) || return
      wl_surface = Wayland.surface(surface) || return
      new(globals, native, surface, wl_surface)
    end

    def initialize(@globals : Wayland::Globals, @native : Widget, @surface : Void*, @wl_surface : Void*)
      @decoration = @globals.decoration.try(&.create(Wayland::DECORATION_MANAGER_CREATE, :decoration,
        Wayland::NEW_ID, @wl_surface))
      unless gtk_background_effect?
        @effect = @globals.background_effect.try(&.create(Wayland::EFFECT_MANAGER_GET, :background_effect,
          Wayland::NEW_ID, @wl_surface))
      end
    end

    # The server decoration mode *decoration* asks for.
    def mode(decoration : Decoration) : Mode
      case decoration
      in .auto?   then @globals.default_mode.try { |mode| Mode.from_value?(mode) } || Mode::Client
      in .client? then Mode::Client
      in .server? then Mode::Server
      in .none?   then Mode::None
      end
    end

    # Whether GTK draws the decorations for *decoration*: server
    # decorations fall back to the client without the KDE protocol.
    def client_side?(decoration : Decoration) : Bool
      case mode(decoration)
      in .client? then true
      in .server? then @globals.decoration.nil?
      in .none?   then false
      end
    end

    def sync_decoration(decoration : Decoration) : Nil
      @decoration.try(&.request(Wayland::DECORATION_REQUEST_MODE, mode(decoration).value))
    end

    # Sets the blur region behind the window, or clears it unless
    # *enabled*; *csd* tells whether GTK draws the decorations.
    def sync_blur(enabled : Bool, csd : Bool) : Nil
      effect = @effect || return
      return unless @globals.blur?
      unless enabled
        effect.request(Wayland::EFFECT_SET_BLUR_REGION, nil) if @slices
        @slices = nil
        return
      end
      slices = blur_region(csd)
      return if slices == @slices
      region = Wayland::Proxy.new(Wayland.request(@globals.compositor, Wayland::COMPOSITOR_CREATE_REGION,
        {Wayland::NEW_ID}, created: :region), :region)
      slices.each { |slice| region.request(Wayland::REGION_ADD, slice.x, slice.y, slice.width, slice.height) }
      effect.request(Wayland::EFFECT_SET_BLUR_REGION, region)
      region.destroy(Wayland::REGION_DESTROY)
      @slices = slices
    end

    # Asks the compositor for the user's attention through an activation
    # token, or withdraws a pending request.
    def urgent=(urgent : Bool) : Bool
      @token.try(&.destroy(Wayland::TOKEN_DESTROY))
      @token = nil
      activation = @globals.activation
      return urgent unless urgent && activation
      token = activation.create(Wayland::ACTIVATION_GET_TOKEN, :activation_token, Wayland::NEW_ID)
      token.request(Wayland::TOKEN_SET_SURFACE, @wl_surface)
      token.listen do |opcode, args|
        next unless opcode == Wayland::TOKEN_DONE
        activation.request(Wayland::ACTIVATION_ACTIVATE, String.new(args[0].s), @wl_surface)
        token.destroy(Wayland::TOKEN_DESTROY)
        @token = nil if @token.same?(token)
      end
      token.request(Wayland::TOKEN_COMMIT)
      @token = token
      urgent
    end

    # Destroys the protocol objects before the surface goes away.
    def release : Nil
      @token.try(&.destroy(Wayland::TOKEN_DESTROY))
      @effect.try(&.destroy(Wayland::EFFECT_DESTROY))
      @decoration.try(&.destroy(Wayland::DECORATION_RELEASE))
      @token = @effect = @decoration = nil
    end

    # The window's blur region: the surface minus GTK's shadow (and the
    # 1 px CSD border), with rounded corners while floating.
    private def blur_region(csd : Bool) : Array(Slice)
      x = y = 0.0
      C.gtk_native_get_surface_transform(@native, pointerof(x), pointerof(y))
      offset_x = x.to_i + (csd ? 1 : 0)
      offset_y = y.to_i + (csd ? 1 : 0)
      width = C.gdk_surface_get_width(@surface) - 2 * offset_x
      height = C.gdk_surface_get_height(@surface) - 2 * offset_y
      return [] of Slice if width <= 0 || height <= 0
      state = C.gdk_toplevel_get_state(@surface)
      rounded = csd && (state & SQUARE_STATES).none?
      Winproto.slices(offset_x, offset_y, width, height, rounded ? CORNER_RADIUS : 0)
    end

    # Approximates a rectangle with corners of *radius* by a middle
    # rectangle and one-pixel rows above and below it.
    def self.slices(x : Int32, y : Int32, width : Int32, height : Int32, radius : Int32) : Array(Slice)
      slices = [Slice.new(x, y + radius, width, height - 2 * radius)]
      r = radius.to_f32
      radius.times do |row|
        dy = (radius - row).to_f32 - 0.5_f32
        dx = Math.sqrt(r * r - dy * dy)
        row_x = (r - (dx + 0.5_f32).round(:ties_away)).to_i
        row_width = width - 2 * row_x
        slices << Slice.new(x + row_x, y + row, row_width, 1)
        slices << Slice.new(x + row_x, y + height - 1 - row, row_width, 1)
      end
      slices
    end

    private def gtk_background_effect? : Bool
      version = {C.gtk_get_major_version.to_i, C.gtk_get_minor_version.to_i, C.gtk_get_micro_version.to_i}
      (version <=> GTK_BACKGROUND_EFFECT) >= 0
    end
  end
end
