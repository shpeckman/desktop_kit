# spec/gtk/desktop/fake_notifications.cr
require "../harness"

# An `org.freedesktop.Notifications` server on the spec session bus. It runs
# on the GTK thread of the app under test, records what GIO's freedesktop
# notification backend sends and emits clicks.
class FakeNotifications
  # One `Notify` call.
  record Sent, id : UInt32, app_name : String, replaces_id : UInt32, summary : String, body : String, actions : Array(String)

  NAME = "org.freedesktop.Notifications"
  PATH = "/org/freedesktop/Notifications"

  private XML = <<-XML
    <node>
      <interface name="org.freedesktop.Notifications">
        <method name="Notify">
          <arg type="s" direction="in"/>
          <arg type="u" direction="in"/>
          <arg type="s" direction="in"/>
          <arg type="s" direction="in"/>
          <arg type="s" direction="in"/>
          <arg type="as" direction="in"/>
          <arg type="a{sv}" direction="in"/>
          <arg type="i" direction="in"/>
          <arg type="u" direction="out"/>
        </method>
        <method name="CloseNotification">
          <arg type="u" direction="in"/>
        </method>
        <method name="GetCapabilities">
          <arg type="as" direction="out"/>
        </method>
        <method name="GetServerInformation">
          <arg type="s" direction="out"/>
          <arg type="s" direction="out"/>
          <arg type="s" direction="out"/>
          <arg type="s" direction="out"/>
        </method>
        <signal name="NotificationClosed">
          <arg type="u"/>
          <arg type="u"/>
        </signal>
        <signal name="ActionInvoked">
          <arg type="u"/>
          <arg type="s"/>
        </signal>
      </interface>
    </node>
    XML

  # DBUS_NAME_FLAG_DO_NOT_QUEUE; RequestName answers 1 to the new owner.
  private DO_NOT_QUEUE  = 4_u32
  private PRIMARY_OWNER = 1_u32

  private METHOD_CALL = ->(connection : Void*, sender : UInt8*, path : UInt8*, interface : UInt8*, method : UInt8*, parameters : Void*, invocation : Void*, data : Void*) do
    Apprt::Handles.get(data, FakeNotifications).call(String.new(method), Apprt::Variant.from_raw(parameters), invocation)
    nil
  end

  getter sent = [] of Sent
  getter closed = [] of UInt32

  @last_id = 0_u32
  @connection : Void*
  @node : Void*
  @vtable : Pointer(Apprt::C::GDBusInterfaceVTable)
  @handle = Pointer(Void).null
  @registration = 0_u32

  # Serves on *app*'s bus connection while the block runs. Before it stops it
  # settles, closes *app*'s windows and settles again: GIO gets the replies
  # to its `Notify` calls before the withdrawals, and the withdrawals reach
  # this fake rather than the one of a later example. After it stops it
  # settles once more, so GIO sees the name vanish while *app* still holds
  # its notification backend: GLib's vanish handler crashes a backend that
  # only its notifications keep alive.
  def self.serve(app : Apprt::App, & : FakeNotifications ->) : Nil
    fake = new(Apprt::C.g_application_get_dbus_connection(app))
    begin
      yield fake
    ensure
      settle
      app.windows.each(&.close)
      settle
      fake.stop
      settle
    end
  end

  def initialize(connection : Void*)
    raise "FakeNotifications: the app has no bus connection" if connection.null?
    @connection = Apprt::C.g_object_ref(connection)
    @node = Apprt::GLibError.check! { |error| Apprt::C.g_dbus_node_info_new_for_xml(XML, error) }
    @vtable = Pointer(Apprt::C::GDBusInterfaceVTable).malloc(1)
    @vtable.value.method_call = METHOD_CALL
    @handle = Apprt::Handles.retain(self)
    interface = Apprt::C.g_dbus_node_info_lookup_interface(@node, NAME)
    @registration = Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_register_object(@connection, PATH, interface, @vtable, @handle, nil, error)
    end
    owner = bus_call("RequestName", Apprt::Variant.new({NAME, DO_NOT_QUEUE}))[0].get(UInt32)
    raise "FakeNotifications: #{NAME} is taken" unless owner == PRIMARY_OWNER
  end

  # Clicks the notification *id*, as the desktop does.
  def click(id : UInt32, action : String = "default") : Nil
    Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_emit_signal(@connection, nil, PATH, NAME, "ActionInvoked", Apprt::Variant.new({id, action}), error)
    end
  end

  def stop : Nil
    bus_call("ReleaseName", Apprt::Variant.new({NAME}))
    Apprt::C.g_dbus_connection_unregister_object(@connection, @registration)
    Apprt::C.g_dbus_node_info_unref(@node)
    Apprt::C.g_object_unref(@connection)
    Apprt::Handles.release(@handle)
  end

  protected def call(method : String, parameters : Apprt::Variant, invocation : Void*) : Nil
    case method
    when "Notify"
      replaces_id = parameters[1].get(UInt32)
      id = replaces_id == 0 ? (@last_id += 1) : replaces_id
      @sent << Sent.new(id, parameters[0].get(String), replaces_id, parameters[3].get(String),
        parameters[4].get(String), parameters[5].get(Array(String)))
      reply(invocation, Apprt::Variant.new({id}))
    when "CloseNotification"
      @closed << parameters[0].get(UInt32)
      reply(invocation, nil)
    when "GetCapabilities"
      reply(invocation, Apprt::Variant.new({["actions", "body"]}))
    when "GetServerInformation"
      reply(invocation, Apprt::Variant.new({"fake", "apprt", "1", "1.2"}))
    else
      Apprt::C.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", method)
    end
  rescue ex
    Apprt::C.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", ex.message || ex.class.name)
  end

  private def reply(invocation : Void*, value : Apprt::Variant?) : Nil
    Apprt::C.g_dbus_method_invocation_return_value(invocation, value.try(&.to_unsafe) || Pointer(Void).null)
  end

  private def bus_call(method : String, parameters : Apprt::Variant) : Apprt::Variant
    reply = Apprt::GLibError.check! do |error|
      Apprt::C.g_dbus_connection_call_sync(@connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        method, parameters, nil, Apprt::C::GDBusCallFlags::None, -1, nil, error)
    end
    Apprt::Variant.take(reply)
  end
end
