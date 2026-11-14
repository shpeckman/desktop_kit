# src/apprt/global_shortcuts.cr
module Apprt
  # :nodoc:
  # The global bindings of an application, registered with the XDG
  # GlobalShortcuts portal; ported from Ghostty's
  # `src/apprt/gtk/class/global_shortcuts.zig`. `#bind` closes the previous
  # session, then creates one and binds each distinct trigger, its XDG form
  # being the shortcut id. `Activated` signals of the session call
  # *activate*; a failed request, or a shortcut the desktop left out of the
  # bound set, calls *failed*.
  class GlobalShortcuts
    INTERFACE = "org.freedesktop.portal.GlobalShortcuts"

    private ACTIVATED = ->(connection : Void*, sender : UInt8*, path : UInt8*, interface : UInt8*, signal : UInt8*, parameters : Void*, data : Void*) do
      begin
        Handles.get(data, GlobalShortcuts).activated(Variant.from_raw(parameters))
      rescue ex
        Log.error(exception: ex) { "global shortcut" }
      end
    end

    @bindings = {} of String => Binding
    @session : String?
    @request : Portal::Request?
    @subscription = 0_u32

    def initialize(@connection : Void*, @activate : Binding ->, @failed : Binding, String ->)
      C.g_object_ref(@connection)
    end

    # Replaces the registered shortcuts with the global bindings among
    # *bindings*; triggers bound twice go to the first binding.
    def bind(bindings : Enumerable(Binding)) : Nil
      close
      bindings.each do |binding|
        @bindings[binding.trigger.to_xdg] ||= binding if binding.global?
      end
      create_session unless @bindings.empty?
    end

    # Closes the session and drops the connection.
    def release : Nil
      close
      C.g_object_unref(@connection)
    end

    protected def activated(parameters : Variant) : Nil
      @bindings[parameters[1].get(String)]?.try { |binding| @activate.call(binding) }
    end

    private def create_session : Nil
      request do |request|
        {INTERFACE, "CreateSession", Variant.new({ {
          "handle_token"         => Variant.new(request.token),
          "session_handle_token" => Variant.new(Portal.token),
        } })}
      end
    end

    # Starts *method* of the request the block builds; the response goes to
    # `#responded`.
    private def request(& : Portal::Request -> {String, String, Variant}) : Nil
      request = Portal::Request.new(@connection) { |results, error| responded(results, error) }
      @request = request
      interface, method, parameters = yield request
      request.call(interface, method, parameters)
    end

    private def responded(results : Variant?, error : String?) : Nil
      @request = nil
      if error || results.nil?
        fail_all(error || "no response")
      elsif session = @session
        bound(session, results)
      else
        session_created(results)
      end
    end

    private def session_created(results : Variant) : Nil
      handle = results["session_handle"]?
      session = handle.try { |value| value.is?(String) ? value.get(String) : value.get(Variant::ObjectPath).path }
      return fail_all("the portal returned no session") unless session
      @session = session
      @subscription = C.g_dbus_connection_signal_subscribe(@connection, Pointer(UInt8).null, INTERFACE, "Activated",
        Portal::OBJECT_PATH, session, C::GDBusSignalFlags::MatchArg0Path, ACTIVATED, Handles.retain(self), Handles::RELEASE)
      shortcuts = @bindings.map do |id, binding|
        {id, {
          "description"       => Variant.new(binding.action.detailed_name),
          "preferred_trigger" => Variant.new(id),
        }}
      end
      request do |request|
        {INTERFACE, "BindShortcuts", Variant.new({Variant::ObjectPath.new(session), shortcuts, "", {
          "handle_token" => Variant.new(request.token),
        }})}
      end
    end

    # Reports the shortcuts missing from the bound set in *results*.
    private def bound(session : String, results : Variant) : Nil
      return unless shortcuts = results["shortcuts"]?
      ids = Set(String).new
      shortcuts.size.times { |index| ids << shortcuts[index][0].get(String) }
      @bindings.each do |id, binding|
        @failed.call(binding, "the desktop did not bind the shortcut") unless ids.includes?(id)
      end
    end

    private def fail_all(message : String) : Nil
      @bindings.each_value { |binding| @failed.call(binding, message) }
    end

    private def close : Nil
      @request.try(&.cancel)
      @request = nil
      unless @subscription == 0
        C.g_dbus_connection_signal_unsubscribe(@connection, @subscription)
        @subscription = 0_u32
      end
      @session.try { |session| Portal.send(@connection, session, "org.freedesktop.portal.Session", "Close", nil) }
      @session = nil
      @bindings.clear
    end
  end
end
