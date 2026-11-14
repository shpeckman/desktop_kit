# spec/gtk/harness.cr
require "file_utils"
require "../spec_helper"

# Private display and session bus for the GTK specs: gtk4-broadwayd renders
# headless, and a dbus-daemon of its own keeps GApplication off the user's
# session bus.
module GtkHarness
  @@dir : String?
  @@processes = [] of Process

  def self.start : Nil
    return if @@dir
    dir = File.tempname("apprt-spec")
    Dir.mkdir(dir, 0o700)
    @@dir = dir
    port = TCPServer.open("127.0.0.1", 0, &.local_address.port)
    @@processes << Process.new("gtk4-broadwayd", ["-p", port.to_s, "-a", "127.0.0.1", ":0"],
      env: {"XDG_RUNTIME_DIR" => dir}, output: :close, error: :close)
    @@processes << Process.new("dbus-daemon", ["--session", "--nofork", "--address=unix:path=#{dir}/bus"],
      output: :close, error: :close)
    sockets = {"#{dir}/broadway1.socket", "#{dir}/bus"}
    1000.times do
      break if sockets.all? { |socket| File.exists?(socket) }
      sleep 10.milliseconds
    end
    raise "GtkHarness: gtk4-broadwayd or dbus-daemon did not start" unless sockets.all? { |socket| File.exists?(socket) }
    {
      "XDG_RUNTIME_DIR"          => dir,
      "DBUS_SESSION_BUS_ADDRESS" => "unix:path=#{dir}/bus",
      "GDK_BACKEND"              => "broadway",
      "BROADWAY_DISPLAY"         => ":0",
      "ADW_DISABLE_PORTAL"       => "1",
      "GDK_DEBUG"                => "no-portals",
      "GTK_A11Y"                 => "none",
      "GSETTINGS_BACKEND"        => "memory",
      "XDG_CONFIG_HOME"          => "#{dir}/config",
    }.each { |name, value| ENV[name] = value }
  end

  def self.stop : Nil
    @@processes.each do |process|
      process.terminate
      process.wait
    end
    @@processes.clear
    @@dir.try { |dir| FileUtils.rm_rf(dir) }
    @@dir = nil
  end
end

Spec.after_suite { GtkHarness.stop }

module AppIds
  @@count = 0

  def self.next : String
    @@count += 1
    "org.example.ApprtSpec.App#{@@count}"
  end
end

# Application that records its hooks; it quits on activation unless
# *on_activated* is replaced.
class TestApp < Apprt::App
  getter events = [] of String
  getter? off_thread = false
  property on_activated : TestApp -> = ->(app : TestApp) { app.quit }
  property on_reloaded : TestApp -> = ->(app : TestApp) { }
  property on_scheme : TestApp -> = ->(app : TestApp) { }

  def initialize(id : String = AppIds.next, *, single_instance : Bool = false)
    super(id, single_instance: single_instance)
  end

  # Without windows or a hold, GApplication quits as soon as it is idle.
  protected def on_startup : Nil
    record "startup"
    Apprt::C.g_application_hold(to_unsafe)
  end

  protected def on_activate : Nil
    record "activate"
    on_activated.call(self)
  end

  protected def on_reload : Nil
    record "reload"
    on_reloaded.call(self)
  end

  protected def on_color_scheme(scheme : Apprt::ColorScheme) : Nil
    record "scheme #{scheme.to_s.downcase}"
    on_scheme.call(self)
  end

  protected def on_shutdown : Nil
    record "shutdown"
  end

  def record(event : String) : Nil
    @off_thread = true unless Apprt::UIThread.current? && Thread.current.name == "gtk"
    @events << event
  end
end

# Runs *app* and quits it when it still runs after *timeout*.
def run_app(app : TestApp, timeout : Time::Span = 10.seconds) : Int32
  done = Atomic(Bool).new(false)
  spawn do
    sleep timeout
    app.quit unless done.get
  end
  app.run.tap { done.set(true) }
end
