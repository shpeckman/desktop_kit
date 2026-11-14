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

  abstract class App
    @bindings = [] of Binding
    @accelerated = [] of String
    @sequences = {} of Array(Trigger) => Action
    @sequence_prefixes = Set(Array(Trigger)).new
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

    # :showdoc:
    #
    # Called when the desktop does not bind the global *binding*; *message*
    # says why. Logs a warning by default.
    protected def on_binding_failed(binding : Binding, message : String) : Nil
      Log.warn { "global binding #{binding.trigger}: #{message}" }
    end

    # Whether a sequence starts with *keys* (`true`), or the action of the
    # sequence *keys* completes; nil when no sequence matches.
    protected def sequence_match(keys : Array(Trigger)) : Action | Bool | Nil
      @sequences[keys]? || (true if @sequence_prefixes.includes?(keys))
    end

    protected def sequences? : Bool
      !@sequences.empty?
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
      @sequences.clear
      @sequence_prefixes.clear
      @bindings.each do |binding|
        next unless binding.sequence?
        @sequences[binding.triggers] = binding.action unless @sequences.has_key?(binding.triggers)
        (1...binding.triggers.size).each { |size| @sequence_prefixes << binding.triggers[0, size] }
      end
      seen = Set(Trigger).new
      accels = {} of String => Array(String)
      @bindings.each do |binding|
        next if binding.global? || binding.sequence? || !seen.add?(binding.trigger)
        if @sequence_prefixes.includes?(binding.triggers)
          Log.warn { "binding #{binding}: a sequence starts with it" }
          next
        end
        (accels[binding.action.detailed_name] ||= [] of String) << binding.trigger.to_gtk_accel
      end
      accels.each { |name, list| set_accels(name, list) }
      @accelerated = accels.keys
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
