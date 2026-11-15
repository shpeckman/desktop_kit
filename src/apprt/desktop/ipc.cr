# src/apprt/desktop/ipc.cr
module Apprt
  # Sends actions to a running application from another process.
  #
  # ```
  # Apprt::IPC.send("org.example.Hello", Apprt::Action::NewWindow.new)
  # ```
  module IPC
    # Triggers *action* in the running instance of the application *app_id*
    # on the session bus.
    #
    # Only actions declared with `ipc: true` compile. The receiving
    # application must run as a single instance. The call blocks the calling
    # thread until the application answers, so never send to the application
    # whose GTK thread makes the call. Raises `ArgumentError` for an invalid
    # *app_id* and `GLibError` when the bus or the application fails, such
    # as when no instance runs.
    def self.send(app_id : String, action : A) : Nil forall A
      {% raise "IPC.send: #{A} is not an ipc action; declare it with `ipc: true`" unless A < ::Apprt::Action && A.constant("IPC") %}
      raise ArgumentError.new("invalid application id: #{app_id.inspect}") if C.g_application_id_is_valid(app_id) == 0
      parameters = action.to_variant.try { |variant| [variant] } || [] of Variant
      message = Variant.new({action.name, parameters, {} of String => Variant})
      bus = GLibError.check! { |error| C.g_bus_get_sync(C::GBusType::Session, Pointer(Void).null, error) }
      begin
        reply = GLibError.check! do |error|
          C.g_dbus_connection_call_sync(bus, app_id, object_path(app_id), "org.gtk.Actions", "Activate",
            message, Pointer(Void).null, C::GDBusCallFlags::None, -1, Pointer(Void).null, error)
        end
        C.g_variant_unref(reply)
      ensure
        C.g_object_unref(bus)
      end
    end

    # GApplication's object path for an application id.
    private def self.object_path(app_id : String) : String
      "/#{app_id.tr(".-", "/_")}"
    end
  end
end
