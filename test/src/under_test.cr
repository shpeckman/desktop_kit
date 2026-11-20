# src/under_test.cr
#
# The apprt app the live tests run: one window of labels with key
# sequences, a key table, progress, tab, split, header, pane header,
# offloading and threaded canvas, search, panel, shortcuts dialog, about
# dialog, sequence timeout and tray bindings, a context menu on every
# label, and with --global the global Ctrl+Alt+Shift+F9, which opens a
# tab. With --dutch the built-in texts the header menu shows are in Dutch.
# Closing the window closes its panels. It reports through LIVETEST_FIFO,
# and on standard error:
#
#   window                     its window is open
#   tab                        a tab opened
#   unbound TRIGGER: REASON    the desktop refused the global binding
#   NAME tables=T,...          the binding reporting NAME fired; T are the
#                              key tables active when it ran
#   progress PERCENT           the surface shows PERCENT, or none when -1
#   surfaces K,...             the tab's surfaces from the left or top, by
#                              the kind each was opened as
#   header tabs                the tab bar moved into the header bar
#   pane headers               every surface shows its pane header
#   canvas dmabuf=BOOL         the canvas tab showed its first frame, as a
#                              DMA-BUF when BOOL is true
#   canvas threaded            the threaded canvas tab showed its first frame
#   timeout MS                 pending key sequences now expire after MS
#   tray registered=BOOL       the tray icon is shown; BOOL is true when the
#                              desktop's StatusNotifierWatcher lists it
#   search NEEDLE              the search text changed to NEEDLE; every
#                              label matches three times
#   navigate next|previous     the search moved to the next or previous match
#   search end                 the search bar closed
#   panel shown=BOOL           the quick panel opened or toggled, or was
#                              asked about
#   dock clear=BOOL            a bottom dock opened; BOOL is true when a
#                              left panel that respects reserved space lost
#                              exactly the dock's height
#
#   apprt-under-test --class ID  runs under the harness with window class ID
#   apprt-under-test --global    also binds the global shortcut
#   apprt-under-test --dutch     shows the header menu's texts in Dutch
#   apprt-under-test --setup     installs the app's desktop file and binds the
#                                shortcut once, which the desktop confirms
require "option_parser"
require "apprt"

lib LibGtk
  fun gtk_label_new(text : UInt8*) : Void*
  fun gtk_native_get_surface(native : Void*) : Void*
  fun gtk_settings_get_default : Void*
  fun g_object_set(object : Void*, property : UInt8*, ...)
end

@[Link("GL")]
lib LibGL
  COLOR_BUFFER_BIT = 0x4000_u32
  SCISSOR_TEST     = 0x0C11_u32

  fun glClearColor(red : Float32, green : Float32, blue : Float32, alpha : Float32)
  fun glClear(mask : UInt32)
  fun glEnable(cap : UInt32)
  fun glDisable(cap : UInt32)
  fun glScissor(x : Int32, y : Int32, width : Int32, height : Int32)
end

lib LibGdkWayland
  fun gdk_wayland_toplevel_set_application_id(toplevel : Void*, application_id : UInt8*) : Void
end

