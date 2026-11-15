# spec/gtk/desktop/fake_portal.cr
require "../harness"

# The parts of `org.freedesktop.portal.Desktop` that apprt calls: the host
# registry, global shortcuts and OpenURI. Like the portal process, it runs on a
# thread and bus connection of its own, so it answers while the app under
# test starts, runs and shuts down; it records the calls until `#stop`.
# *deny* lists shortcut ids that `BindShortcuts` leaves out of the bound
# set; *response* is the response code of `BindShortcuts` and `OpenURI`.
class FakePortal
  # One shortcut of a `BindShortcuts` call.
  record Shortcut, id : String, description : String, preferred_trigger : String

  # One `OpenURI` call and the options it passed.
  record Opened, uri : String, ask : Bool?, writable : Bool?, activation_token : String?

  NAME      = Apprt::Portal::BUS_NAME
  PATH      = Apprt::Portal::OBJECT_PATH
  REGISTRY  = "org.freedesktop.host.portal.Registry"
  SHORTCUTS = "org.freedesktop.portal.GlobalShortcuts"
  SESSION   = "org.freedesktop.portal.Session"
  OPEN_URI  = "org.freedesktop.portal.OpenURI"

  private XML = <<-XML
    <node>
      <interface name="org.freedesktop.host.portal.Registry">
        <method name="Register">
          <arg type="s" direction="in"/>
          <arg type="a{sv}" direction="in"/>
        </method>
      </interface>
      <interface name="org.freedesktop.portal.GlobalShortcuts">
        <method name="CreateSession">
          <arg type="a{sv}" direction="in"/>
          <arg type="o" direction="out"/>
        </method>
        <method name="BindShortcuts">
          <arg type="o" direction="in"/>
          <arg type="a(sa{sv})" direction="in"/>
          <arg type="s" direction="in"/>
          <arg type="a{sv}" direction="in"/>
          <arg type="o" direction="out"/>
        </method>
        <signal name="Activated">
          <arg type="o"/>
          <arg type="s"/>
          <arg type="t"/>
          <arg type="a{sv}"/>
        </signal>
      </interface>
      <interface name="org.freedesktop.portal.Session">
        <method name="Close"/>
      </interface>
      <interface name="org.freedesktop.portal.OpenURI">
        <method name="OpenURI">
          <arg type="s" direction="in"/>
          <arg type="s" direction="in"/>
          <arg type="a{sv}" direction="in"/>
          <arg type="o" direction="out"/>
        </method>
      </interface>
    </node>
    XML

  # DBUS_NAME_FLAG_DO_NOT_QUEUE; RequestName answers 1 to the new owner.
  private DO_NOT_QUEUE  = 4_u32
  private PRIMARY_OWNER = 1_u32

  private METHOD_CALL = ->(connection : Void*, sender : UInt8*, path : UInt8*, interface : UInt8*, method : UInt8*, parameters : Void*, invocation : Void*, data : Void*) do
    Apprt::Handles.get(data, FakePortal).call(String.new(sender), String.new(path), String.new(interface), String.new(method),
      Apprt::Variant.from_raw(parameters), invocation)
    nil
  end

  @lock = Mutex.new
  @registered = [] of String
  @sessions = [] of String
  @closed = [] of String
  @shortcuts = [] of Shortcut
  @opened = [] of Opened
  @context : Void* = Apprt::C.g_main_context_new
  @connection = Pointer(Void).null
  @node = Pointer(Void).null
  @vtable = Pointer(Apprt::C::GDBusInterfaceVTable).malloc(1)
  @handle = Pointer(Void).null
  @registrations = [] of UInt32
  @session_objects = {} of String => UInt32
  @quit = Atomic(Bool).new(false)
  @stopped = Channel(Nil).new(1)

  # Serves while the block runs.
  def self.serve(*, deny : Array(String) = [] of String, response : UInt32 = 0_u32, & : FakePortal ->) : Nil
    portal = new(deny, response)
    begin
      yield portal
    ensure
      portal.stop
    end
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

  def initialize(@deny : Array(String), @response : UInt32)
    @vtable.value.method_call = METHOD_CALL
    ready = Channel(Exception?).new(1)
    Fiber::ExecutionContext::Isolated.new("portal") { run(ready) }
    ready.receive.try { |ex| raise ex }
  end

  # Returns the application ids passed to `Register`.
  def registered : Array(String)
    @lock.synchronize { @registered.dup }
  end

  # Returns the session handles in creation order.
  def sessions : Array(String)
    @lock.synchronize { @sessions.dup }
  end

  # Returns the session handles closed, in order.
  def closed : Array(String)
    @lock.synchronize { @closed.dup }
  end

  # Returns the shortcuts of every `BindShortcuts` call.
  def shortcuts : Array(Shortcut)
    @lock.synchronize { @shortcuts.dup }
  end

  # Returns the `OpenURI` calls in order.
  def opened : Array(Opened)
    @lock.synchronize { @opened.dup }
  end

  # Emits `Activated` for the shortcut *id* of the newest session, as the
  # desktop does when the user presses it.
  def activate(id : String) : Nil
    session = sessions.last
    parameters = Apprt::Variant.new({Apprt::Variant::ObjectPath.new(session), id, 0_u64, {} of String => Apprt::Variant})
    Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_emit_signal(@connection, nil, PATH, SHORTCUTS, "Activated", parameters, error)
    end
  end

  def stop : Nil
    @quit.set(true)
    Apprt::C.g_main_context_wakeup(@context)
    @stopped.receive
    Apprt::C.g_main_context_unref(@context)
  end

  protected def call(sender : String, path : String, interface : String, method : String, parameters : Apprt::Variant, invocation : Void*) : Nil
    case {interface, method}
    when {REGISTRY, "Register"}
      @lock.synchronize { @registered << parameters[0].get(String) }
      reply(invocation, nil)
    when {SHORTCUTS, "CreateSession"}
      options = parameters[0]
      token = options["session_handle_token"]?.try(&.get(String)) || "session"
      session = "#{PATH}/session/#{sender.lchop(':').tr(".", "_")}/#{token}"
      @session_objects[session] = export(session, SESSION)
      @lock.synchronize { @sessions << session }
      respond(invocation, sender, options, 0_u32, {"session_handle" => Apprt::Variant.new(session)})
    when {SHORTCUTS, "BindShortcuts"}
      respond(invocation, sender, parameters[3], @response, {"shortcuts" => Apprt::Variant.new(bind(parameters[1]))})
    when {OPEN_URI, "OpenURI"}
      options = parameters[2]
      opened = Opened.new(parameters[1].get(String), options["ask"]?.try(&.get(Bool)), options["writable"]?.try(&.get(Bool)),
        options["activation_token"]?.try(&.get(String)))
      @lock.synchronize { @opened << opened }
      respond(invocation, sender, options, @response, {} of String => Apprt::Variant)
    when {SESSION, "Close"}
      reply(invocation, nil)
      @session_objects.delete(path).try { |id| Apprt::C.g_dbus_connection_unregister_object(@connection, id) }
      @lock.synchronize { @closed << path }
    else
      Apprt::C.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", method)
    end
  rescue ex
    Apprt::C.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", ex.message || ex.class.name)
  end

  # Records the `a(sa{sv})` *list* and returns the shortcuts it binds.
  private def bind(list : Apprt::Variant) : Array({String, Hash(String, Apprt::Variant)})
    bound = [] of {String, Hash(String, Apprt::Variant)}
    list.size.times do |index|
      id = list[index][0].get(String)
      options = list[index][1]
      shortcut = Shortcut.new(id, options["description"]?.try(&.get(String)) || "",
        options["preferred_trigger"]?.try(&.get(String)) || "")
      @lock.synchronize { @shortcuts << shortcut }
      next if @deny.includes?(id)
      bound << {id, {"description" => Apprt::Variant.new(shortcut.description), "trigger_description" => Apprt::Variant.new(id)}}
    end
    bound
  end

  # Answers a request method with its request handle, then emits the
  # request's `Response` to *sender*.
  private def respond(invocation : Void*, sender : String, options : Apprt::Variant, code : UInt32, results : Hash(String, Apprt::Variant)) : Nil
    token = options["handle_token"]?.try(&.get(String)) || "request"
    request = Apprt::Portal.request_path(sender, token)
    reply(invocation, Apprt::Variant.new({Apprt::Variant::ObjectPath.new(request)}))
    Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_emit_signal(@connection, sender, request, "org.freedesktop.portal.Request", "Response",
        Apprt::Variant.new({code, results}), error)
    end
  end

  private def reply(invocation : Void*, value : Apprt::Variant?) : Nil
    Apprt::C.g_dbus_method_invocation_return_value(invocation, value.try(&.to_unsafe) || Pointer(Void).null)
  end

  # The portal thread: serves on `@context` until `#stop`.
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
    @node = Apprt::GLibError.check! { |error| Apprt::C.g_dbus_node_info_new_for_xml(XML, error) }
    @handle = Apprt::Handles.retain(self)
    {REGISTRY, SHORTCUTS, OPEN_URI}.each { |interface| @registrations << export(PATH, interface) }
    reply = Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_call_sync(@connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "RequestName", Apprt::Variant.new({NAME, DO_NOT_QUEUE}), nil, Apprt::C::GDBusCallFlags::None, -1, nil, error)
    end
    owner = Apprt::Variant.take(reply)[0].get(UInt32)
    raise "FakePortal: #{NAME} is taken" unless owner == PRIMARY_OWNER
  end

  private def export(path : String, interface : String) : UInt32
    info = Apprt::C.g_dbus_node_info_lookup_interface(@node, interface)
    Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_register_object(@connection, path, info, @vtable, @handle, nil, error)
    end
  end

  # Closing the connection releases the bus name.
  private def finish : Nil
    return if @connection.null?
    (@registrations + @session_objects.values).each { |id| Apprt::C.g_dbus_connection_unregister_object(@connection, id) }
    Apprt::C.g_dbus_connection_close_sync(@connection, nil, nil)
    Apprt::C.g_object_unref(@connection)
    Apprt::C.g_dbus_node_info_unref(@node) unless @node.null?
    Apprt::Handles.release(@handle) unless @handle.null?
  end
end
