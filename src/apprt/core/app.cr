# src/apprt/core/app.cr
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

    # How long the application keeps running after its last window closes;
    # nil keeps it running until `#quit`.
    getter quit_delay : Time::Span? = Time::Span.zero

    @@current = Atomic(App?).new(nil)

    @application = Pointer(Void).null
    # Every `app` action; windows insert it as their `app` group, hiding the
    # GApplication's, which holds only the ipc actions it exports on D-Bus.
    @actions = Pointer(Void).null
    @provider = Pointer(Void).null
    @runtime_style = Pointer(Void).null
    @dark_handler = 0_u64
    @running = Atomic(Bool).new(false)
    @ready = false
    @windows = [] of Window
    @tabs = {} of Void* => Tab
    @surfaces = {} of UInt64 => Surface
    @holding = false
    @quit_timer = 0_u32

    # Creates the application with *id*; raises `ArgumentError` when *id* is not
    # a valid application id.
    def initialize(@id : String, *, @single_instance : Bool = true)
      raise ArgumentError.new("invalid application id: #{id.inspect}") if C.g_application_id_is_valid(id) == 0
    end

    # Runs the application until `#quit` or until `#quit_delay` after its last
    # window closes, and returns its exit status.
    #
    # *arguments*, without the program name, go to `#on_command_line`: of
    # this process, or of the instance already running when the application
    # is a single instance. In the latter case `#run` returns the exit status
    # that instance's `#on_command_line` returned.
    #
    # Blocks the calling fiber. Until it returns, SIGINT and SIGTERM call
    # `#quit` and SIGUSR2 calls `#reload`. Raises `RuntimeError` when an
    # application is already running.
    #
    # ```
    # exit Editor.new("org.example.Editor").run(ARGV)
    # ```
    def run(arguments : Enumerable(String) = [] of String) : Int32
      raise RuntimeError.new("an application is already running") unless @@current.compare_and_set(nil, self)[1]
      status = 0
      begin
        Signal::INT.trap { quit }
        Signal::TERM.trap { quit }
        Signal::USR2.trap { reload }
        arguments = arguments.to_a
        # New "gtk" thread per run; GTK and the default GMainContext survive
        # across runs.
        Fiber::ExecutionContext::Isolated.new("gtk") { status = UIThread.enter { run_application(arguments) } }.wait
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

    # Closes the application windows and quits at the next main loop
    # iteration; `#run` then returns 0. Does nothing unless the application
    # is running.
    def quit : Nil
      # Always post, even on the UI thread: inline from `new_surface` it
      # destroyed the window mid-`Window#open_tab` (ADW_IS_TAB_VIEW assertion).
      UIThread.post { quit_now } if running?
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

    # Runs *block* on the GTK thread once *delay* passed and returns its
    # `Source`. Raises `RuntimeError` off the GTK thread.
    def after(delay : Time::Span, &block : ->) : Source
      UIThread.assert!
      Source.timer(delay, &block)
    end

    # Calls *block* on the GTK thread with the conditions of *fd* whenever
    # one of *conditions* holds, until the returned `Source` is cancelled.
    #
    # Errors, hang-ups and a closed descriptor are reported whatever
    # *conditions* holds; a closed descriptor also ends the watch. Raises
    # `RuntimeError` off the GTK thread.
    def watch(fd : Int32, conditions : Source::Condition = :read, &block : Source::Condition ->) : Source
      UIThread.assert!
      Source.watch(fd, conditions, &block)
    end

    # :ditto:
    def watch(io : IO::FileDescriptor, conditions : Source::Condition = :read, &block : Source::Condition ->) : Source
      watch(io.fd, conditions, &block)
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

    # Sets how long the application keeps running once its last window
    # closes: zero quits right away, nil never.
    #
    # Opening a window before *delay* passes keeps the application running.
    def quit_delay=(delay : Time::Span?) : Time::Span?
      @quit_delay = delay
      UIThread.dispatch { apply_quit_delay } if running?
      delay
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
    # Called when the application is launched without files, and again
    # whenever it is launched so while running as a single instance.
    protected def on_activate : Nil
    end

    # :showdoc:
    #
    # Called on each launch with its *command_line*, the arguments `#run`
    # received, and returns the launch's exit status.
    #
    # By default it opens the arguments as files with `#on_open`, or calls
    # `#on_activate` when there are none.
    protected def on_command_line(command_line : CommandLine) : Int32
      files = command_line.arguments.map { |argument| command_line.path(argument) }
      files.empty? ? activate : on_open(files)
      0
    end

    # :showdoc:
    #
    # Called with *files* to open, from `#on_command_line` or from the
    # desktop; calls `#on_activate` by default.
    protected def on_open(files : Array(Path)) : Nil
      on_activate
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
    # Called with each new window before it is shown, to add widgets or
    # buttons to its header bar.
    protected def on_window(window : Window) : Nil
    end

    # :showdoc:
    #
    # Called when the desktop stops showing *window* (*suspended*), such as
    # on another workspace or minimized, and when it shows it again.
    protected def on_window_suspended(window : Window, suspended : Bool) : Nil
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
      # Other Apprt types can't call protected `perform` of a user subclass
      # defined outside Apprt ("protected method 'perform' called for Hello"):
      # they call this wrapper, which uses an implicit receiver.
      perform(target, action)
    end

    # Returns the group of every `app` action, for windows to insert.
    protected getter actions : Void*

    protected def open_window(panel : Panel? = nil) : Window
      stop_quit_timer
      @session_saved = false
      window = Window.new(self, panel)
      @windows << window
      on_window(window)
      window
    end

    protected def window_suspended(window : Window, suspended : Bool) : Nil
      # Protected wrapper: Window can't call the user's protected hook.
      on_window_suspended(window, suspended)
    end

    protected def create_surface(kind : SurfaceContext::Kind, parent : Surface?, session_state : String? = nil) : Surface
      surface = Surface.new(self, new_surface(SurfaceContext.new(kind, parent, session_state)))
      @surfaces[surface.id] = surface
      surface
    end

    protected def register(tab : Tab) : Nil
      @tabs[tab.root.to_unsafe] = tab
    end

    protected def unregister(window : Window) : Nil
      @windows.delete(window)
      return unless @windows.empty? && running?
      save_session unless window.panel
      start_quit_timer
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

    @exit_status : Int32? = nil

    private def run_application(arguments : Array(String)) : Int32
      flags = C::GApplicationFlags::HandlesOpen | C::GApplicationFlags::HandlesCommandLine
      flags |= C::GApplicationFlags::NonUnique unless single_instance?
      @application = C.adw_application_new(@id, flags)
      Signals.connect(@application, "startup", -> { startup })
      Signals.connect(@application, "activate", -> { activate })
      Signals.connect(@application, "command-line", ->(command_line : Void*) : Int32 { command_line(command_line) })
      Signals.connect(@application, "open", ->(files : Void*, count : Int32, _hint : String?) { open(files, count) })
      Signals.connect(@application, "shutdown", -> { shutdown })
      # Without main options GApplication passes unknown options through to
      # the command line handler.
      argv = Native.strv([PROGRAM_NAME].concat(arguments))
      register_with_portal
      # GLib 2.84 g_application_run resets status = 0 each loop iteration:
      # a local launch's status comes back through @exit_status.
      @exit_status = nil
      status = C.g_application_run(@application, argv.size - 1, argv.to_unsafe)
      @exit_status || status
    ensure
      C.g_object_unref(@application) unless @application.null?
      @application = Pointer(Void).null
    end

    private def startup : Nil
      @ready = false
      @session_saved = false
      @provider = C.gtk_css_provider_new
      Signals.connect(@provider, "parsing-error", ->(section : Void*, error : Void*) { css_error(section, error) })
      C.gtk_style_context_add_provider_for_display(C.gdk_display_get_default, @provider, C::STYLE_PROVIDER_PRIORITY_USER)
      @runtime_style = C.gtk_css_provider_new
      load_runtime_style
      C.gtk_style_context_add_provider_for_display(C.gdk_display_get_default, @runtime_style, C::STYLE_PROVIDER_PRIORITY_APPLICATION)
      # Before load_css/apply_appearance: mutators act only while running.
      @running.set(true)
      @actions = C.g_simple_action_group_new
      Action.install(@actions, :app) { |action| perform(self, action) }
      Action.install(@application, :app, ipc_only: true) { |action| perform(self, action) }
      start_global_shortcuts
      apply_bindings
      apply_key_tables
      load_css
      apply_appearance
      apply_quit_delay
      watch_user_idle
      # Appearance applied before connecting: no double on_color_scheme.
      @dark_handler = Signals.notify(C.adw_style_manager_get_default, "dark", -> { color_scheme_changed })
      on_startup
      sync_tray
      color_scheme_changed
    end

    # Restores the saved session on the first activation when
    # `#restore_session?`, else calls `#on_activate`.
    private def activate : Nil
      on_activate unless !@ready && restore_session? && Session.restore(self)
    ensure
      became_ready
    end

    # Returns the launch's exit status; a remote launch gets it through
    # *command_line*. GApplication drops a local launch's status once its
    # main loop runs, so `#run_application` returns `@exit_status`.
    private def command_line(command_line : Void*) : Int32
      launch = CommandLine.from(command_line)
      on_command_line(launch).tap do |status|
        C.g_application_command_line_set_exit_status(command_line, status)
        @exit_status = status unless launch.remote?
      end
    ensure
      became_ready
    end

    # Opens the `GFile`s the desktop asked for; files without a local path
    # are skipped.
    private def open(files : Void*, count : Int32) : Nil
      paths = Slice.new(files.as(Void**), count).compact_map do |file|
        Native.take_string?(C.g_file_get_path(file)).try { |path| Path[path] }
      end
      on_open(paths)
    ensure
      became_ready
    end

    # Marks the end of the first launch: systemd hears the application is
    # ready and the configuration errors show.
    private def became_ready : Nil
      return if @ready
      @ready = true
      Systemd.ready
      sync_config_errors
    end

    private def shutdown : Nil
      # First: mutators called from now on only store.
      @running.set(false)
      Systemd.stopping
      on_shutdown
    ensure
      @global_shortcuts.try(&.release)
      @global_shortcuts = nil
      release_open_uri
      release_user_idle
      release_logout_inhibit
      release_tray
      Source.cancel_all
      # before the registries: releasing closed surfaces unregisters them
      undo_stack.clear
      stop_quit_timer
      @holding = false
      release_bell_sound
      forget_config_errors_dialog
      @windows.clear
      @tabs.clear
      @surfaces.clear
      unless @actions.null?
        C.g_object_unref(@actions)
        @actions = Pointer(Void).null
      end
      Signals.disconnect(C.adw_style_manager_get_default, @dark_handler) unless @dark_handler == 0
      @dark_handler = 0_u64
      unless @provider.null?
        C.gtk_style_context_remove_provider_for_display(C.gdk_display_get_default, @provider)
        C.g_object_unref(@provider)
        @provider = Pointer(Void).null
      end
      unless @runtime_style.null?
        C.gtk_style_context_remove_provider_for_display(C.gdk_display_get_default, @runtime_style)
        C.g_object_unref(@runtime_style)
        @runtime_style = Pointer(Void).null
      end
    end

    # Holds the application while it should outlive its windows, and
    # restarts the quit timer for the new delay when no window is open.
    private def apply_quit_delay : Nil
      hold = @quit_delay != Time::Span.zero
      stop_quit_timer
      start_quit_timer if @ready && @windows.empty?
      return if hold == @holding
      @holding = hold
      hold ? C.g_application_hold(@application) : C.g_application_release(@application)
    end

    private def start_quit_timer : Nil
      delay = @quit_delay
      return unless delay && delay.positive? && @quit_timer == 0
      @quit_timer = Idle.after(delay) do
        @quit_timer = 0_u32
        quit_now
      end
    end

    private def stop_quit_timer : Nil
      return if @quit_timer == 0
      Idle.cancel(@quit_timer)
      @quit_timer = 0_u32
    end

    private def quit_now : Nil
      return if @application.null?
      save_session
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
