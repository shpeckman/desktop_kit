# src/apprt/desktop/dbus.cr
module Apprt
  # A connection to a D-Bus message bus: method calls, signals and
  # subscriptions with `Variant` arguments.
  #
  # `.session` and `.system` return the process's shared connections;
  # `App#dbus` returns the running application's. Asynchronous calls and
  # subscriptions answer on the thread that made them, through its main
  # loop: use them on the GTK thread. `#call_sync` and `#emit` work on any
  # thread.
  #
  # ```
  # bus = app.dbus || Apprt::DBus.session
  # bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames") do |reply, error|
  #   puts reply.try(&.[0].get(Array(String))) || error
  # end
  # ```
  class DBus < Wrapper
    # A signal a subscription received.
    record Signal, sender : String, path : String, interface : String, member : String, args : Variant

    # A subscription to signals from `#subscribe`; it lasts until `#cancel`.
    class Subscription
      @id : UInt32

      protected def initialize(@bus : DBus, @id : UInt32)
      end

      # Whether the subscription still receives signals.
      def active? : Bool
        @id != 0
      end

      # Stops the subscription; does nothing once it stopped.
      def cancel : Nil
        id = @id
        return if id == 0
        @id = 0_u32
        C.g_dbus_connection_signal_unsubscribe(@bus, id)
      end
    end

    private record Reply, bus : DBus, block : Proc(Variant?, GLibError?, Nil)

    private CALLED = ->(source : Void*, result : Void*, data : Void*) do
      reply = Handles.get(data, Reply)
      Handles.release(data)
      value, error = begin
        {Variant.take(GLibError.check! { |error| C.g_dbus_connection_call_finish(source, result, error) }), nil}
      rescue ex : GLibError
        {nil, ex}
      end
      begin
        reply.block.call(value, error)
      rescue ex
        Log.error(exception: ex) { "dbus reply" }
      end
      nil
    end

    private RECEIVED = ->(_connection : Void*, sender : UInt8*, path : UInt8*, interface : UInt8*, member : UInt8*, parameters : Void*, data : Void*) do
      begin
        signal = Signal.new(Native.string?(sender) || "", String.new(path), String.new(interface), String.new(member),
          Variant.from_raw(parameters))
        Handles.get(data, Proc(Signal, Nil)).call(signal)
      rescue ex
        Log.error(exception: ex) { "dbus signal" }
      end
      nil
    end

    # Returns the shared connection to the session bus. Raises `GLibError`
    # when there is none.
    def self.session : DBus
      bus(:session)
    end

    # Returns the shared connection to the system bus. Raises `GLibError`
    # when there is none.
    def self.system : DBus
      bus(:system)
    end

    private def self.bus(type : C::GBusType) : DBus
      take(GLibError.check! { |error| C.g_bus_get_sync(type, nil, error) })
    end

    # Returns the connection's unique bus name, such as `":1.42"`.
    def unique_name : String
      Native.string?(C.g_dbus_connection_get_unique_name(self)) || ""
    end

    # Calls *method* of *interface* on the object *path* of *destination*
    # with *args*, a tuple variant or `nil` for none, and yields the reply
    # tuple or the error.
    #
    # *reply_type* (a tuple type string such as `"(u)"`) turns a reply of
    # another type into an error. Without a *timeout* the bus default (25
    # seconds) applies. The block runs on the calling thread's main loop.
    # Raises `ArgumentError` when *args* is not a tuple.
    def call(destination : String?, path : String, interface : String, method : String, args : Variant? = nil, *,
             reply_type : String? = nil, timeout : Time::Span? = nil, auto_start : Bool = true,
             &block : Variant?, GLibError? ->) : Nil
      check_tuple(args)
      Variant.with_type(reply_type) do |type|
        C.g_dbus_connection_call(self, cstr(destination), path, interface, method, raw(args), type, call_flags(auto_start),
          milliseconds(timeout), nil, CALLED, Handles.retain(Reply.new(self, block)))
      end
    end

    # Calls *method* like `#call` but waits for the reply tuple and returns
    # it. Raises `GLibError` when the call fails, `ArgumentError` when *args*
    # is not a tuple. Blocks the calling thread: on the GTK thread, prefer
    # `#call`.
    def call_sync(destination : String?, path : String, interface : String, method : String, args : Variant? = nil, *,
                  reply_type : String? = nil, timeout : Time::Span? = nil, auto_start : Bool = true) : Variant
      check_tuple(args)
      raw = Variant.with_type(reply_type) do |type|
        GLibError.check! do |error|
          C.g_dbus_connection_call_sync(self, cstr(destination), path, interface, method, raw(args), type, call_flags(auto_start),
            milliseconds(timeout), nil, error)
        end
      end
      Variant.take(raw)
    end

    # Emits the signal *member* of *interface* from the object *path* with
    # *args*, a tuple variant or `nil`, to *destination* or to every
    # subscriber. Raises `GLibError` when the signal cannot be sent,
    # `ArgumentError` when *args* is not a tuple.
    def emit(path : String, interface : String, member : String, args : Variant? = nil, *,
             destination : String? = nil) : Nil
      check_tuple(args)
      GLibError.check! { |error| C.g_dbus_connection_emit_signal(self, cstr(destination), path, interface, member, raw(args), error) }
    end

    # Yields each signal that matches every given filter: *sender* (a
    # unique or well-known name), *interface*, *member*, *path* and the
    # first argument *arg0* (a string). The block runs on the calling
    # thread's main loop until the returned subscription is cancelled.
    def subscribe(*, sender : String? = nil, interface : String? = nil, member : String? = nil,
                  path : String? = nil, arg0 : String? = nil, &block : Signal ->) : Subscription
      id = C.g_dbus_connection_signal_subscribe(self, cstr(sender), cstr(interface), cstr(member), cstr(path), cstr(arg0),
        C::GDBusSignalFlags::None,
        RECEIVED, Handles.retain(block), Handles::RELEASE)
      Subscription.new(self, id)
    end

    private def check_tuple(args : Variant?) : Nil
      return unless args
      raise ArgumentError.new("D-Bus arguments must be a tuple, not #{args.type_string}") unless args.type_string.starts_with?('(')
    end

    private def cstr(text : String?) : UInt8*
      text ? text.to_unsafe : Pointer(UInt8).null
    end

    private def raw(args : Variant?) : Void*
      args ? args.to_unsafe : Pointer(Void).null
    end

    private def call_flags(auto_start : Bool) : C::GDBusCallFlags
      auto_start ? C::GDBusCallFlags::None : C::GDBusCallFlags::NoAutoStart
    end

    private def milliseconds(timeout : Time::Span?) : Int32
      timeout ? timeout.total_milliseconds.clamp(0, Int32::MAX).to_i32 : -1
    end
  end

  abstract class App
    # Returns the running application's connection to the session bus, the
    # one its actions and notifications use, or `nil` while it is not
    # registered on the bus.
    def dbus : DBus?
      return if @application.null?
      DBus.from_raw?(C.g_application_get_dbus_connection(@application))
    end
  end
end
