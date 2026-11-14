# src/apprt/types.cr
module Apprt
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
