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

    # Returns the key bindings.
    def bindings : Array(Binding)
      @bindings.dup
    end

    # Replaces the key bindings.
    #
    # Bindings to actions with the same detailed name share it as GTK
    # accelerators; triggers bound twice go to the first binding.
    def bindings=(bindings : Enumerable(Binding)) : Enumerable(Binding)
      @bindings = bindings.to_a
      UIThread.dispatch { apply_bindings } if running?
      bindings
    end

    # Sets the GTK accelerators of the local bindings, clearing those of the
    # previous set.
    private def apply_bindings : Nil
      return if @application.null?
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

    private def set_accels(name : String, accels : Array(String)) : Nil
      C.gtk_application_set_accels_for_action(@application, name, Native.strv(accels))
    end
  end
end
