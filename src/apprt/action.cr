# src/apprt/action.cr
module Apprt
  # Declares an action type: an immutable struct named *name* with one getter
  # per *payload* field, registered as the GAction *gname*.
  #
  # *scope* says where the action lives: `:app` (the application), `:window`,
  # `:tab` or `:split` (the focused split of a tab). *ipc* lets other
  # processes send an `:app` action with `IPC.send`. A block adds
  # definitions to the struct, such as the enums its payload uses.
  #
  # ```
  # Apprt.action Refresh, "refresh", payload: {force: Bool}
  #
  # class Viewer < Apprt::App
  #   protected def perform(target : Apprt::App, action : Refresh) : Bool
  #     reload_documents(force: action.force)
  #     true
  #   end
  # end
  # ```
  #
  # Payload fields take types `Variant` can carry; the GAction parameter is the
  # single field's type, or a tuple of all fields. Names must be unique per
  # scope and are checked at compile time.
  macro action(name, gname, *, scope = :app, payload = nil, ipc = false, &block)
    {% fields = payload || {} of Nil => Nil %}
    {% raise "Apprt.action #{name}: name must be a string literal of letters, digits, '-' and '.'" unless gname.is_a?(StringLiteral) && gname =~ /\A[A-Za-z0-9][A-Za-z0-9.\-]*\z/ %}
    {% raise "Apprt.action #{name}: scope must be :app, :window, :tab or :split" unless %w(app window tab split).includes?(scope.id.stringify) %}
    {% raise "Apprt.action #{name}: only :app actions can allow ipc" if ipc && scope.id.stringify != "app" %}
    {% for key in fields.keys %}
      {% raise "Apprt.action #{name}: payload field #{key} clashes with an Action method" if %w(name scope detailed_name to_variant ipc?).includes?(key.id.stringify) %}
    {% end %}
    struct {{ name.id }} < ::Apprt::Action
      # :nodoc:
      NAME = {{ gname }}
      # :nodoc:
      SCOPE = ::Apprt::Action::Scope::{{ scope.id.camelcase }}
      # :nodoc:
      IPC = {{ ipc }}

      {% for key, type in fields %}
        getter {{ key.id }} : {{ type }}
      {% end %}

      {% unless fields.empty? %}
        def initialize({% for key, type in fields %}@{{ key.id }} : {{ type }}, {% end %})
        end
      {% end %}

      def name : String
        NAME
      end

      def scope : ::Apprt::Action::Scope
        SCOPE
      end

      # :nodoc:
      def ipc? : Bool
        IPC
      end

      # :nodoc:
      def to_variant : ::Apprt::Variant?
        {% if fields.empty? %}
          nil
        {% elsif fields.size == 1 %}
          ::Apprt::Variant.new(@{{ fields.keys.first.id }})
        {% else %}
          ::Apprt::Variant.new({ {% for key in fields.keys %}@{{ key.id }}, {% end %} })
        {% end %}
      end

      # :nodoc:
      def self.parameter_type : String?
        {% if fields.empty? %}
          nil
        {% elsif fields.size == 1 %}
          ::Apprt::Variant.signature({{ fields.values.first }})
        {% else %}
          ::Apprt::Variant.signature(::Tuple({{ fields.values.splat }}))
        {% end %}
      end

      # :nodoc:
      # Returns nil when *variant* does not carry this action's payload.
      def self.from_variant(variant : ::Apprt::Variant?) : self?
        {% if fields.empty? %}
          new if variant.nil?
        {% elsif fields.size == 1 %}
          new(variant.get({{ fields.values.first }})) if variant && variant.is?({{ fields.values.first }})
        {% else %}
          new(*variant.get(::Tuple({{ fields.values.splat }}))) if variant && variant.is?(::Tuple({{ fields.values.splat }}))
        {% end %}
      rescue ArgumentError
        nil
      end

      {{ block.body if block }}
    end
  end

  # Base of all actions; declare action types with `Apprt.action`.
  #
  # The built-in actions are nested in this type; `App#perform` carries them
  # out.
  abstract struct Action
    # Where an action lives and which part of the application it acts on.
    enum Scope
      App
      Window
      Tab
      Split

      # Returns the GAction group prefix, such as `"win"`.
      def prefix : String
        case self
        in .app?    then "app"
        in .window? then "win"
        in .tab?    then "tab"
        in .split?  then "split"
        end
      end
    end

    # :nodoc:
    def initialize
    end

    # :nodoc:
    record Info, name : String, scope : Scope, parameter_type : String?, decode : Proc(Variant?, Action?)

    # Returns the action name, such as `"new-split"`.
    abstract def name : String

    abstract def scope : Scope

    # :nodoc:
    abstract def ipc? : Bool

    # :nodoc:
    abstract def to_variant : Variant?

    # Returns the detailed GAction name, such as `"split.new-split::right"`,
    # for accelerators, menus and buttons.
    def detailed_name : String
      Native.take_string?(C.g_action_print_detailed_name("#{scope.prefix}.#{name}", to_variant.try(&.to_unsafe) || Pointer(Void).null)).not_nil!
    end

    @@registry : Array(Info)?

    # :nodoc:
    # Every declared action type, built at compile time from the subclasses.
    def self.registry : Array(Info)
      @@registry ||= begin
        {% begin %}
          {% seen = {} of String => Bool %}
          {% for type in Action.all_subclasses.reject(&.abstract?) %}
            {% scope = type.constant("SCOPE").names.last.stringify.underscore %}
            {% key = "#{scope.id}.#{type.constant("NAME").id}" %}
            {% raise "Apprt.action #{type}: action #{type.constant("NAME")} is declared twice in scope :#{scope.id}" if seen[key] %}
            {% seen[key] = true %}
          {% end %}
          [
            {% for type in Action.all_subclasses.reject(&.abstract?) %}
              Info.new(::{{ type }}::NAME, ::{{ type }}::SCOPE, ::{{ type }}.parameter_type, ->(variant : Variant?) { ::{{ type }}.from_variant(variant).as(Action?) }),
            {% end %}
          ] of Info
        {% end %}
      end
    end

    # :nodoc:
    # Adds a GAction to *map* for each action of *scope*; *perform* receives
    # the decoded actions and returns whether it handled them.
    def self.install(map : Void*, scope : Scope, &perform : Action -> Bool) : Nil
      registry.each do |info|
        next unless info.scope == scope
        install(map, info, perform)
      end
    end

    private def self.install(map : Void*, info : Info, perform : Action -> Bool) : Nil
      parameter_type = info.parameter_type.try { |type| C.g_variant_type_new(type) } || Pointer(Void).null
      gaction = C.g_simple_action_new(info.name, parameter_type)
      C.g_variant_type_free(parameter_type) unless parameter_type.null?
      Signals.connect(gaction, "activate", ->(parameter : Void*) { activate(info, parameter, perform) })
      C.g_action_map_add_action(map, gaction)
      C.g_object_unref(gaction)
    end

    private def self.activate(info : Info, parameter : Void*, perform : Action -> Bool) : Nil
      variant = Variant.from_raw?(parameter)
      if action = info.decode.call(variant)
        Log.warn { "action #{action.detailed_name} not handled" } unless perform.call(action)
      else
        Log.warn { "action #{info.scope.prefix}.#{info.name}: invalid parameter #{variant.inspect}" }
      end
    end
  end
end
