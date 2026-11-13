# src/apprt/app.cr
module Apprt
  # Base of an application: subclass it, override the hooks it needs and call
  # `#run`.
  #
  # ```
  # class Hello < Apprt::App
  #   protected def on_activate
  #     puts "running"
  #     quit
  #   end
  # end
  #
  # exit Hello.new("org.example.Hello").run
  # ```
  #
  # `#run` drives GTK on a thread of its own. The hooks run on that thread; the
  # other methods are callable from any thread. One application runs at a
  # time.
  abstract class App
    # The application id, a reverse-DNS name such as `"org.example.Hello"`.
    getter id : String

    # Whether launching the application again activates the running instance
    # instead of starting a new one.
    getter? single_instance : Bool

    # The application style sheet, applied above the theme.
    getter css : String = ""

    # The requested appearance.
    getter appearance : Appearance = Appearance::System

    @@current = Atomic(App?).new(nil)

    @application = Pointer(Void).null
    @provider = Pointer(Void).null
    @dark_handler = 0_u64
    @running = Atomic(Bool).new(false)
    @ready = false

    # Creates the application with *id*; raises `ArgumentError` when *id* is not
    # a valid application id.
    def initialize(@id : String, *, @single_instance : Bool = true)
      raise ArgumentError.new("invalid application id: #{id.inspect}") if C.g_application_id_is_valid(id) == 0
    end

    # Runs the application until `#quit` or until its last window closes, and
    # returns its exit status.
    #
    # Blocks the calling fiber. Until it returns, SIGINT and SIGTERM call
    # `#quit` and SIGUSR2 calls `#reload`. Raises `RuntimeError` when an
    # application is already running.
    def run : Int32
      raise RuntimeError.new("an application is already running") unless @@current.compare_and_set(nil, self)[1]
      status = 0
      begin
        Signal::INT.trap { quit }
        Signal::TERM.trap { quit }
        Signal::USR2.trap { reload }
        Fiber::ExecutionContext::Isolated.new("gtk") { status = UIThread.enter { run_application } }.wait
      ensure
        {Signal::INT, Signal::TERM, Signal::USR2}.each(&.reset)
        @@current.set(nil)
      end
      status
    end

    # Returns whether the application is running: started up and not yet
    # shutting down.
    def running? : Bool
      @running.get
    end

    # Closes the application windows and quits; `#run` then returns 0. Does
    # nothing unless the application is running.
    def quit : Nil
      UIThread.dispatch { quit_now } if running?
    end

    # Reloads the application: calls `#on_reload` and reports the reload to
    # systemd. Does nothing unless the application is running.
    def reload : Nil
      UIThread.dispatch { reload_now } if running?
    end

    # Runs *block* on the GTK thread at the next main loop iteration.
    #
    # Blocks run in posting order; exceptions they raise are logged. Blocks
    # posted before `#run` run once the application is active; blocks still
    # queued when it quits are dropped.
    def post(&block : ->) : Nil
      UIThread.post(&block)
    end

    # Sets the application style sheet; parse errors are logged as warnings.
    def css=(css : String) : String
      @css = css
      UIThread.dispatch { load_css } if running?
      css
    end

    def appearance=(appearance : Appearance) : Appearance
      @appearance = appearance
      UIThread.dispatch { apply_appearance } if running?
      appearance
    end

    # :nodoc:
    # The GApplication, null unless `#run` is in progress.
    def to_unsafe : Void*
      @application
    end

    # :showdoc:
    #
    # Called once GTK is initialized, before the first `#on_activate`.
    protected def on_startup : Nil
    end

    # :showdoc:
    #
    # Called when the application is launched, and again whenever it is
    # launched while running as a single instance.
    protected def on_activate : Nil
    end

    # :showdoc:
    #
    # Called on `#reload`.
    protected def on_reload : Nil
    end

    # :showdoc:
    #
    # Called with the color scheme in effect after `#on_startup` and whenever
    # it changes.
    protected def on_color_scheme(scheme : ColorScheme) : Nil
    end

    # :showdoc:
    #
    # Called when the application quits, while its windows still exist.
    protected def on_shutdown : Nil
    end

    private def run_application : Int32
      flags = single_instance? ? C::GApplicationFlags::None : C::GApplicationFlags::NonUnique
      @application = C.adw_application_new(@id, flags)
      Signals.connect(@application, "startup", -> { startup })
      Signals.connect(@application, "activate", -> { activate })
      Signals.connect(@application, "shutdown", -> { shutdown })
      # GApplication rejects file arguments without HANDLES_OPEN, so it only
      # sees the program name.
      argv = [PROGRAM_NAME.to_unsafe, Pointer(UInt8).null]
      C.g_application_run(@application, 1, argv.to_unsafe)
    ensure
      C.g_object_unref(@application) unless @application.null?
      @application = Pointer(Void).null
    end

    private def startup : Nil
      @ready = false
      @provider = C.gtk_css_provider_new
      Signals.connect(@provider, "parsing-error", ->(section : Void*, error : Void*) { css_error(section, error) })
      C.gtk_style_context_add_provider_for_display(C.gdk_display_get_default, @provider, C::STYLE_PROVIDER_PRIORITY_USER)
      @running.set(true)
      load_css
      apply_appearance
      @dark_handler = Signals.notify(C.adw_style_manager_get_default, "dark", -> { color_scheme_changed })
      on_startup
      color_scheme_changed
    end

    private def activate : Nil
      on_activate
    ensure
      unless @ready
        @ready = true
        Systemd.ready
      end
    end

    private def shutdown : Nil
      @running.set(false)
      Systemd.stopping
      on_shutdown
    ensure
      Signals.disconnect(C.adw_style_manager_get_default, @dark_handler) unless @dark_handler == 0
      @dark_handler = 0_u64
      unless @provider.null?
        C.gtk_style_context_remove_provider_for_display(C.gdk_display_get_default, @provider)
        C.g_object_unref(@provider)
        @provider = Pointer(Void).null
      end
    end

    # Destroys only the application windows: destroying every toplevel
    # double-frees input method windows (fcitx).
    private def quit_now : Nil
      return if @application.null?
      windows = [] of Void*
      Native.each(C.gtk_application_get_windows(@application)) { |window| windows << window }
      windows.each { |window| C.gtk_window_destroy(window) }
      C.g_application_quit(@application)
    end

    private def reload_now : Nil
      return if @application.null?
      Systemd.reloading
      begin
        on_reload
      ensure
        Systemd.ready
      end
    end

    private def load_css : Nil
      C.gtk_css_provider_load_from_string(@provider, @css) unless @provider.null?
    end

    private def apply_appearance : Nil
      scheme = case @appearance
               in .system? then C::AdwColorScheme::Default
               in .light?  then C::AdwColorScheme::ForceLight
               in .dark?   then C::AdwColorScheme::ForceDark
               end
      C.adw_style_manager_set_color_scheme(C.adw_style_manager_get_default, scheme)
    end

    private def color_scheme_changed : Nil
      dark = C.adw_style_manager_get_dark(C.adw_style_manager_get_default) != 0
      on_color_scheme(dark ? ColorScheme::Dark : ColorScheme::Light)
    end

    private def css_error(section : Void*, error : Void*) : Nil
      location = Native.take_string?(C.gtk_css_section_to_string(section))
      message = Native.string?(error.as(C::GError*).value.message)
      Log.warn { "css parsing failed at #{location}: #{message}" }
    end
  end
end
