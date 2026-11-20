# src/apprt/actions/trigger.cr
module Apprt
  # Key combination: a key and the modifiers held with it.
  #
  # ```
  # trigger = Apprt::Trigger.parse("ctrl+shift+t")
  # trigger.to_gtk_accel # => "<Shift><Control>t"
  # trigger.label        # => "Shift+Ctrl+T"
  # ```
  struct Trigger
    # GDK key value of the key, lower case.
    getter keyval : UInt32

    getter mods : Mods

    private MODIFIERS = {
      Mods::Shift => {"shift", "SHIFT"},
      Mods::Ctrl  => {"ctrl", "CTRL"},
      Mods::Alt   => {"alt", "ALT"},
      Mods::Super => {"super", "LOGO"},
    }

    private MODIFIER_NAMES = {
      "shift"   => Mods::Shift,
      "ctrl"    => Mods::Ctrl,
      "control" => Mods::Ctrl,
      "alt"     => Mods::Alt,
      "opt"     => Mods::Alt,
      "option"  => Mods::Alt,
      "super"   => Mods::Super,
      "cmd"     => Mods::Super,
      "command" => Mods::Super,
    }

    private KEY_NAMES = {
      "enter"       => "Return",
      "return"      => "Return",
      "esc"         => "Escape",
      "escape"      => "Escape",
      "tab"         => "Tab",
      "space"       => "space",
      "backspace"   => "BackSpace",
      "delete"      => "Delete",
      "del"         => "Delete",
      "insert"      => "Insert",
      "home"        => "Home",
      "end"         => "End",
      "page_up"     => "Page_Up",
      "pageup"      => "Page_Up",
      "page_down"   => "Page_Down",
      "pagedown"    => "Page_Down",
      "up"          => "Up",
      "down"        => "Down",
      "left"        => "Left",
      "right"       => "Right",
      "arrow_up"    => "Up",
      "arrow_down"  => "Down",
      "arrow_left"  => "Left",
      "arrow_right" => "Right",
    }

    private VOID_SYMBOL = 0xffffff_u32

    # Creates the trigger of the key *keyval* with *mods*; raises
    # `ArgumentError` when the combination cannot be a shortcut, such as a
    # modifier key alone.
    def initialize(keyval : UInt32, @mods : Mods = Mods::None)
      @keyval = C.gdk_keyval_to_lower(keyval)
      raise ArgumentError.new("invalid trigger: key value 0x#{keyval.to_s(16)} with #{mods}") unless accelerator?
    end

    # Returns the trigger of *keyval* with *mods*, or nil when the
    # combination cannot be a shortcut.
    protected def self.new?(keyval : UInt32, mods : Mods) : self?
      new(keyval, mods)
    rescue ArgumentError
    end

    # Parses *text*: modifiers and a key joined by `+`, such as
    # `"ctrl+shift+t"`; raises `ArgumentError` when *text* is not a trigger.
    #
    # Modifiers are `shift`, `ctrl` (`control`), `alt` (`opt`, `option`) and
    # `super` (`cmd`, `command`). The key is a single character, a name such as
    # `enter`, `page_up` or `f5`, or a GDK key name such as `KP_Enter`. Names
    # other than GDK key names ignore case; `ctrl++` binds the plus key.
    def self.parse(text : String) : self
      key, modifiers = split(text)
      mods = Mods::None
      modifiers.each do |name|
        mod = MODIFIER_NAMES[name.downcase]? || raise ArgumentError.new("invalid trigger #{text.inspect}: unknown modifier #{name.inspect}")
        raise ArgumentError.new("invalid trigger #{text.inspect}: duplicate modifier #{name.inspect}") if mods.includes?(mod)
        mods |= mod
      end
      keyval = keyval(key) || raise ArgumentError.new("invalid trigger #{text.inspect}: unknown key #{key.inspect}")
      begin
        new(keyval, mods)
      rescue ArgumentError
        raise ArgumentError.new("invalid trigger #{text.inspect}: not a shortcut")
      end
    end

    # Returns the GTK accelerator, such as `"<Control>t"`.
    def to_gtk_accel : String
      Native.take_string?(C.gtk_accelerator_name(@keyval, gdk_mods)).not_nil!
    end

    # Returns the shortcut in the XDG shortcuts format, such as `"CTRL+t"`.
    def to_xdg : String
      String.build do |io|
        each_mod { |_, xdg| io << xdg << '+' }
        io << key_name
      end
    end

    # Returns the label to show the user, such as `"Ctrl+T"`.
    def label : String
      Native.take_string?(C.gtk_accelerator_get_label(@keyval, gdk_mods)).not_nil!
    end

    # Writes the trigger in the format `.parse` reads, such as `"ctrl+t"`.
    def to_s(io : IO) : Nil
      each_mod { |name, _| io << name << '+' }
      io << key_name
    end

    def inspect(io : IO) : Nil
      io << "Trigger(" << self << ')'
    end

    # Splits *text* into the key and the modifier names; a final `+` after a
    # separator is the plus key.
    private def self.split(text : String) : {String, Array(String)}
      text = "#{text.rchop}plus" if text == "+" || text.ends_with?("++")
      modifiers, separator, key = text.rpartition('+')
      {key, separator.empty? ? [] of String : modifiers.split('+')}
    end

    private def self.keyval(key : String) : UInt32?
      keyval = if key.size == 1
                 C.gdk_unicode_to_keyval(key[0].ord.to_u32)
               elsif name = KEY_NAMES[key.downcase]?
                 C.gdk_keyval_from_name(name)
               elsif key =~ /\A[fF]([1-9]|1[0-9]|2[0-4])\z/
                 C.gdk_keyval_from_name("F#{$1}")
               else
                 C.gdk_keyval_from_name(key)
               end
      keyval unless keyval == 0 || keyval == VOID_SYMBOL
    end

    private def each_mod(& : String, String ->) : Nil
      MODIFIERS.each do |mod, (name, xdg)|
        yield name, xdg if @mods.includes?(mod)
      end
    end

    private def gdk_mods : C::GdkModifierType
      @mods.to_gdk
    end

    private def key_name : String
      Native.string?(C.gdk_keyval_name(@keyval)).not_nil!
    end

    # GTK accepts the trigger as an accelerator and parses its name back to
    # the same key.
    private def accelerator? : Bool
      # Round trip rejects keys without an accelerator name, such as emoji.
      return false if C.gtk_accelerator_valid(@keyval, gdk_mods) == 0
      name = Native.take_string?(C.gtk_accelerator_name(@keyval, gdk_mods))
      return false unless name
      C.gtk_accelerator_parse(name, out key, out _mods) != 0 && key == @keyval
    end
  end
end
