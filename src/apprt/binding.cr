# src/apprt/binding.cr
module Apprt
  # Key binding: a trigger that performs an action.
  #
  # ```
  # app.bindings = [
  #   Apprt::Binding.new("ctrl+shift+t", Apprt::Action::NewTab.new),
  #   Apprt::Binding.new("ctrl+shift+e", Apprt::Action::NewSplit.new(:right)),
  # ]
  # ```
  struct Binding
    getter trigger : Trigger

    getter action : Action

    # Whether the binding works while the application is not focused.
    getter? global : Bool

    # Creates the binding of *trigger* to *action*; raises `ArgumentError` when
    # *trigger* is a string that `Trigger.parse` rejects.
    def initialize(trigger : Trigger | String, @action : Action, *, @global : Bool = false)
      @trigger = trigger.is_a?(String) ? Trigger.parse(trigger) : trigger
    end
  end

  abstract class App
    @bindings = [] of Binding
    @accelerated = [] of String
    @global_shortcuts : GlobalShortcuts?

    # Returns the key bindings.
    def bindings : Array(Binding)
      @bindings.dup
    end

    # Replaces the key bindings.
    #
    # Bindings to actions with the same detailed name share it as GTK
    # accelerators; triggers bound twice go to the first binding. Global
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

    # Sets the GTK accelerators of the local bindings, clearing those of the
    # previous set, and registers the global bindings.
    private def apply_bindings : Nil
      return if @application.null?
      @global_shortcuts.try(&.bind(@bindings))
      @accelerated.each { |name| set_accels(name, [] of String) }
      seen = Set(Trigger).new
      accels = {} of String => Array(String)
      @bindings.each do |binding|
        next if binding.global? || !seen.add?(binding.trigger)
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
      window = active_window
      target = case action.scope
               in .app?    then self
               in .window? then window
               in .tab?    then window.try(&.active_tab)
               in .split?  then window.try(&.active_surface)
               end
      Log.warn { "global binding: action #{action.detailed_name} not handled" } unless target && perform(target, action)
    end

    private def set_accels(name : String, accels : Array(String)) : Nil
      C.gtk_application_set_accels_for_action(@application, name, Native.strv(accels))
    end
  end
end
