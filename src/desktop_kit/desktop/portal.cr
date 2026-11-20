# src/desktop_kit/desktop/portal.cr
module DesktopKit
  # :nodoc:
  # XDG desktop portal calls.
  # A request method returns a request object path at once and answers later
  # with that object's `Response` signal; `Request` subscribes to the path it
  # predicts from the connection's unique name and its handle token before it
  # calls, so the answer cannot arrive first.
  module Portal
    BUS_NAME       = "org.freedesktop.portal.Desktop"
    OBJECT_PATH    = "/org/freedesktop/portal/desktop"
    REQUEST_PREFIX = "#{OBJECT_PATH}/request/"

    # The reason a request fails when the user cancelled it.
    CANCELLED = "the request was cancelled"

    # Reasons of the non-zero response codes.
    private FAILURES = {
      1_u32 => CANCELLED,
      2_u32 => "the request ended unexpectedly",
    }

    # Logs the failure of a call made with `.send`.
    private SENT = ->(source : Void*, result : Void*, data : Void*) do
      error = Pointer(C::GError).null
      reply = C.g_dbus_connection_call_finish(source, result, pointerof(error))
      if error.null?
        C.g_variant_unref(reply)
      else
        message = GLibError.take(error).message
        Log.debug { "portal call: #{message}" }
      end
    end

    # Returns a fresh handle token.
    def self.token : String
      "desktop_kit_#{Random::Secure.hex(8)}"
    end

    # Returns the request object path for *token* on the connection named
    # *unique_name*.
    def self.request_path(unique_name : String, token : String) : String
      "#{REQUEST_PREFIX}#{unique_name.lchop(':').tr(".", "_")}/#{token}"
    end

    # Calls *method* without waiting for the answer; failures are logged at
    # debug level.
    def self.send(connection : Void*, path : String, interface : String, method : String, parameters : Variant?) : Nil
      C.g_dbus_connection_call(connection, BUS_NAME, path, interface, method, parameters.try(&.to_unsafe) || Pointer(Void).null,
        Pointer(Void).null, C::GDBusCallFlags::None, -1, Pointer(Void).null, SENT, Pointer(Void).null)
    end

    # Tells the portal the application id of *connection*, which it cannot
    # tell from a host process. Must precede every other portal call on
    # *connection*.
    def self.register(connection : Void*, app_id : String) : Nil
      # Registry takes Register only before any other portal call on the
      # connection; GTK calls the settings portal in startup, so `App#run`
      # sends it before `g_application_run`. Needed outside Flatpak/systemd
      # app scopes only: failures just logged at debug.
      send(connection, OBJECT_PATH, "org.freedesktop.host.portal.Registry", "Register",
        Variant.new({app_id, {} of String => Variant}))
    end

    # One request method call. The block passed to `.new` receives the
    # response results, or `nil` and the reason the request failed; it runs
    # at most once, and never after `#cancel`.
    class Request
      # The handle token; the call's options must carry it as `handle_token`.
      getter token : String = Portal.token

      @done : Proc(Variant?, String?, Nil)
      @subscription = 0_u32
      # Whether the request answered, failed or was cancelled.
      getter? finished = false

      @cancellable : Void*

      private RESPONSE = ->(connection : Void*, sender : UInt8*, path : UInt8*, interface : UInt8*, signal : UInt8*, parameters : Void*, data : Void*) do
        begin
          Handles.get(data, Request).responded(Variant.from_raw(parameters))
        rescue ex
          Log.error(exception: ex) { "portal response" }
        end
      end

      private CALLED = ->(source : Void*, result : Void*, data : Void*) do
        begin
          request = Handles.get(data, Request)
          Handles.release(data)
          request.called(source, result)
        rescue ex
          Log.error(exception: ex) { "portal reply" }
        end
      end

      def initialize(@connection : Void*, &done : Variant?, String? -> Nil)
        @done = done
        unique_name = Native.string?(C.g_dbus_connection_get_unique_name(@connection)) || ""
        @cancellable = C.g_cancellable_new
        @subscription = C.g_dbus_connection_signal_subscribe(@connection, Pointer(UInt8).null, "org.freedesktop.portal.Request",
          "Response", Portal.request_path(unique_name, @token), Pointer(UInt8).null, C::GDBusSignalFlags::None, RESPONSE, Handles.retain(self), Handles::RELEASE)
      end

      # Calls *method* of *interface* on the portal with *parameters*.
      def call(interface : String, method : String, parameters : Variant) : Nil
        C.g_dbus_connection_call(@connection, BUS_NAME, OBJECT_PATH, interface, method, parameters, Pointer(Void).null,
          C::GDBusCallFlags::None, -1, @cancellable, CALLED, Handles.retain(self))
      end

      # Drops the request without calling the block.
      def cancel : Nil
        return if @finished
        C.g_cancellable_cancel(@cancellable)
        stop
      end

      protected def called(source : Void*, result : Void*) : Nil
        error = Pointer(C::GError).null
        reply = C.g_dbus_connection_call_finish(source, result, pointerof(error))
        if error.null?
          # Reply = request path; ignored, always the predicted one since xdg-desktop-portal 0.9.
          C.g_variant_unref(reply)
        else
          finish(nil, GLibError.take(error).message || "the call failed")
        end
      end

      # Handles the `(ua{sv})` arguments of `Response`.
      protected def responded(parameters : Variant) : Nil
        code = parameters[0].get(UInt32)
        if code == 0
          finish(parameters[1], nil)
        else
          finish(nil, FAILURES.fetch(code) { "the request failed with response #{code}" })
        end
      end

      private def finish(results : Variant?, error : String?) : Nil
        return if @finished
        stop
        @done.call(results, error)
      end

      private def stop : Nil
        @finished = true
        C.g_dbus_connection_signal_unsubscribe(@connection, @subscription)
        C.g_object_unref(@cancellable)
      end
    end
  end
end
