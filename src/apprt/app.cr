# src/apprt/app.cr
module Apprt
  # Base of an application: subclass it, return the content of new surfaces
  # from `#new_surface`, override the hooks it needs and call `#run`.
  #
  # ```
  # class Hello < Apprt::App
  #   protected def new_surface(context)
  #     # A widget from the application's own GTK bindings.
  #     Apprt::WidgetContent.new(Apprt::Widget.new(LibGtk.gtk_label_new("Hello")))
  #   end
  #
  #   protected def on_activate
  #     new_window
  #   end
  # end
  #
  # exit Hello.new("org.example.Hello").run
  # ```
  #
  # `#run` drives GTK on a thread of its own. The hooks and actions run on
  # that thread. `#quit`, `#reload`, `#post`, `#css=` and `#appearance=` are
  # callable from any thread; the window and surface methods only from the
  # GTK thread. One application runs at a time.
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
    @windows = [] of Window
    @tabs = {} of Void* => Tab
    @surfaces = {} of UInt64 => Surface

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

    # Opens a window with one tab, from *parent* when given, presents it and
    # returns it. Raises `RuntimeError` off the GTK thread.
    def new_window(parent : Surface? = nil) : Window
      UIThread.assert!
      window = open_window
      window.open_tab(:window, parent)
      window.present
      window
    end

    # Returns the open windows, oldest first.
    def windows : Array(Window)
      @windows.dup
    end

    # Returns the window the user last focused, or `nil` when no window is
    # open.
    def active_window : Window?
      return if @application.null?
      active = C.gtk_application_get_active_window(@application)
      @windows.find { |window| window.widget.to_unsafe == active } || @windows.last?
    end

    # Returns the active surface of `#active_window`.
    def active_surface : Surface?
      active_window.try(&.active_surface)
    end

    # Returns the open surface with *id*.
    def surface(id : UInt64) : Surface?
      @surfaces[id]?
    end

    # :nodoc:
    # The GApplication, null unless `#run` is in progress.
    def to_unsafe : Void*
      @application
    end

    # :showdoc:
    #
    # Returns the content of a new surface; *context* tells where it opens.
    #
    # Each call must return a new `Content`.
    protected abstract def new_surface(context : SurfaceContext) : Content

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

    # :showdoc:
    #
    # Carries out *action* on *target* and returns whether it was handled.
    #
    # *target* is the application for application actions, the `Window` for
    # window actions, the `Tab` for tab actions and the `Surface` for split
    # actions.
    #
    # Each action type has its own overload; define one for each action the
    # application declares, or redefine a built-in one. The overload with an
    # unrestricted *action* handles nothing.
    protected def perform(target, action : Action) : Bool
      false
    end

    protected def perform(target : App, action : Action::Quit) : Bool
      confirm_close(:app) { quit_now }
      true
    end

    protected def perform(target : App, action : Action::NewWindow) : Bool
      new_window(active_surface)
      true
    end

    protected def perform(target : App, action : Action::CloseAllWindows) : Bool
      confirm_close(:windows) { destroy_windows }
      true
    end

    # Calls `#perform`, so that the overloads of subclasses apply.
    protected def dispatch(target, action : Action) : Bool
      perform(target, action)
    end

    protected def open_window : Window
      window = Window.new(self)
      @windows << window
      window
    end

    protected def create_surface(kind : SurfaceContext::Kind, parent : Surface?) : Surface
      surface = Surface.new(self, new_surface(SurfaceContext.new(kind, parent)))
      @surfaces[surface.id] = surface
      surface
    end

    protected def register(tab : Tab) : Nil
      @tabs[tab.root.to_unsafe] = tab
    end

    protected def unregister(window : Window) : Nil
      @windows.delete(window)
    end

    protected def unregister(tab : Tab) : Nil
      @tabs.delete(tab.root.to_unsafe)
    end

    protected def unregister(surface : Surface) : Nil
      @surfaces.delete(surface.id)
    end

    # Returns the tab whose page shows *child*.
    protected def tab_for(child : Void*) : Tab?
      @tabs[child]?
    end

    protected def tabs : Array(Tab)
      @tabs.values
    end

    protected def perform(target : App, action : Action::ReloadConfig) : Bool
      reload_now
      true
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
      register_with_portal
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
      Action.install(@application, :app) { |action| perform(self, action) }
      start_global_shortcuts
      apply_bindings
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
      @global_shortcuts.try(&.release)
      @global_shortcuts = nil
      @windows.clear
      @tabs.clear
      @surfaces.clear
      Signals.disconnect(C.adw_style_manager_get_default, @dark_handler) unless @dark_handler == 0
      @dark_handler = 0_u64
      unless @provider.null?
        C.gtk_style_context_remove_provider_for_display(C.gdk_display_get_default, @provider)
        C.g_object_unref(@provider)
        @provider = Pointer(Void).null
      end
    end

    private def quit_now : Nil
      return if @application.null?
      destroy_windows
      C.g_application_quit(@application)
    end

    # Runs *block* once the user confirms closing *kind*, or right away when
    # no surface asks for a confirmation.
    private def confirm_close(kind : Dialogs::Close, &block : ->) : Nil
      window = active_window
      if window && @surfaces.each_value.any?(&.confirm_close?)
        Dialogs.confirm_close(window.widget, kind) { |confirmed| block.call if confirmed }
      else
        block.call
      end
    end

    # Destroys only the application windows: destroying every toplevel
    # double-frees input method windows (fcitx).
    private def destroy_windows : Nil
      @windows.dup.each(&.destroy)
      windows = [] of Void*
      Native.each(C.gtk_application_get_windows(@application)) { |window| windows << window }
      windows.each { |window| C.gtk_window_destroy(window) }
    end

    private def reload_now : Nil
      return if @application.null?
      Systemd.reloading
      begin
        on_reload
        @surfaces.each_value do |surface|
          surface.content.reload
        rescue ex
          Log.error(exception: ex) { "content reload" }
        end
      ensure
        Systemd.ready
      end
    end

    # Tells the desktop portal the application id before GTK makes its own
    # portal calls on the session bus: a process outside a sandbox or an
    # application scope has none the portal can find.
    private def register_with_portal : Nil
      error = Pointer(C::GError).null
      bus = C.g_bus_get_sync(C::GBusType::Session, Pointer(Void).null, pointerof(error))
      if bus.null?
        Log.debug { "session bus: #{GLibError.take(error).message}" } unless error.null?
        return
      end
      Portal.register(bus, @id)
      C.g_object_unref(bus)
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
