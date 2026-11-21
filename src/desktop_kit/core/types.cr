# src/desktop_kit/core/types.cr
module DesktopKit
  # Color scheme in effect: light or dark.
  enum ColorScheme
    Light
    Dark
  end

  # Requested appearance: follow the desktop, or force light or dark.
  enum Appearance
    System
    Light
    Dark
  end

  # Window decorations: the desktop's choice, drawn by the application
  # (client), drawn by the compositor (server) or none.
  #
  # Server decorations need a compositor with KDE's server decoration
  # protocol; elsewhere `Server` falls back to `Client`.
  enum Decoration
    Auto
    Client
    Server
    None
  end

  # Direction on screen, relative to a split or a window.
  enum Direction
    Left
    Right
    Up
    Down
  end

  # A rectangle in fractions of an area, from its top-left corner.
  struct Bounds
    # Slack for edges computed in floating point. Bounds is a plain struct,
    # not a `record`: `crystal docs` fails on private members in a
    # `record` body.
    private EPSILON = 1e-9

    getter x : Float64
    getter y : Float64
    getter width : Float64
    getter height : Float64

    def initialize(@x : Float64, @y : Float64, @width : Float64, @height : Float64)
    end

    # Returns the bounds shifted by *dx* and *dy*, then kept inside the area.
    def moved(dx : Float64, dy : Float64) : Bounds
      Bounds.new(x + dx, y + dy, width, height).clamped
    end

    # Returns the bounds grown by *dw* and *dh*, or shrunk by negative
    # amounts, with the top-left corner kept: at least *min_width* by
    # *min_height*, and at most up to the right and bottom edges.
    def resized(dw : Float64, dh : Float64, min_width : Float64, min_height : Float64) : Bounds
      Bounds.new(x, y,
        Math.max(Math.min(width + dw, 1.0 - x), min_width),
        Math.max(Math.min(height + dh, 1.0 - y), min_height)).clamped
    end

    # Returns the bounds made to fit the area: no wider or taller than it,
    # moved inside it.
    def clamped : Bounds
      width = Math.min(self.width, 1.0)
      height = Math.min(self.height, 1.0)
      Bounds.new(fit(x, width), fit(y, height), width, height)
    end

    # Keeps *start* unless the span of *size* from it leaves the area: a
    # span ending on the edge by rounding stays put.
    private def fit(start : Float64, size : Float64) : Float64
      return 0.0 if start < 0.0
      start + size > 1.0 + EPSILON ? 1.0 - size : start
    end

    # Returns the middle point.
    def center : {Float64, Float64}
      {x + width / 2, y + height / 2}
    end

    # Returns whether the bounds are finite, not empty and inside the area.
    def valid? : Bool
      {x, y, width, height}.all?(&.finite?) && x >= 0 && y >= 0 && width > 0 && height > 0 &&
        x + width <= 1.0 + EPSILON && y + height <= 1.0 + EPSILON
    end
  end

  # Module-level, not inside `Mods`: enum bodies can't hold constants.
  private MODS_GDK = {
    Mods::Shift => C::GdkModifierType::ShiftMask,
    Mods::Ctrl  => C::GdkModifierType::ControlMask,
    Mods::Alt   => C::GdkModifierType::AltMask,
    Mods::Super => C::GdkModifierType::SuperMask,
  }

  # Keyboard modifiers.
  @[Flags]
  enum Mods : UInt8
    Shift
    Ctrl
    Alt
    Super

    # :nodoc:
    def self.from_gdk(state : C::GdkModifierType) : self
      MODS_GDK.reduce(None) { |mods, (mod, mask)| state.includes?(mask) ? mods | mod : mods }
    end

    # :nodoc:
    def to_gdk : C::GdkModifierType
      MODS_GDK.reduce(C::GdkModifierType::None) { |state, (mod, mask)| includes?(mod) ? state | mask : state }
    end
  end
end
