# src/apprt/open_uri.cr
module Apprt
  # :nodoc:
  # Opens URLs with the XDG OpenURI portal, ported from Ghostty's
  # `src/apprt/gtk/portal/OpenURI.zig`. The portal takes no `file://` URLs,
  # so those and plain paths go to `xdg-open` at once, as Ghostty's
  # `src/os/open.zig` does; so does a URL whose request failed for any
  # reason but the user cancelling. Ghostty's cleanup timer, which falls
  # back to `xdg-open` after 30 seconds without an answer, is left out: a
  # portal still waiting on the user's choice of app would open the URL
  # twice. A null *connection* opens everything with `xdg-open`.
  class OpenURI
    INTERFACE = "org.freedesktop.portal.OpenURI"

    @requests = [] of Portal::Request

    def initialize(@connection : Void*)
      C.g_object_ref(@connection) unless @connection.null?
    end

    # Opens *url*; *activation_token* lets the app that opens it take the
    # focus.
    def open(url : String, activation_token : String?) : Nil
      return OpenURI.xdg_open(url) if @connection.null? || local?(url)
      @requests.reject!(&.finished?)
      request = Portal::Request.new(@connection) do |_, error|
        OpenURI.xdg_open(url) unless error.nil? || error == Portal::CANCELLED
      end
      @requests << request
      options = {
        "handle_token" => Variant.new(request.token),
        "writable"     => Variant.new(false),
        "ask"          => Variant.new(false),
      }
      activation_token.try { |token| options["activation_token"] = Variant.new(token) }
      request.call(INTERFACE, "OpenURI", Variant.new({"", url, options}))
    end

    # Cancels the pending requests and drops the connection.
    def release : Nil
      @requests.each(&.cancel)
      @requests.clear
      C.g_object_unref(@connection) unless @connection.null?
    end

    # Runs `xdg-open` on *url* and logs its error output when it fails.
    def self.xdg_open(url : String) : Nil
      process = Process.new("xdg-open", [url], output: :close, error: :pipe)
      spawn(name: "xdg-open") do
        message = process.error.gets_to_end.strip
        status = process.wait
        Log.warn { "xdg-open #{url}: #{message.presence || status}" } unless status.success?
      end
    rescue ex : IO::Error
      Log.error { "open url #{url}: #{ex.message}" }
    end

    private def local?(url : String) : Bool
      url.starts_with?('/') || url.starts_with?("file://")
    end
  end

  abstract class App
    @open_uri : OpenURI?

    protected def perform(target : App, action : Action::OpenUrl) : Bool
      open_uri = @open_uri ||= OpenURI.new(C.g_application_get_dbus_connection(@application))
      open_uri.open(action.url, activation_token)
      true
    end

    # Cancels the pending portal requests; called at shutdown.
    private def release_open_uri : Nil
      @open_uri.try(&.release)
      @open_uri = nil
    end

    # Returns an XDG activation token from the display, nil when it gives
    # none.
    private def activation_token : String?
      display = C.gdk_display_get_default
      return if display.null?
      context = C.gdk_display_get_app_launch_context(display)
      begin
        Native.take_string?(C.g_app_launch_context_get_startup_notify_id(context, nil, nil))
      ensure
        C.g_object_unref(context)
      end
    end
  end
end
