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
