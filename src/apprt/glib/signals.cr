# src/apprt/glib/signals.cr
module Apprt
  # :nodoc:
  # Connects GObject signals to Crystal procs.
  #
  # The handler is a proc literal with typed parameters: the signal's
  # arguments after the instance, in order (`->(page : Void*) : Bool { ... }`).
  # The macro writes a C trampoline that converts each argument by its
  # restriction, calls the proc and converts the result. Exceptions are logged
  # to `Apprt::Log` and the signal gets a zero result. The proc lives in
  # `Handles` until GObject drops the handler.
  #
  # Arguments: `Bool`, `String`, `String?`, `Int32`, `UInt32`, `Int64`,
  # `UInt64`, `Float32`, `Float64`, `Void*`, enums (from a C int), `Widget`,
  # `Widget?` and `Wrapper` subclasses (borrowed, so `from_raw`), nilable or
  # not. Results: `Nil`, `Bool` and `Int32`.
  module Signals
    # Connects *handler* to *signal* of *instance* (a `Widget`, a `Wrapper` or a
    # `Void*`) and returns the handler id.
    macro connect(instance, signal, handler)
      {%
        raws = [] of ASTNode
        values = [] of ASTNode
        types = [] of ASTNode
        handler.args.each_with_index do |arg, index|
          raise "Signals.connect: parameter #{arg.name} needs a type restriction" if arg.restriction.is_a?(Nop)
          type = arg.restriction.resolve
          types << type
          nilable = type.nilable? && type != Nil
          base = nilable ? type.union_types.reject { |member| member == Nil }.first : type
          raw = "__raw#{index}".id
          if base == Bool
            raws << "#{raw} : Int32".id
            values << "#{raw} != 0".id
          elsif base == String
            raws << "#{raw} : UInt8*".id
            values << (nilable ? "(String.new(#{raw}) unless #{raw}.null?)" : "String.new(#{raw})").id
          elsif [Int32, UInt32, Int64, UInt64, Float32, Float64, Pointer(Void)].includes?(base)
            raws << "#{raw} : #{base}".id
            values << raw
          elsif base < ::Enum
            raws << "#{raw} : Int32".id
            values << "#{base}.from_value(#{raw})".id
          elsif base == ::Apprt::Widget
            raws << "#{raw} : Void*".id
            values << (nilable ? "::Apprt::Widget.new?(#{raw})" : "::Apprt::Widget.new(#{raw})").id
          elsif base < ::Apprt::Wrapper
            raws << "#{raw} : Void*".id
            values << (nilable ? "#{base}.from_raw?(#{raw})" : "#{base}.from_raw(#{raw})").id
          else
            raise "Signals.connect: unsupported parameter type #{type}"
          end
        end
        result = handler.return_type.is_a?(Nop) ? Nil : handler.return_type.resolve
        raise "Signals.connect: unsupported result type #{result}" unless [Nil, Bool, Int32].includes?(result)
        where = signal.is_a?(StringLiteral) ? "#{signal.id} handler" : "signal handler"
      %}
      %handler = ->({{ handler.args.splat }}) : {{ result }} { {{ handler.body }} }
      %trampoline = ->(__instance : Void*, {% for raw in raws %}{{ raw }}, {% end %}__data : Void*) {
        begin
          %value = ::Apprt::Handles.get(__data, Proc({% for type in types %}{{ type }}, {% end %}{{ result }})).call({{ values.splat }})
          {% if result == Bool %}
            %value ? 1 : 0
          {% elsif result == Int32 %}
            %value
          {% else %}
            nil
          {% end %}
        rescue %ex
          ::Apprt::Log.error(exception: %ex) { {{ where }} }
          {% if result == Nil %} nil {% else %} 0 {% end %}
        end
      }
      ::Apprt::Signals.connect_raw({{ instance }}, {{ signal }}, %trampoline.pointer, ::Apprt::Handles.retain(%handler))
    end

    # Connects *handler*, a proc literal without parameters, to the change
    # notification of *property* of *instance* and returns the handler id.
    macro notify(instance, property, handler)
      ::Apprt::Signals.connect({{ instance }}, {{ "notify::" + property }}, ->(__pspec : Void*) { {{ handler.body }} })
    end

    def self.connect_raw(instance, signal : String, trampoline : Void*, data : Void*) : UInt64
      callback = C::GCallback.new(trampoline, Pointer(Void).null)
      C.g_signal_connect_data(instance, signal, callback, data, Handles::RELEASE_CLOSURE, C::GConnectFlags::None).to_u64
    end

    def self.disconnect(instance, handler : UInt64) : Nil
      C.g_signal_handler_disconnect(instance, handler)
    end

    def self.connected?(instance, handler : UInt64) : Bool
      C.g_signal_handler_is_connected(instance, handler) != 0
    end

    # Blocks *handler* for the duration of the block.
    def self.blocked(instance, handler : UInt64, &)
      C.g_signal_handler_block(instance, handler)
      begin
        yield
      ensure
        C.g_signal_handler_unblock(instance, handler)
      end
    end
  end
end
