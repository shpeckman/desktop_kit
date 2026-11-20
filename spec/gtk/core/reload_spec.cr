# spec/gtk/core/reload_spec.cr
require "../harness"

# Content that records its reloads in the app's events; *broken* content
# raises instead.
class ReloadContent < DesktopKit::WidgetContent
  def initialize(@app : TestApp, @broken : Bool = false)
    super(DesktopKit::Widget.new(DesktopKit::C.gtk_entry_new))
  end

  protected def on_reload : Nil
    raise "broken content" if @broken
    @app.record "content #{surface.id}"
  end
end

describe "DesktopKit::App#reload" do
  before_all { GtkHarness.start }

  it "reloads the content of every surface after the app" do
    app = TestApp.new
    app.make_content = ->(context : DesktopKit::SurfaceContext) { ReloadContent.new(app).as(DesktopKit::Content) }
    run_steps(app) do
      window = app.new_window
      first = window.active_surface.not_nil!
      second = window.new_tab.active_surface.not_nil!
      third = second.split(:right)
      app.reload
      app.events.last(4).should eq ["reload", "content #{first.id}", "content #{second.id}", "content #{third.id}"]
    end
  end

  it "reloads the other contents when one raises" do
    app = TestApp.new
    broken = true
    app.make_content = ->(context : DesktopKit::SurfaceContext) do
      content = ReloadContent.new(app, broken)
      broken = false
      content.as(DesktopKit::Content)
    end
    run_steps(app) do
      window = app.new_window
      second = window.active_surface.not_nil!.split(:down)
      app.reload
      app.events.last(2).should eq ["reload", "content #{second.id}"]
    end
  end

  it "reloads the content on SIGUSR2 before it reports ready to systemd" do
    with_notify_socket do |socket|
      app = TestApp.new
      app.make_content = ->(context : DesktopKit::SurfaceContext) { ReloadContent.new(app).as(DesktopKit::Content) }
      id = 0_u64
      app.on_activated = ->(app : TestApp) do
        id = app.new_window.active_surface.not_nil!.id
        Process.signal(Signal::USR2, Process.pid)
      end
      app.on_reloaded = ->(_app : TestApp) { Process.signal(Signal::TERM, Process.pid) }
      run_app(app).should eq 0
      app.events.should eq ["startup", "scheme light", "activate", "reload", "content #{id}", "shutdown"]
      messages = notifications(socket)
      messages[1].should start_with "RELOADING=1\n"
      messages[2..].should eq ["READY=1", "STOPPING=1"]
    end
  end
end
