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
end
