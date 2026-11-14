# src/under_test.cr
#
# The apprt app the live tests run: one window of labels with key
# sequences, a key table, progress, tab, split and header bindings, and
# with --global the global Ctrl+Alt+Shift+F9, which opens a tab. It
# reports through LIVETEST_FIFO, and on standard error:
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
#
#   apprt-under-test --class ID  runs under the harness with window class ID
#   apprt-under-test --global    also binds the global shortcut
#   apprt-under-test --setup     installs the app's desktop file and binds the
#                                shortcut once, which the desktop confirms
require "option_parser"
require "apprt"

lib LibGtk
  fun gtk_label_new(text : UInt8*) : Void*
  fun gtk_native_get_surface(native : Void*) : Void*
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
  }

  # The key table `mode`.
  MODE = {
    "x"      => Report.new("table"),
    "Escape" => Action::DeactivateKeyTable.new,
  }

  class UnderTest < Apprt::App
    getter? failed = false

    # The kind each surface's content was opened as.
    @kinds = {} of Apprt::Content => String

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
      bindings = BINDINGS.map { |keys, action| Apprt::Binding.new(keys, action) }
      bindings << Apprt::Binding.new(TRIGGER, Apprt::Action::NewTab.new, global: true) if @global || @setup
      self.bindings = bindings
      self.key_tables = {"mode" => MODE.map { |keys, action| Apprt::Binding.new(keys, action) }}
    end

    protected def on_activate : Nil
      window = new_window
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
      text = @setup ? "Confirm the shortcut in the desktop's dialog, then press #{TRIGGER.label}." : context.kind.to_s
      content = Apprt::WidgetContent.new(Apprt::Widget.new(LibGtk.gtk_label_new(text)))
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

    private def report(line : String) : Nil
      STDERR.puts line
      fifo = ENV["LIVETEST_FIFO"]? || return
      File.open(fifo, "a", &.puts(line))
    end
  end
end

window_class = nil.as(String?)
global = false
setup = false
OptionParser.parse do |parser|
  parser.banner = "Usage: apprt-under-test [--class ID] [--global] | --setup"
  parser.on("--class ID", "Runs under the harness with window class ID") { |id| window_class = id }
  parser.on("--global", "Also binds the global shortcut") { global = true }
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
app = Apprt::Test::UnderTest.new(window_class, global, setup)
status = app.run
exit(app.failed? ? 1 : status)
