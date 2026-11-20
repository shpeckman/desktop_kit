# spec/gtk/harness.cr
require "file_utils"
require "../spec_helper"

# Private display and session bus for the GTK specs: a headless sway is the
# Wayland compositor, and a dbus-daemon of its own keeps GApplication off the
# user's session bus.
#
# Specs drive controllers by emitting their signals (`g_signal_emit_by_name`)
# rather than through input devices: headless sway has no keyboard or
# pointer, so windows never become active, no real drag happens (drop hooks
# are unspecced) and the user is idle at once.
module GtkHarness
  # Windows float at their own size instead of tiling.
  private SWAY_CONFIG = <<-SWAY
    xwayland disable
    output HEADLESS-1 resolution 1280x800 scale 1
    for_window [app_id=".*"] floating enable
    SWAY

  # A session bus without service directories: calls to names nobody owns,
  # such as the desktop portal, fail instead of starting the host's services.
  private def self.bus_config(dir : String) : String
    <<-XML
      <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
        "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
      <busconfig>
        <type>session</type>
        <listen>unix:path=#{dir}/bus</listen>
        <auth>EXTERNAL</auth>
        <policy context="default">
          <allow send_destination="*" eavesdrop="true"/>
          <allow eavesdrop="true"/>
          <allow own="*"/>
        </policy>
      </busconfig>
      XML
  end

  @@dir : String?
  @@processes = [] of Process

  def self.start : Nil
    return if @@dir
    dir = File.tempname("desktop-kit-spec")
    Dir.mkdir(dir, 0o700)
    @@dir = dir
    File.write("#{dir}/sway.conf", SWAY_CONFIG)
    File.write("#{dir}/bus.conf", bus_config(dir))
    # A real compositor, not broadway: the canvas needs GL, and a process
    # gets only one GDK backend.
    sway_env = {
      "XDG_RUNTIME_DIR"         => dir,
      "WLR_BACKENDS"            => "headless",
      "WLR_RENDERER"            => "pixman",
      "WLR_LIBINPUT_NO_DEVICES" => "1",
      "WAYLAND_DISPLAY"         => nil,
      "DISPLAY"                 => nil,
    }
    @@processes << Process.new("sway", ["-c", "#{dir}/sway.conf"], env: sway_env, output: :close, error: :close)
    @@processes << Process.new("dbus-daemon", ["--config-file=#{dir}/bus.conf", "--nofork"], output: :close, error: :close)
    display = nil.as(String?)
    1000.times do
      display = Dir.children(dir).find { |name| name.starts_with?("wayland-") && !name.ends_with?(".lock") }
      break if display && File.exists?("#{dir}/bus")
      sleep 10.milliseconds
    end
    raise "GtkHarness: sway or dbus-daemon did not start" unless display && File.exists?("#{dir}/bus")
    ENV.delete("DISPLAY")
    # `gtk_init` calls `setlocale`, hence no `LANGUAGE` and `LC_ALL` C.UTF-8
    # below: translated accelerator labels leaked into later pure `Trigger`
    # specs.
    ENV.delete("LANGUAGE")
    {
      "LC_ALL"                   => "C.UTF-8",
      "XDG_RUNTIME_DIR"          => dir,
      "WAYLAND_DISPLAY"          => display,
      "DBUS_SESSION_BUS_ADDRESS" => "unix:path=#{dir}/bus",
      "GDK_BACKEND"              => "wayland",
      # GL renderer only: the threaded canvas crash that only GSK's Vulkan
      # renderer triggers is covered by the live `threaded-canvas` case.
      "GSK_RENDERER" => "ngl",
      "GDK_DISABLE"  => "vulkan",
      # GIO notifications go to `FakeNotifications`.
      "GNOTIFICATION_BACKEND" => "freedesktop",
      "ADW_DISABLE_PORTAL"    => "1",
      # Without portals GTK inhibits logout through
      # `org.gnome.SessionManager` (faked in `logout_inhibit_spec.cr`). GDK
      # caches portal versions per process, so this must hold for all specs.
      "GDK_DEBUG" => "no-portals",
      "GTK_A11Y"  => "none",
      # GStreamer's GL display outlives the stream and floods "Failed to flush
      # Wayland connection" once sway stops; bell sounds therefore fail and
      # specs check only the warning.
      "GTK_MEDIA"         => "none",
      "GSETTINGS_BACKEND" => "memory",
      "XDG_CONFIG_HOME"   => "#{dir}/config",
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
    "org.example.DesktopKitSpec.App#{@@count}"
  end
end

# Application that records its hooks; it quits on activation unless
# *on_activated* is replaced.
class TestApp < DesktopKit::App
  getter events = [] of String
  getter? off_thread = false
  property on_activated : TestApp -> = ->(app : TestApp) { app.quit }
  property on_reloaded : TestApp -> = ->(app : TestApp) { }
  property on_scheme : TestApp -> = ->(app : TestApp) { }
  getter contexts = [] of DesktopKit::SurfaceContext
  # Makes the content of new surfaces; a text entry by default.
  property make_content : DesktopKit::SurfaceContext -> DesktopKit::Content = ->(context : DesktopKit::SurfaceContext) do
    DesktopKit::WidgetContent.new(DesktopKit::Widget.new(DesktopKit::C.gtk_entry_new)).as(DesktopKit::Content)
  end

  # Closed surfaces are released at once unless a spec sets
  # `#undo_timeout`, so `#closed?` holds right after closing.
  def initialize(id : String = AppIds.next, *, single_instance : Bool = false)
    super(id, single_instance: single_instance)
    self.undo_timeout = Time::Span.zero
  end

  # Without windows or a hold, GApplication quits as soon as it is idle.
  protected def on_startup : Nil
    record "startup"
    DesktopKit::C.g_application_hold(to_unsafe)
  end

  protected def new_surface(context : DesktopKit::SurfaceContext) : DesktopKit::Content
    @contexts << context
    make_content.call(context)
  end

  protected def on_activate : Nil
    record "activate"
    on_activated.call(self)
  end

  protected def on_reload : Nil
    record "reload"
    on_reloaded.call(self)
  end

  protected def on_color_scheme(scheme : DesktopKit::ColorScheme) : Nil
    record "scheme #{scheme.to_s.downcase}"
    on_scheme.call(self)
  end

  protected def on_shutdown : Nil
    record "shutdown"
  end

  def record(event : String) : Nil
    @off_thread = true unless DesktopKit::UIThread.current? && Thread.current.name == "gtk"
    @events << event
  end
end

# Runs *app* with *arguments* and quits it when it still runs after
# *timeout*.
def run_app(app : TestApp, timeout : Time::Span = 10.seconds, arguments : Array(String) = [] of String) : Int32
  done = Atomic(Bool).new(false)
  spawn do
    sleep timeout
    app.quit unless done.get
  end
  app.run(arguments).tap { done.set(true) }
end

# Runs *block* once *app* activates, then quits it; re-raises what *block*
# raised.
def run_steps(app : TestApp, &block : TestApp ->) : Nil
  failure = nil.as(Exception?)
  app.on_activated = ->(app : TestApp) do
    begin
      block.call(app)
    rescue ex
      failure = ex
    ensure
      app.quit
    end
  end
  run_app(app).should eq 0
  failure.try { |ex| raise ex }
end

# Runs the GTK main loop for *duration*, so that idle callbacks, layout and
# dialog responses happen.
def settle(duration : Time::Span = 200.milliseconds) : Nil
  deadline = Time.instant + duration
  while Time.instant < deadline
    DesktopKit::C.g_main_context_iteration(Pointer(Void).null, 0)
    sleep 1.millisecond
  end
end

# Runs the GTK main loop until *condition* holds or *timeout* passes, and
# returns whether it holds: layout and drawing wait for the frame clock.
def eventually(timeout : Time::Span = 5.seconds, &condition : -> Bool) : Bool
  deadline = Time.instant + timeout
  until condition.call
    return false if Time.instant >= deadline
    DesktopKit::C.g_main_context_iteration(Pointer(Void).null, 0)
    sleep 1.millisecond
  end
  true
end

# Triggers *action* from *window*, as its menu and shortcuts do.
def trigger(window : DesktopKit::Window, action : DesktopKit::Action) : Nil
  parameter = action.to_variant.try(&.to_unsafe) || Pointer(Void).null
  name = "#{action.scope.prefix}.#{action.name}"
  DesktopKit::C.gtk_widget_activate_action_variant(window.widget, name, parameter).should eq 1
  settle
end
