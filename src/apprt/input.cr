# src/apprt/input.cr
module Apprt
  # A key going down or up on a `Canvas`.
  struct KeyEvent
    # Whether the key went down; `false` when it went up.
    getter? pressed : Bool

    # Returns the GDK key value the layout and the modifiers make of the key,
    # such as `0x41` for Shift+A.
    getter keyval : UInt32

    # Returns the hardware code of the key.
    getter keycode : UInt32

    # Returns the modifiers held. A modifier key going down counts itself; one
    # going up does not.
    getter mods : Mods

    # Returns the modifiers the layout used up to make `#keyval`, such as Shift
    # for `A`.
    getter consumed_mods : Mods

    # Returns the text the key types: the input method's text, else the key's
    # character, even with Ctrl or Alt held; `nil` when the key goes up or
    # types nothing.
    getter text : String?

    # Returns the character the key makes in the current layout without
    # modifiers, or `nil` when it makes none.
    getter unshifted : Char?

    # Whether the key is a modifier key, such as Shift or Caps Lock.
    getter? modifier : Bool

    # Whether an input method was composing text when the key arrived.
    getter? composing : Bool

    # :nodoc:
    def initialize(@pressed : Bool, @keyval : UInt32, @keycode : UInt32, @mods : Mods, @consumed_mods : Mods,
                   @text : String?, @unshifted : Char?, @modifier : Bool, @composing : Bool)
    end
  end

  # Mouse button, by its GDK number; other buttons keep their number.
  enum MouseButton
    Left    = 1
    Middle  = 2
    Right   = 3
    Back    = 8
    Forward = 9
  end

  # A mouse button going down or up on a `Canvas`.
  struct MouseButtonEvent
    # Whether the button went down; `false` when it went up.
    getter? pressed : Bool

    getter button : MouseButton

    # Returns the pointer position in framebuffer pixels from the left edge.
    getter x : Float64

    # Returns the pointer position in framebuffer pixels from the top edge.
    getter y : Float64

    getter mods : Mods

    # :nodoc:
    def initialize(@pressed : Bool, @button : MouseButton, @x : Float64, @y : Float64, @mods : Mods)
    end
  end

  # The pointer moving over a `Canvas`.
  struct MouseMotionEvent
    # Returns the pointer position in framebuffer pixels from the left edge.
    getter x : Float64

    # Returns the pointer position in framebuffer pixels from the top edge.
    getter y : Float64

    getter mods : Mods

    # :nodoc:
    def initialize(@x : Float64, @y : Float64, @mods : Mods)
    end
  end

  # A scroll over a `Canvas`.
  struct ScrollEvent
    # Returns the horizontal distance, positive to the right: wheel steps, or
    # framebuffer pixels when `#precise?`.
    getter dx : Float64

    # Returns the vertical distance, positive downwards: wheel steps, or
    # framebuffer pixels when `#precise?`.
    getter dy : Float64

    # Whether the distances are in pixels, as from a touchpad.
    getter? precise : Bool

    getter mods : Mods

    # :nodoc:
    def initialize(@dx : Float64, @dy : Float64, @precise : Bool, @mods : Mods)
    end
  end
end
