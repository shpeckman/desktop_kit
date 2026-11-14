# src/apprt/binding.cr
module Apprt
  # Key binding: a trigger, or a sequence of triggers pressed one after
  # another, that performs an action.
  #
  # ```
  # app.bindings = [
  #   Apprt::Binding.new("ctrl+shift+t", Apprt::Action::NewTab.new),
  #   Apprt::Binding.new("ctrl+shift+e", Apprt::Action::NewSplit.new(:right)),
  #   Apprt::Binding.new("ctrl+a>n", Apprt::Action::GotoTab.new(-1)),
  # ]
  # ```
  struct Binding
    # Returns the triggers in the order they are pressed; one for a plain
    # binding.
    getter triggers : Array(Trigger)

    getter action : Action

    # Whether the binding works while the application is not focused.
    getter? global : Bool

    # Creates the binding of *trigger* to *action*. A string holds one
    # trigger in the `Trigger.parse` grammar, or several joined by `>` for a
    # sequence, such as `"ctrl+a>n"`.
    #
    # Raises `ArgumentError` when a trigger does not parse, or when a global
    # binding is a sequence: the desktop binds single triggers only.
    def initialize(trigger : Trigger | String, @action : Action, *, @global : Bool = false)
      @triggers = trigger.is_a?(String) ? Binding.parse(trigger) : [trigger]
      raise ArgumentError.new("global binding #{self}: sequences cannot be global") if @global && sequence?
    end

    # :ditto:
    def initialize(@triggers : Array(Trigger), @action : Action, *, @global : Bool = false)
      raise ArgumentError.new("empty binding") if @triggers.empty?
      raise ArgumentError.new("global binding #{self}: sequences cannot be global") if @global && sequence?
    end

    # Returns the first trigger.
    def trigger : Trigger
      @triggers.first
    end

    # Whether the binding takes several triggers.
    def sequence? : Bool
      @triggers.size > 1
    end

    # Returns the labels of the triggers, such as `"Ctrl+A N"`.
    def label : String
      @triggers.join(' ', &.label)
    end

    # Writes the triggers in the `.new` grammar.
    def to_s(io : IO) : Nil
      @triggers.join(io, '>')
    end

    # Splits *text* at each `>` that follows a key, so `"ctrl+>"` and
    # `"a>>"` keep `>` as a key.
    protected def self.parse(text : String) : Array(Trigger)
      triggers = [] of Trigger
      start = 0
      text.each_char_with_index do |char, index|
        next unless char == '>' && index > start && text[index - 1] != '+'
        triggers << Trigger.parse(text[start...index])
        start = index + 1
      end
      triggers << Trigger.parse(text[start..])
    end
  end

  # The sequences of a set of bindings, and optionally its single
  # triggers, matched one key at a time.
  private class Keymap
    EMPTY = new([] of Binding, singles: false)

    @actions = {} of Array(Trigger) => Action
    @prefixes = Set(Array(Trigger)).new

    def initialize(bindings : Enumerable(Binding), *, singles : Bool)
      bindings.each do |binding|
        (1...binding.triggers.size).each { |size| @prefixes << binding.triggers[0, size] }
      end
      bindings.each do |binding|
        next unless singles || binding.sequence?
        if prefix?(binding.triggers)
          Log.warn { "binding #{binding}: a sequence starts with it" }
          next
        end
        @actions[binding.triggers] = binding.action unless @actions.has_key?(binding.triggers)
      end
    end

    # Returns the action *keys* complete, `true` when a sequence starts
    # with them, or nil.
    def match(keys : Array(Trigger)) : Action | Bool | Nil
      @actions[keys]? || (true if prefix?(keys))
    end

    def prefix?(keys : Array(Trigger)) : Bool
      @prefixes.includes?(keys)
    end

    def empty? : Bool
      @actions.empty?
    end
  end

  abstract class App
    @bindings = [] of Binding
    @accelerated = [] of String
    @binding_keymap : Keymap = Keymap::EMPTY
    @key_tables = {} of String => Array(Binding)
    @key_table_maps = {} of String => Keymap
    @global_shortcuts : GlobalShortcuts?

    # Returns the key bindings.
    def bindings : Array(Binding)
      @bindings.dup
    end

    # Replaces the key bindings.
    #
    # Bindings to actions with the same detailed name share it as GTK
    # accelerators; triggers bound twice go to the first binding. A
    # sequence waits for its next trigger after each one; any other key
    # ends it, and a single trigger that starts a sequence is ignored. Global
    # bindings are registered with the desktop's global shortcuts portal,
    # which may ask the user to confirm them; `#on_binding_failed` reports
    # those it does not bind.
    def bindings=(bindings : Enumerable(Binding)) : Enumerable(Binding)
      @bindings = bindings.to_a
      UIThread.dispatch { apply_bindings } if running?
      bindings
    end

    # Returns the key tables by name.
    def key_tables : Hash(String, Array(Binding))
      @key_tables.transform_values(&.dup)
    end

    # Replaces the key tables: named sets of bindings that
    # `Action::ActivateKeyTable` lays over a window's bindings until
    # `Action::DeactivateKeyTable`.
    #
    # The innermost active table matches a key first, then the next one
    # and finally the bindings; keys none of them match pass through.
    # Raises `ArgumentError` for a global binding.
    def key_tables=(tables : Hash(String, Array(Binding))) : Hash(String, Array(Binding))
      tables.each do |name, bindings|
        bindings.each do |binding|
          raise ArgumentError.new("key table #{name}: binding #{binding} cannot be global") if binding.global?
        end
      end
      @key_tables = tables.transform_values(&.dup)
      UIThread.dispatch { apply_key_tables } if running?
      tables
    end

    # :showdoc:
    #
    # Called when the desktop does not bind the global *binding*; *message*
    # says why. Logs a warning by default.
    protected def on_binding_failed(binding : Binding, message : String) : Nil
      Log.warn { "global binding #{binding.trigger}: #{message}" }
    end

    # Matches *keys* against the active *tables*, innermost (last) first,
    # then against the sequences: returns the completed action with the
    # name of its table (nil for the bindings), `true` when a sequence
    # starts with *keys*, or nil.
    protected def key_match(tables : Array({String, Bool}), keys : Array(Trigger)) : {Action, String?} | Bool | Nil
      tables.reverse_each do |(name, _)|
        case match = @key_table_maps[name]?.try(&.match(keys))
        when Action then return {match, name}
        when true   then return true
        end
      end
      case match = @binding_keymap.match(keys)
      when Action then {match, nil}
      else             match
      end
    end

    protected def sequences? : Bool
      !@binding_keymap.empty?
    end

    protected def key_table?(name : String) : Bool
      @key_table_maps.has_key?(name)
    end

    # Performs *action* on the target of its scope in *window*: the window,
    # its selected tab or that tab's active surface; app actions go to the
    # application. Returns whether an overload handled it.
    protected def perform_in(window : Window?, action : Action) : Bool
      target = case action.scope
               in .app?    then self
               in .window? then window
               in .tab?    then window.try(&.active_tab)
               in .split?  then window.try(&.active_surface)
               end
      !target.nil? && perform(target, action)
    end

    # Sets the GTK accelerators of the local bindings, clearing those of the
    # previous set, collects the sequences and registers the global
    # bindings.
    private def apply_bindings : Nil
      return if @application.null?
      @global_shortcuts.try(&.bind(@bindings))
      @accelerated.each { |name| set_accels(name, [] of String) }
      @binding_keymap = Keymap.new(@bindings.reject(&.global?), singles: false)
      seen = Set(Trigger).new
      accels = {} of String => Array(String)
      @bindings.each do |binding|
        next if binding.global? || binding.sequence? || !seen.add?(binding.trigger)
        if @binding_keymap.prefix?(binding.triggers)
          Log.warn { "binding #{binding}: a sequence starts with it" }
          next
        end
        (accels[binding.action.detailed_name] ||= [] of String) << binding.trigger.to_gtk_accel
      end
      accels.each { |name, list| set_accels(name, list) }
      @accelerated = accels.keys
    end

    private def apply_key_tables : Nil
      @key_table_maps = @key_tables.transform_values { |bindings| Keymap.new(bindings, singles: true) }
    end

    private def start_global_shortcuts : Nil
      connection = C.g_application_get_dbus_connection(@application)
      return if connection.null?
      @global_shortcuts = GlobalShortcuts.new(connection,
        ->(binding : Binding) { perform_global(binding.action) },
        ->(binding : Binding, message : String) { on_binding_failed(binding, message) })
    end

    # Performs *action* of an activated global binding on the focused
    # target of its scope.
    private def perform_global(action : Action) : Nil
      Log.warn { "global binding: action #{action.detailed_name} not handled" } unless perform_in(active_window, action)
    end

    private def set_accels(name : String, accels : Array(String)) : Nil
      C.gtk_application_set_accels_for_action(@application, name, Native.strv(accels))
    end
  end
end
