# spec/gtk/quit_delay_spec.cr
require "./harness"

# A test app without the harness's hold, so it quits as configured.
private class UnheldApp < TestApp
  protected def on_startup : Nil
    record "startup"
  end
end

# Runs *app*, which opens and closes a window on activation and calls
# *after_close* right after; returns the time from the close to the end of
# the run.
private def close_and_wait(app : UnheldApp, &after_close : UnheldApp ->) : Time::Span
  closed_at = Time.instant
  app.on_activated = ->(app : TestApp) do
    window = app.new_window
    settle
    closed_at = Time.instant
    window.close
    after_close.call(app.as(UnheldApp))
  end
  run_app(app).should eq 0
  Time.instant - closed_at
end

describe "App#quit_delay" do
  before_all { GtkHarness.start }

  it "quits right away by default" do
    app = UnheldApp.new
    app.quit_delay.should eq Time::Span.zero
    close_and_wait(app) { }.should be < 2.seconds
  end

  it "keeps running for the delay after the last window closes" do
    app = UnheldApp.new
    app.quit_delay = 400.milliseconds
    alive = false
    elapsed = close_and_wait(app) do |app|
      Apprt::Idle.after(200.milliseconds) { alive = app.running? }
    end
    alive.should be_true
    elapsed.should be >= 400.milliseconds
    elapsed.should be < 5.seconds
  end

  it "keeps running when a window opens before the delay passes" do
    app = UnheldApp.new
    app.quit_delay = 300.milliseconds
    windows = -1
    close_and_wait(app) do |app|
      Apprt::Idle.after(100.milliseconds) { app.new_window }
      Apprt::Idle.after(700.milliseconds) do
        windows = app.windows.size
        app.quit
      end
    end
    windows.should eq 1
  end

  it "keeps running without windows until quit when nil" do
    app = UnheldApp.new
    app.quit_delay = nil
    alive = false
    close_and_wait(app) do |app|
      Apprt::Idle.after(500.milliseconds) do
        alive = app.running? && app.windows.empty?
        app.quit
      end
    end
    alive.should be_true
  end

  it "quits once the delay drops to zero without windows" do
    app = UnheldApp.new
    app.quit_delay = nil
    elapsed = close_and_wait(app) do |app|
      Apprt::Idle.after(200.milliseconds) { app.quit_delay = Time::Span.zero }
    end
    elapsed.should be >= 200.milliseconds
    elapsed.should be < 5.seconds
  end
end
