# spec/gtk/app_spec.cr
require "./harness"

private module AppIds
  @@count = 0

  def self.next : String
    @@count += 1
    "org.example.ApprtSpec.App#{@@count}"
  end
end

private class TestApp < Apprt::App
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

  private def record(event : String) : Nil
    @off_thread = true unless Apprt::UIThread.current? && Thread.current.name == "gtk"
    @events << event
  end
end

# Runs *app* and quits it when it still runs after *timeout*.
private def run_app(app : TestApp, timeout : Time::Span = 10.seconds) : Int32
  done = Atomic(Bool).new(false)
  spawn do
    sleep timeout
    app.quit unless done.get
  end
  app.run.tap { done.set(true) }
end

private LIFECYCLE = ["startup", "scheme light", "activate", "shutdown"]

describe Apprt::App do
  before_all { GtkHarness.start }

  it "rejects an invalid application id" do
    expect_raises(ArgumentError, %(invalid application id: "no dots")) { TestApp.new("no dots") }
  end

  it "runs its hooks on the GTK thread and returns 0 when it quits" do
    app = TestApp.new(single_instance: true)
    app.running?.should be_false
    run_app(app).should eq 0
    app.events.should eq LIFECYCLE
    app.off_thread?.should be_false
    app.running?.should be_false
  end

  it "ignores quit and reload before it runs" do
    app = TestApp.new
    app.quit
    app.reload
    run_app(app).should eq 0
    app.events.should eq LIFECYCLE
  end

  it "runs posted blocks in order on the GTK thread and logs their exceptions" do
    app = TestApp.new
    app.on_activated = ->(_app : TestApp) { }
    order = [] of String
    app.post { order << "first on #{Thread.current.name}" }
    app.post { raise "boom" }
    app.post { order << "second"; app.quit }
    Log.capture("apprt") do |logs|
      run_app(app).should eq 0
      logs.check(:error, "posted block")
      logs.entry.exception.try(&.message).should eq "boom"
    end
    order.should eq ["first on gtk", "second"]
  end

  it "quits when asked from another thread" do
    app = TestApp.new
    app.on_activated = ->(app : TestApp) { spawn { app.quit } }
    run_app(app).should eq 0
    app.events.should eq LIFECYCLE
  end

  it "reloads on SIGUSR2, quits on SIGTERM and reports each state to systemd" do
    with_notify_socket do |socket|
      app = TestApp.new
      app.on_activated = ->(_app : TestApp) { Process.signal(Signal::USR2, Process.pid) }
      app.on_reloaded = ->(_app : TestApp) { Process.signal(Signal::TERM, Process.pid) }
      run_app(app).should eq 0
      app.events.should eq ["startup", "scheme light", "activate", "reload", "shutdown"]
      messages = notifications(socket)
      messages.size.should eq 4
      messages[0].should eq "READY=1"
      messages[1].should match /\ARELOADING=1\nMONOTONIC_USEC=\d+\z/
      messages[2..].should eq ["READY=1", "STOPPING=1"]
    end
  end

  it "reports the color scheme of the requested appearance" do
    app = TestApp.new
    app.appearance = :dark
    app.on_activated = ->(app : TestApp) { app.appearance = :light }
    app.on_scheme = ->(app : TestApp) { app.quit if app.events.last == "scheme light" }
    run_app(app).should eq 0
    app.events.should eq ["startup", "scheme dark", "activate", "scheme light", "shutdown"]
    app.appearance.should eq Apprt::Appearance::Light
  end

  it "logs style sheet errors" do
    app = TestApp.new
    app.css = "window { colr: red; }"
    app.on_activated = ->(app : TestApp) { app.css = "label { margin: wide; }"; app.quit }
    Log.capture("apprt") do |logs|
      run_app(app).should eq 0
      logs.check(:warn, /\Acss parsing failed at .+: .+/)
      logs.check(:warn, /\Acss parsing failed at .+: .+/)
    end
    app.css.should eq "label { margin: wide; }"
  end

  it "refuses to run while another application runs" do
    app = TestApp.new
    message = nil
    app.on_activated = ->(app : TestApp) do
      begin
        TestApp.new.run
      rescue ex : RuntimeError
        message = ex.message
      end
      app.quit
    end
    run_app(app).should eq 0
    message.should eq "an application is already running"
  end

  it "guards the GTK thread" do
    expect_raises(RuntimeError, "GTK called outside the UI thread") { Apprt::UIThread.assert! }
    app = TestApp.new
    asserted = false
    app.on_activated = ->(app : TestApp) { Apprt::UIThread.assert!; asserted = true; app.quit }
    run_app(app).should eq 0
    asserted.should be_true
  end
end
