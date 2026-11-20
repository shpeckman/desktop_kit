# src/under_test.cr
#
# The desktop_kit app the live tests run: one window of labels with key
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
#   desktop-kit-under-test --class ID  runs under the harness with window class ID
#   desktop-kit-under-test --global    also binds the global shortcut
#   desktop-kit-under-test --dutch     shows the header menu's texts in Dutch
#   desktop-kit-under-test --setup     installs the app's desktop file and binds the
#                                shortcut once, which the desktop confirms
require "option_parser"
require "desktop_kit"

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

module DesktopKit::Test
  # The application id, also the basename of the desktop file the portal
  # and the taskbar need to know the app.
  #
  # Fixed rather than livetest's `livetest-<pid>-<n>` class: a GApplication
  # id needs a dot, and the portal and kglobalaccel need a stable id. The
  # portal accepts `Registry.Register` only for an id naming an installed
  # desktop file; without one xdg-desktop-portal-kde names the kglobalaccel
  # component after the session token (`token_desktop_kit_<hex>` in
  # `~/.config/kglobalshortcutsrc`), new each run, and asks again each time.
  APP_ID = "org.example.DesktopKitLive"

  # The global binding under test.
  TRIGGER = DesktopKit::Trigger.parse("ctrl+alt+shift+F9")

  # Reports *line* and the window's key tables.
  DesktopKit.action Report, "report", scope: :window, payload: {line: String}

  # Shows *percent* as the surface's progress; -1 clears it.
  DesktopKit.action ShowProgress, "show-progress", scope: :split, payload: {percent: Int32}

  # Reports the tab's surfaces in order.
  DesktopKit.action ReportSurfaces, "report-surfaces", scope: :tab

  # Moves the tab bar into the header bar.
  DesktopKit.action HeaderTabs, "header-tabs", scope: :app

  # Shows a pane header on every surface.
  DesktopKit.action PaneHeaders, "pane-headers", scope: :app

  # Opens a tab whose content is a `Halves` canvas: rendering on its own
  # thread when *threaded*, else offloading.
  DesktopKit.action OpenCanvas, "open-canvas", scope: :window, payload: {threaded: Bool}

  # Lets pending key sequences expire after `SEQUENCE_TIMEOUT`.
  DesktopKit.action SequenceTimeout, "sequence-timeout", scope: :app

  # Shows the about dialog.
  DesktopKit.action ShowAbout, "show-about", scope: :window

  # Shows the tray icon and reports whether the desktop registered it.
  DesktopKit.action ShowTray, "show-tray", scope: :app

  # Opens the quick panel the first time, toggles it after that.
  DesktopKit.action QuickPanel, "quick-panel", scope: :app

  # Reports whether the quick panel is shown.
  DesktopKit.action ReportPanel, "report-panel", scope: :app

  # Opens a bottom dock and checks the space it reserves.
  DesktopKit.action DockPanel, "dock-panel", scope: :app

  # The quick panel: a drop-down above other windows that hides when it
  # loses the focus.
  QUICK = DesktopKit::Panel.new(edge: :top, height: 200, layer: :overlay,
    hide_on_focus_loss: true, name: "quick")

  # The dock `DockPanel` opens, and the left panel whose height shows
  # the space the dock reserves.
  DOCK  = DesktopKit::Panel.new(edge: :bottom, height: 160, name: "dock")
  PROBE = DesktopKit::Panel.new(edge: :left, width: 60, exclusive_zone: 0, name: "probe")

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
  ABOUT = DesktopKit::About.new("desktop_kit live test", version: "1.0", icon: "applications-system-symbolic",
    developer: "desktop_kit", comments: "The app the desktop_kit live tests run", license: :mit)

  # The tray icon `ShowTray` shows; its menu opens a window.
  TRAY = DesktopKit::Tray.new(icon: "applications-system-symbolic", title: "desktop_kit live test",
    menu: DesktopKit::Menu.build { |menu| menu.item "New Window", Action::NewWindow.new })

  # The Dutch texts of the header menu, for `--dutch`. The longest label
  # keeps the menu an even number of pixels wide: KWin and sway round a
  # centered popup's half pixel apart (208 px; odd widths fail in kde).
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
  CONTEXT_MENU = DesktopKit::Menu.build do |menu|
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
  class Halves < DesktopKit::Canvas
    @reported = false

    def initialize(@threaded : Bool)
      super(offload: !threaded, threaded: threaded)
    end

    protected def on_render : Nil
      # Red over blue in GL coordinates (rows start at the bottom), so a
      # frame shown unflipped is caught.
      LibGL.glClearColor(1.0, 0.0, 0.0, 1.0)
      LibGL.glClear(LibGL::COLOR_BUFFER_BIT)
      LibGL.glEnable(LibGL::SCISSOR_TEST)
      LibGL.glScissor(0, 0, width, height // 2)
      LibGL.glClearColor(0.0, 0.0, 1.0, 1.0)
      LibGL.glClear(LibGL::COLOR_BUFFER_BIT)
      LibGL.glDisable(LibGL::SCISSOR_TEST)
    end

    protected def on_presented(timing : DesktopKit::FrameTiming) : Nil
      return if @reported
      @reported = true
      Test.report(@threaded ? "canvas threaded" : "canvas dmabuf=#{dmabuf?}")
    end
  end

  # A label that reports its search and matches every needle three times.
  class Label < DesktopKit::WidgetContent
    MATCHES = 3

    # Labels are not focusable: the window's first button keeps the focus,
    # and its focus ring is part of the shots.

    @selected = 0

    def initialize(text : String)
      super(DesktopKit::Widget.new(LibGtk.gtk_label_new(text)))
    end

    protected def context_menu(x : Float64, y : Float64) : DesktopKit::Menu?
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

  class UnderTest < DesktopKit::App
    getter? failed = false

    # The kind each surface's content was opened as: `ReportSurfaces` names
    # surfaces by it, so a drop's new order shows.
    @kinds = {} of DesktopKit::Content => String

    # Whether the next surface is a `Halves` canvas, and whether it renders
    # on its own thread.
    @canvas = false
    @threaded = false

    # The quick panel once `QuickPanel` opened it.
    @quick : DesktopKit::Window?

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
        Name=desktop_kit live test
        Comment=The app the desktop_kit live tests run
        Exec=#{Process.executable_path || PROGRAM_NAME}
        NoDisplay=true

        DESKTOP
      Process.run("kbuildsycoca6", output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
      file
    end

    protected def on_startup : Nil
      # A blinking caret would make shots of the search bar differ.
      LibGtk.g_object_set(LibGtk.gtk_settings_get_default, "gtk-cursor-blink", 0, Pointer(Void).null)
      bindings = BINDINGS.map { |keys, action| DesktopKit::Binding.new(keys, action) }
      # Only --global and --setup bind: a nested sway shares the session bus
      # and would reach the real desktop's portal. Plasma 6.4+ asks in a
      # dialog for unbound shortcuts, so --setup binds once; still every
      # start calls `BindShortcuts`, which xdg-desktop-portal-kde 6.7.4+
      # needs to activate the stored shortcut.
      bindings << DesktopKit::Binding.new(TRIGGER, DesktopKit::Action::NewTab.new, global: true) if @global || @setup
      self.bindings = bindings
      self.key_tables = {"mode" => MODE.map { |keys, action| DesktopKit::Binding.new(keys, action) }}
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

    protected def new_surface(context : DesktopKit::SurfaceContext) : DesktopKit::Content
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

    protected def on_binding_failed(binding : DesktopKit::Binding, message : String) : Nil
      @failed = true
      report "unbound #{binding.trigger}: #{message}"
      quit if @setup
    end

    protected def perform(target : DesktopKit::Window, action : Report) : Bool
      # The active key tables ride along, so `expect` proves both the
      # binding and the table it came from.
      report "#{action.line} tables=#{target.key_tables.join(',')}"
      true
    end

    protected def perform(target : DesktopKit::Surface, action : ShowProgress) : Bool
      target.progress = action.percent < 0 ? nil : DesktopKit::Progress.new(action.percent / 100)
      report "progress #{action.percent}"
      true
    end

    protected def perform(target : DesktopKit::Tab, action : ReportSurfaces) : Bool
      report "surfaces #{target.surfaces.join(',') { |surface| @kinds[surface.content]? }}"
      true
    end

    protected def perform(target : DesktopKit::App, action : HeaderTabs) : Bool
      self.window_style = DesktopKit::WindowStyle.new(tabs_in_header: true)
      report "header tabs"
      true
    end

    protected def perform(target : DesktopKit::App, action : PaneHeaders) : Bool
      self.window_style = DesktopKit::WindowStyle.new(pane_headers: true)
      report "pane headers"
      true
    end

    protected def perform(target : DesktopKit::Window, action : OpenCanvas) : Bool
      @canvas = true
      @threaded = action.threaded
      perform(target, DesktopKit::Action::NewTab.new)
    end

    protected def perform(target : DesktopKit::App, action : SequenceTimeout) : Bool
      self.sequence_timeout = SEQUENCE_TIMEOUT
      report "timeout #{SEQUENCE_TIMEOUT.total_milliseconds.to_i}"
      true
    end

    protected def perform(target : DesktopKit::Window, action : ShowAbout) : Bool
      target.show_about(ABOUT)
      true
    end

    # Shows the tray, then asks the watcher after a second, when the
    # registration had time to arrive.
    protected def perform(target : DesktopKit::App, action : ShowTray) : Bool
      self.tray = TRAY
      after(1.second) { report_tray }
      true
    end

    protected def perform(target : DesktopKit::App, action : QuickPanel) : Bool
      if @quick
        perform(target, DesktopKit::Action::TogglePanel.new(QUICK.name))
      else
        @quick = new_panel(QUICK)
      end
      report_panel
      true
    end

    protected def perform(target : DesktopKit::App, action : ReportPanel) : Bool
      report_panel
      true
    end

    protected def perform(target : DesktopKit::App, action : DockPanel) : Bool
      probe = new_panel(PROBE)
      after(500.milliseconds) do
        before = probe.widget.height
        new_panel(DOCK)
        after(1.second) { report "dock clear=#{before - probe.widget.height == DOCK.height}" }
      end
      true
    end

    # Closes every panel once *window* closed, so the app quits; desktop_kit has
    # no hook for a closed window, so this checks every 100 ms.
    private def close_panels_with(window : DesktopKit::Window) : Nil
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
      args = DesktopKit::Variant.new({"org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems"})
      bus.call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.freedesktop.DBus.Properties", "Get", args) do |reply, _error|
        items = reply.try(&.[0].get(DesktopKit::Variant).get(Array(String))) || [] of String
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
  parser.banner = "Usage: desktop-kit-under-test [--class ID] [--global] | --setup"
  parser.on("--class ID", "Runs under the harness with window class ID") { |id| window_class = id }
  parser.on("--global", "Also binds the global shortcut") { global = true }
  parser.on("--dutch", "Shows the header menu's texts in Dutch") { dutch = true }
  parser.on("--setup", "Installs the desktop file and binds the shortcut once") { setup = true }
  parser.invalid_option do |flag|
    STDERR.puts "desktop-kit-under-test: unknown option #{flag}\n#{parser}"
    exit 2
  end
end

if setup
  STDERR.puts "Installed #{DesktopKit::Test::UnderTest.install_desktop_file}."
  STDERR.puts "Confirm the shortcut in the desktop's dialog, then press #{DesktopKit::Test::TRIGGER.label}."
end
# Before `App.new`: built-in defaults (`Menu.window`) translate at init.
DesktopKit.translator = ->(text : String) { DesktopKit::Test::DUTCH.fetch(text, text) } if dutch
app = DesktopKit::Test::UnderTest.new(window_class, global, setup)
status = app.run
exit(app.failed? ? 1 : status)
