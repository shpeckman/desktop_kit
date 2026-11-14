# src/under_test.cr
#
# The apprt app the live tests run: one window of labels whose only binding
# is the global Ctrl+Alt+Shift+F9, which opens a tab. It reports through
# LIVETEST_FIFO, and on standard error:
#
#   window                     its window is open
#   tab                        the global binding opened a tab
#   unbound TRIGGER: REASON    the desktop refused the global binding
#
#   apprt-under-test --class ID  runs under the harness with window class ID
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
  # needs to know the app.
  APP_ID = "org.example.ApprtLive"

  # The global binding under test.
  TRIGGER = Apprt::Trigger.parse("ctrl+alt+shift+F9")

  class UnderTest < Apprt::App
    getter? failed = false

    # Runs with *window_class* as the Wayland app id of its window when
    # given; *setup* waits for the first activation of the global binding
    # and then quits.
    def initialize(@window_class : String?, @setup : Bool)
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
      self.bindings = [Apprt::Binding.new(TRIGGER, Apprt::Action::NewTab.new, global: true)]
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
      Apprt::WidgetContent.new(Apprt::Widget.new(LibGtk.gtk_label_new(text)))
    end

    protected def on_binding_failed(binding : Apprt::Binding, message : String) : Nil
      @failed = true
      report "unbound #{binding.trigger}: #{message}"
      quit if @setup
    end

    private def report(line : String) : Nil
      STDERR.puts line
      fifo = ENV["LIVETEST_FIFO"]? || return
      File.open(fifo, "a", &.puts(line))
    end
  end
end

window_class = nil.as(String?)
setup = false
OptionParser.parse do |parser|
  parser.banner = "Usage: apprt-under-test [--class ID | --setup]"
  parser.on("--class ID", "Runs under the harness with window class ID") { |id| window_class = id }
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
app = Apprt::Test::UnderTest.new(window_class, setup)
status = app.run
exit(app.failed? ? 1 : status)
