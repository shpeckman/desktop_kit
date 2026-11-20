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
    DesktopKit::Handles.get(data, FakeNotifications).call(String.new(method), DesktopKit::Variant.from_raw(parameters), invocation)
    nil
  end

  getter sent = [] of Sent
  getter closed = [] of UInt32

  @last_id = 0_u32
  @connection : Void*
  @node : Void*
  @vtable : Pointer(DesktopKit::C::GDBusInterfaceVTable)
  @handle = Pointer(Void).null
  @registration = 0_u32

  # Serves on *app*'s bus connection while the block runs. Before it stops it
  # settles, closes *app*'s windows and settles again: GIO gets the replies
  # to its `Notify` calls before the withdrawals, and the withdrawals reach
  # this fake rather than the one of a later example. After it stops it
  # settles once more, so GIO sees the name vanish while *app* still holds
  # its notification backend: GLib's vanish handler crashes a backend that
  # only its notifications keep alive.
  def self.serve(app : DesktopKit::App, & : FakeNotifications ->) : Nil
    fake = new(DesktopKit::C.g_application_get_dbus_connection(app))
    begin
      yield fake
    ensure
      # GLib 2.84.4 (unfixed on main): the freedesktop backend's
      # `name_vanished_handler_cb` frees its list before clearing it, so the
      # final unref double-frees (stack overflow), and an unsettled vanish
      # idle runs in a later run.
      settle
      app.windows.each(&.close)
      settle
      fake.stop
      settle
    end
  end

  def initialize(connection : Void*)
    raise "FakeNotifications: the app has no bus connection" if connection.null?
    @connection = DesktopKit::C.g_object_ref(connection)
    @node = DesktopKit::GLibError.check! { |error| DesktopKit::C.g_dbus_node_info_new_for_xml(XML, error) }
    @vtable = Pointer(DesktopKit::C::GDBusInterfaceVTable).malloc(1)
    @vtable.value.method_call = METHOD_CALL
    @handle = DesktopKit::Handles.retain(self)
    interface = DesktopKit::C.g_dbus_node_info_lookup_interface(@node, NAME)
    @registration = DesktopKit::GLibError.check! do |error|
      DesktopKit::C.g_dbus_connection_register_object(@connection, PATH, interface, @vtable, @handle, nil, error)
    end
    # Exported on the app's own connection; `DO_NOT_QUEUE` must make us the
    # primary owner (1) at once.
    owner = bus_call("RequestName", DesktopKit::Variant.new({NAME, DO_NOT_QUEUE}))[0].get(UInt32)
    raise "FakeNotifications: #{NAME} is taken" unless owner == PRIMARY_OWNER
  end

  # Clicks the notification *id*, as the desktop does.
  def click(id : UInt32, action : String = "default") : Nil
    DesktopKit::GLibError.check! do |error|
      DesktopKit::C.g_dbus_connection_emit_signal(@connection, nil, PATH, NAME, "ActionInvoked", DesktopKit::Variant.new({id, action}), error)
    end
  end

  def stop : Nil
    bus_call("ReleaseName", DesktopKit::Variant.new({NAME}))
    DesktopKit::C.g_dbus_connection_unregister_object(@connection, @registration)
    DesktopKit::C.g_dbus_node_info_unref(@node)
    DesktopKit::C.g_object_unref(@connection)
    DesktopKit::Handles.release(@handle)
  end

  protected def call(method : String, parameters : DesktopKit::Variant, invocation : Void*) : Nil
    case method
    when "Notify"
      replaces_id = parameters[1].get(UInt32)
      id = replaces_id == 0 ? (@last_id += 1) : replaces_id
      @sent << Sent.new(id, parameters[0].get(String), replaces_id, parameters[3].get(String),
        parameters[4].get(String), parameters[5].get(Array(String)))
      reply(invocation, DesktopKit::Variant.new({id}))
    when "CloseNotification"
      @closed << parameters[0].get(UInt32)
      reply(invocation, nil)
    when "GetCapabilities"
      reply(invocation, DesktopKit::Variant.new({["actions", "body"]}))
    when "GetServerInformation"
      reply(invocation, DesktopKit::Variant.new({"fake", "desktop_kit", "1", "1.2"}))
    else
      DesktopKit::C.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", method)
    end
  rescue ex
    DesktopKit::C.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.Failed", ex.message || ex.class.name)
  end

  private def reply(invocation : Void*, value : DesktopKit::Variant?) : Nil
    DesktopKit::C.g_dbus_method_invocation_return_value(invocation, value.try(&.to_unsafe) || Pointer(Void).null)
  end

  private def bus_call(method : String, parameters : DesktopKit::Variant) : DesktopKit::Variant
    reply = DesktopKit::GLibError.check! do |error|
      DesktopKit::C.g_dbus_connection_call_sync(@connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        method, parameters, nil, DesktopKit::C::GDBusCallFlags::None, -1, nil, error)
    end
    DesktopKit::Variant.take(reply)
  end
end
