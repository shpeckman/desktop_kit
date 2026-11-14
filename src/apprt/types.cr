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

  # Direction on screen, relative to a split or a window.
  enum Direction
    Left
    Right
    Up
    Down
  end

  # Keyboard modifiers.
  @[Flags]
  enum Mods : UInt8
    Shift
    Ctrl
    Alt
    Super
  end
end
