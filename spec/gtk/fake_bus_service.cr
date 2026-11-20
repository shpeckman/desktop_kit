# spec/gtk/fake_bus_service.cr
require "./harness"

# A D-Bus service owning a well-known name on the private session bus. Like
# a real service process it runs on a thread, main context and connection
# of its own, so it answers while the app under test starts, runs and shuts
# down, even to synchronous calls from the GTK thread. Subclasses describe
# the service in `#xml`, export interfaces in `#start_service` and answer in
# `#call`.
abstract class FakeBusService
  # DBUS_NAME_FLAG_DO_NOT_QUEUE; RequestName answers 1 to the new owner.
  private DO_NOT_QUEUE  = 4_u32
  private PRIMARY_OWNER = 1_u32

  private METHOD_CALL = ->(connection : Void*, sender : UInt8*, path : UInt8*, interface : UInt8*, method : UInt8*, parameters : Void*, invocation : Void*, data : Void*) do
    service = Apprt::Handles.get(data, FakeBusService)
    begin
      service.call(String.new(sender), String.new(path), String.new(interface), String.new(method),
        Apprt::Variant.from_raw(parameters), invocation)
    rescue ex
      Apprt::C.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", ex.message || ex.class.name)
    end
    nil
  end

  # Waits up to *timeout* for *condition* without running a main loop, for
  # checks after the app under test stopped.
  def self.poll(timeout : Time::Span = 5.seconds, & : -> Bool) : Bool
    deadline = Time.instant + timeout
    until yield
      return false if Time.instant >= deadline
      sleep 5.milliseconds
    end
    true
  end

  @lock = Mutex.new
  @context : Void* = Apprt::C.g_main_context_new
  @connection = Pointer(Void).null
  @node = Pointer(Void).null
  @vtable = Pointer(Apprt::C::GDBusInterfaceVTable).malloc(1)
  @handle = Pointer(Void).null
  @objects = {} of String => Array(UInt32)
  @quit = Atomic(Bool).new(false)
  @stopped = Channel(Nil).new(1)

  # Owns *name* and serves until `#stop`.
  def initialize(@name : String)
    @vtable.value.method_call = METHOD_CALL
    ready = Channel(Exception?).new(1)
    Fiber::ExecutionContext::Isolated.new(@name) { run(ready) }
    ready.receive.try { |ex| raise ex }
  end

  def stop : Nil
    @quit.set(true)
    Apprt::C.g_main_context_wakeup(@context)
    @stopped.receive
    Apprt::C.g_main_context_unref(@context)
  end

  # Returns the introspection XML of every interface the service exports.
  private abstract def xml : String

  # Exports the service's objects; runs on the service thread before the
  # name is owned.
  private abstract def start_service : Nil

  # Answers *method* of *interface* on *path*; runs on the service thread.
  protected abstract def call(sender : String, path : String, interface : String, method : String, parameters : Apprt::Variant, invocation : Void*) : Nil

  # Exports *interface* of `#xml` on *path*.
  private def export(path : String, interface : String) : Nil
    info = Apprt::C.g_dbus_node_info_lookup_interface(@node, interface)
    id = Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_register_object(@connection, path, info, @vtable, @handle, nil, error)
    end
    (@objects[path] ||= [] of UInt32) << id
  end

  # Removes every interface exported on *path*.
  private def unexport(path : String) : Nil
    @objects.delete(path).try &.each { |id| Apprt::C.g_dbus_connection_unregister_object(@connection, id) }
  end

  private def reply(invocation : Void*, value : Apprt::Variant?) : Nil
    Apprt::C.g_dbus_method_invocation_return_value(invocation, value.try(&.to_unsafe) || Pointer(Void).null)
  end

  private def emit(destination : String?, path : String, interface : String, signal : String, parameters : Apprt::Variant) : Nil
    Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_emit_signal(@connection, destination, path, interface, signal, parameters, error)
    end
  end

  # The service thread: serves on `@context` until `#stop`.
  private def run(ready : Channel(Exception?)) : Nil
    Apprt::C.g_main_context_push_thread_default(@context)
    begin
      start
    rescue ex
      ready.send(ex)
      return
    end
    ready.send(nil)
    until @quit.get
      Apprt::C.g_main_context_iteration(@context, 1)
    end
  ensure
    finish
    Apprt::C.g_main_context_pop_thread_default(@context)
    @stopped.send(nil)
  end

  private def start : Nil
    flags = Apprt::C::GDBusConnectionFlags::AuthenticationClient | Apprt::C::GDBusConnectionFlags::MessageBusConnection
    @connection = Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_new_for_address_sync(ENV["DBUS_SESSION_BUS_ADDRESS"], flags, nil, nil, error)
    end
    @node = Apprt::GLibError.check! { |error| Apprt::C.g_dbus_node_info_new_for_xml(xml, error) }
    @handle = Apprt::Handles.retain(self.as(FakeBusService))
    start_service
    reply = Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_call_sync(@connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "RequestName", Apprt::Variant.new({@name, DO_NOT_QUEUE}), nil, Apprt::C::GDBusCallFlags::None, -1, nil, error)
    end
    owner = Apprt::Variant.take(reply)[0].get(UInt32)
    raise "#{self.class}: #{@name} is taken" unless owner == PRIMARY_OWNER
  end

  # Closing the connection releases the bus name.
  private def finish : Nil
    return if @connection.null?
    @objects.each_value { |ids| ids.each { |id| Apprt::C.g_dbus_connection_unregister_object(@connection, id) } }
    @objects.clear
    Apprt::C.g_dbus_connection_close_sync(@connection, nil, nil)
    Apprt::C.g_object_unref(@connection)
    Apprt::C.g_dbus_node_info_unref(@node) unless @node.null?
    Apprt::Handles.release(@handle) unless @handle.null?
  end
end