module Apprt::Test
  # The application id, also the basename of the desktop file the portal
  # and the taskbar need to know the app.
  APP_ID = "org.example.ApprtLive"

  # The global binding under test.
  TRIGGER = Apprt::Trigger.parse("ctrl+alt+shift+F9")

  # Reports *line* and the window's key tables.
  Apprt.action Report, "report", scope: :window, payload: {line: String}

  # Shows *percent* as the surface's progress; -1 clears it.
  Apprt.action ShowProgress, "show-progress", scope: :split, payload: {percent: Int32}

  # Reports the tab's surfaces in order.
  Apprt.action ReportSurfaces, "report-surfaces", scope: :tab

  # Moves the tab bar into the header bar.
  Apprt.action HeaderTabs, "header-tabs", scope: :app

  # Shows a pane header on every surface.
  Apprt.action PaneHeaders, "pane-headers", scope: :app

  # Opens a tab whose content is a `Halves` canvas: rendering on its own
  # thread when *threaded*, else offloading.
  Apprt.action OpenCanvas, "open-canvas", scope: :window, payload: {threaded: Bool}

  # Lets pending key sequences expire after `SEQUENCE_TIMEOUT`.
  Apprt.action SequenceTimeout, "sequence-timeout", scope: :app

  # Shows the about dialog.
  Apprt.action ShowAbout, "show-about", scope: :window

  # Shows the tray icon and reports whether the desktop registered it.
  Apprt.action ShowTray, "show-tray", scope: :app

  # Opens the quick panel the first time, toggles it after that.
  Apprt.action QuickPanel, "quick-panel", scope: :app

  # Reports whether the quick panel is shown.
  Apprt.action ReportPanel, "report-panel", scope: :app

  # Opens a bottom dock and checks the space it reserves.
  Apprt.action DockPanel, "dock-panel", scope: :app

  # The quick panel: a drop-down above other windows that hides when it
  # loses the focus.
  QUICK = Apprt::Panel.new(edge: :top, height: 200, layer: :overlay,
    hide_on_focus_loss: true, name: "quick")

  # The dock `DockPanel` opens, and the left panel whose height shows
  # the space the dock reserves.
  DOCK  = Apprt::Panel.new(edge: :bottom, height: 160, name: "dock")
  PROBE = Apprt::Panel.new(edge: :left, width: 60, exclusive_zone: 0, name: "probe")

  # The window bindings under test. `ctrl+t` is a plain window shortcut
  # that `ctrl+a>ctrl+t` must win over while the sequence is pending.
  BINDINGS = {
    "ctrl+t"         => Report.new("accel"),
    "ctrl+a>n"       => Report.new("sequence"),
    "ctrl+a>ctrl+t"  => Report.new("capture"),
    "ctrl+a>e"       => Action::ActivateKeyTable.new("mode"),
    "ctrl+a>o"       => Action::ActivateKeyTableOnce.new("mode"),
    "ctrl+a>p"       => ShowProgress.new(40),
    "ctrl+a>shift+p" => ShowProgress.new(-1),
    "ctrl+a>t"       => Action::NewTab.new,
    "ctrl+a>s"       => Action::NewSplit.new(:right),
    "ctrl+a>l"       => ReportSurfaces.new,
    "ctrl+a>h"       => HeaderTabs.new,
    "ctrl+a>m"       => PaneHeaders.new,
    "ctrl+a>c"       => OpenCanvas.new(false),
    "ctrl+a>g"       => OpenCanvas.new(true),
    "ctrl+a>w"       => SequenceTimeout.new,
    "ctrl+a>k"       => Action::ShowShortcuts.new,
    "ctrl+a>i"       => ShowAbout.new,
    "ctrl+a>y"       => ShowTray.new,
    "ctrl+a>f"       => Action::StartSearch.new,
    "ctrl+a>q"       => QuickPanel.new,
    "ctrl+a>v"       => ReportPanel.new,
    "ctrl+a>b"       => DockPanel.new,
  }

  # The key table `mode`.
  MODE = {
    "x"      => Report.new("table"),
    "Escape" => Action::DeactivateKeyTable.new,
  }

  # How long a pending key sequence waits once `SequenceTimeout` ran.
  SEQUENCE_TIMEOUT = 300.milliseconds

  # The about dialog `ShowAbout` shows.
  ABOUT = Apprt::About.new("apprt live test", version: "1.0", icon: "applications-system-symbolic",
    developer: "apprt", comments: "The app the apprt live tests run", license: :mit)

  # The tray icon `ShowTray` shows; its menu opens a window.
  TRAY = Apprt::Tray.new(icon: "applications-system-symbolic", title: "apprt live test",
    menu: Apprt::Menu.build { |menu| menu.item "New Window", Action::NewWindow.new })

  # The Dutch texts of the header menu, for `--dutch`. The longest label
  # keeps the menu an even number of pixels wide: KWin and sway round a
  # centered popup's half pixel apart.
  DUTCH = {
    "Main Menu"            => "Hoofdmenu",
    "New Window"           => "Nieuw venster",
    "New Tab"              => "Nieuw tabblad",
    "Split Up"             => "Boven splitsen",
    "Split Down"           => "Onder splitsen",
    "Split Left"           => "Links splitsen",
    "Split Right"          => "Rechts splitsen",
    "Change Title…"        => "Titel wijzigen…",
    "Change Tab Title…"    => "Tabnaam wijzigen…",
    "Change Window Title…" => "Venstertitel…",
    "Close Tab"            => "Tabblad sluiten",
    "Close Window"         => "Venster sluiten",
    "Keyboard Shortcuts"   => "Sneltoetsen",
  }

  # The context menu of every label.
  CONTEXT_MENU = Apprt::Menu.build do |menu|
    menu.item "Report", Report.new("context")
    menu.item "Split Right", Action::NewSplit.new(:right)
  end

  # Reports *line* on standard error and to the harness's fifo.
  def self.report(line : String) : Nil
    STDERR.puts line
    fifo = ENV["LIVETEST_FIFO"]? || return
    File.open(fifo, "a", &.puts(line))
  end

  # Canvas that clears its upper half red and its lower half blue, and
  # reports how its first frame reached the screen. It renders on its own
  # thread when *threaded*, else it offloads.
  class Halves < Apprt::Canvas
    @reported = false

    def initialize(@threaded : Bool)
      super(offload: !threaded, threaded: threaded)
    end

    protected def on_render : Nil
      LibGL.glClearColor(1.0, 0.0, 0.0, 1.0)
      LibGL.glClear(LibGL::COLOR_BUFFER_BIT)
      LibGL.glEnable(LibGL::SCISSOR_TEST)
      LibGL.glScissor(0, 0, width, height // 2)
      LibGL.glClearColor(0.0, 0.0, 1.0, 1.0)
      LibGL.glClear(LibGL::COLOR_BUFFER_BIT)
      LibGL.glDisable(LibGL::SCISSOR_TEST)
    end

    protected def on_presented(timing : Apprt::FrameTiming) : Nil
      return if @reported
      @reported = true
      Test.report(@threaded ? "canvas threaded" : "canvas dmabuf=#{dmabuf?}")
    end
  end

  # A label that reports its search and matches every needle three times.
  class Label < Apprt::WidgetContent
    MATCHES = 3

    @selected = 0

    def initialize(text : String)
      super(Apprt::Widget.new(LibGtk.gtk_label_new(text)))
    end

    protected def context_menu(x : Float64, y : Float64) : Apprt::Menu?
      CONTEXT_MENU
    end

    protected def on_search(needle : String) : Nil
      @selected = 0
      surface.search_total = needle.empty? ? nil : MATCHES
      surface.search_selected = needle.empty? ? nil : @selected
      Test.report "search #{needle}"
    end

    protected def on_search_navigate(forward : Bool) : Nil
      @selected = (@selected + (forward ? 1 : -1)) % MATCHES
      surface.search_selected = @selected
      Test.report "navigate #{forward ? "next" : "previous"}"
    end

    protected def on_search_end : Nil
      Test.report "search end"
    end
  end

  class UnderTest < Apprt::App
    getter? failed = false

    # The kind each surface's content was opened as.
    @kinds = {} of Apprt::Content => String

    # Whether the next surface is a `Halves` canvas, and whether it renders
    # on its own thread.
    @canvas = false
    @threaded = false

    # The quick panel once `QuickPanel` opened it.
    @quick : Apprt::Window?

    # Runs with *window_class* as the Wayland app id of its window when
    # given; *global* binds the global shortcut; *setup* waits for the
    # first activation of the global binding and then quits.
    def initialize(@window_class : String?, @global : Bool, @setup : Bool)
      super(APP_ID, single_instance: false)
    end

    # Writes the desktop file for this executable and refreshes KDE's
    # service cache; returns the desktop file's path.
    def self.install_desktop_file : String
      data = ENV["XDG_DATA_HOME"]? || File.join(Path.home.to_s, ".local", "share")
      file = File.join(data, "applications", "#{APP_ID}.desktop")
      Dir.mkdir_p(File.dirname(file))
      File.write(file, <<-DESKTOP)
        [Desktop Entry]
        Type=Application
        Name=apprt live test
        Comment=The app the apprt live tests run
        Exec=#{Process.executable_path || PROGRAM_NAME}
        NoDisplay=true

        DESKTOP
      Process.run("kbuildsycoca6", output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
      file
    end

    protected def on_startup : Nil
      # A blinking caret would make shots of the search bar differ.
      LibGtk.g_object_set(LibGtk.gtk_settings_get_default, "gtk-cursor-blink", 0, Pointer(Void).null)
      bindings = BINDINGS.map { |keys, action| Apprt::Binding.new(keys, action) }
      bindings << Apprt::Binding.new(TRIGGER, Apprt::Action::NewTab.new, global: true) if @global || @setup
      self.bindings = bindings
      self.key_tables = {"mode" => MODE.map { |keys, action| Apprt::Binding.new(keys, action) }}
    end

    protected def on_activate : Nil
      window = new_window
      close_panels_with(window)
      # GTK gives the window the application id at realize, which
      # new_window did; the harness finds the window by its own id.
      @window_class.try do |id|
        LibGdkWayland.gdk_wayland_toplevel_set_application_id(LibGtk.gtk_native_get_surface(window.widget), id)
      end
      report "window"
    end

    protected def new_surface(context : Apprt::SurfaceContext) : Apprt::Content
      if context.kind.tab?
        report "tab"
        if @setup
          STDERR.puts "#{TRIGGER.label} is bound."
          quit
        end
      end
      if @canvas
        @canvas = false
        return Halves.new(@threaded)
      end
      text = @setup ? "Confirm the shortcut in the desktop's dialog, then press #{TRIGGER.label}." : context.kind.to_s
      content = Label.new(text)
      @kinds[content] = context.kind.to_s.downcase
      content
    end

    protected def on_binding_failed(binding : Apprt::Binding, message : String) : Nil
      @failed = true
      report "unbound #{binding.trigger}: #{message}"
      quit if @setup
    end

    protected def perform(target : Apprt::Window, action : Report) : Bool
      report "#{action.line} tables=#{target.key_tables.join(',')}"
      true
    end

    protected def perform(target : Apprt::Surface, action : ShowProgress) : Bool
      target.progress = action.percent < 0 ? nil : Apprt::Progress.new(action.percent / 100)
      report "progress #{action.percent}"
      true
    end

    protected def perform(target : Apprt::Tab, action : ReportSurfaces) : Bool
      report "surfaces #{target.surfaces.join(',') { |surface| @kinds[surface.content]? }}"
      true
    end

    protected def perform(target : Apprt::App, action : HeaderTabs) : Bool
      self.window_style = Apprt::WindowStyle.new(tabs_in_header: true)
      report "header tabs"
      true
    end

    protected def perform(target : Apprt::App, action : PaneHeaders) : Bool
      self.window_style = Apprt::WindowStyle.new(pane_headers: true)
      report "pane headers"
      true
    end

    protected def perform(target : Apprt::Window, action : OpenCanvas) : Bool
      @canvas = true
      @threaded = action.threaded
      perform(target, Apprt::Action::NewTab.new)
    end

    protected def perform(target : Apprt::App, action : SequenceTimeout) : Bool
      self.sequence_timeout = SEQUENCE_TIMEOUT
      report "timeout #{SEQUENCE_TIMEOUT.total_milliseconds.to_i}"
      true
    end

    protected def perform(target : Apprt::Window, action : ShowAbout) : Bool
      target.show_about(ABOUT)
      true
    end

    # Shows the tray, then asks the watcher after a second, when the
    # registration had time to arrive.
    protected def perform(target : Apprt::App, action : ShowTray) : Bool
      self.tray = TRAY
      after(1.second) { report_tray }
      true
    end

    protected def perform(target : Apprt::App, action : QuickPanel) : Bool
      if @quick
        perform(target, Apprt::Action::TogglePanel.new(QUICK.name))
      else
        @quick = new_panel(QUICK)
      end
      report_panel
      true
    end

    protected def perform(target : Apprt::App, action : ReportPanel) : Bool
      report_panel
      true
    end

    protected def perform(target : Apprt::App, action : DockPanel) : Bool
      probe = new_panel(PROBE)
      after(500.milliseconds) do
        before = probe.widget.height
        new_panel(DOCK)
        after(1.second) { report "dock clear=#{before - probe.widget.height == DOCK.height}" }
      end
      true
    end

    # Closes every panel once *window* closed, so the app quits; apprt has
    # no hook for a closed window, so this checks every 100 ms.
    private def close_panels_with(window : Apprt::Window) : Nil
      after(100.milliseconds) do
        if window.closed?
          windows.select(&.panel).each(&.close)
        else
          close_panels_with(window)
        end
      end
    end

    private def report_tray : Nil
      bus = dbus || return report "tray registered=false"
      args = Apprt::Variant.new({"org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems"})
      bus.call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.freedesktop.DBus.Properties", "Get", args) do |reply, _error|
        items = reply.try(&.[0].get(Apprt::Variant).get(Array(String))) || [] of String
        report "tray registered=#{items.any?(&.starts_with?(bus.unique_name))}"
      end
    end

    private def report_panel : Nil
      report "panel shown=#{@quick.try(&.widget.visible?) || false}"
    end

    private def report(line : String) : Nil
      Test.report(line)
    end
  end
end

window_class = nil.as(String?)
global = false
dutch = false
setup = false
OptionParser.parse do |parser|
  parser.banner = "Usage: apprt-under-test [--class ID] [--global] | --setup"
  parser.on("--class ID", "Runs under the harness with window class ID") { |id| window_class = id }
  parser.on("--global", "Also binds the global shortcut") { global = true }
  parser.on("--dutch", "Shows the header menu's texts in Dutch") { dutch = true }
  parser.on("--setup", "Installs the desktop file and binds the shortcut once") { setup = true }
  parser.invalid_option do |flag|
    STDERR.puts "apprt-under-test: unknown option #{flag}\n#{parser}"
    exit 2
  end
end

if setup
  STDERR.puts "Installed #{Apprt::Test::UnderTest.install_desktop_file}."
  STDERR.puts "Confirm the shortcut in the desktop's dialog, then press #{Apprt::Test::TRIGGER.label}."
end
Apprt.translator = ->(text : String) { Apprt::Test::DUTCH.fetch(text, text) } if dutch
app = Apprt::Test::UnderTest.new(window_class, global, setup)
status = app.run
exit(app.failed? ? 1 : status)
