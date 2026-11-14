# spec/gtk/surface_dialogs_spec.cr
require "./harness"

private def dialog(window : Apprt::Window) : Void*
  Apprt::C.adw_application_window_get_visible_dialog(window.widget)
end

private def heading(window : Apprt::Window) : String?
  dialog = dialog(window)
  Apprt::Native.string?(Apprt::C.adw_alert_dialog_get_heading(dialog)) unless dialog.null?
end

# Closes the visible dialog of *window* with *response*.
private def respond(window : Apprt::Window, response : String) : Nil
  dialog = dialog(window)
  dialog.null?.should be_false
  Apprt::C.adw_alert_dialog_set_close_response(dialog, response)
  Apprt::C.adw_dialog_force_close(dialog)
  settle
end

describe "Surface#confirm_clipboard" do
  before_all { GtkHarness.start }

  it "asks before a paste and yields the answer" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      answers = [] of Bool
      surface.confirm_clipboard(:paste, "rm -rf ~\n") { |allowed| answers << allowed }
      settle
      heading(window).should eq "Warning: Potentially Unsafe Paste"
      respond(window, "ok")
      answers.should eq [true]

      surface.confirm_clipboard(:read, "secret") { |allowed| answers << allowed }
      settle
      heading(window).should eq "Authorize Clipboard Access"
      respond(window, "cancel")
      answers.should eq [true, false]

      surface.confirm_clipboard(:write, "copied") { |allowed| answers << allowed }
      settle
      heading(window).should eq "Authorize Clipboard Access"
      respond(window, "cancel")
      answers.should eq [true, false, false]
    end
  end

  it "denies for a closed surface" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      other = surface.split(:right)
      settle
      surface.close
      eventually { surface.closed? }.should be_true
      answers = [] of Bool
      surface.confirm_clipboard(:paste, "text") { |allowed| answers << allowed }
      answers.should eq [false]
      dialog(window).null?.should be_true
      other.closed?.should be_false
    end
  end
end

# Runs *block* on an idle after the first activation, when configuration
# errors show.
private def run_activated(app : TestApp, &block : TestApp ->) : Nil
  failure = nil.as(Exception?)
  app.on_activated = ->(app : TestApp) do
    Apprt::Idle.add do
      block.call(app)
    rescue ex
      failure = ex
    ensure
      app.quit
    end
    nil
  end
  run_app(app).should eq 0
  failure.try { |ex| raise ex }
end

describe "App#config_errors" do
  before_all { GtkHarness.start }

  it "shows, updates and closes the errors dialog" do
    run_activated(TestApp.new) do |app|
      window = app.new_window
      settle
      app.config_errors = ["line 3: unknown key \"colour\""]
      settle
      heading(window).should eq "Configuration Errors"
      shown = dialog(window)

      app.config_errors = ["line 3: unknown key \"colour\"", "line 9: bad value"]
      settle
      dialog(window).should eq shown
      app.config_errors.size.should eq 2

      app.config_errors = [] of String
      eventually { dialog(window).null? }.should be_true
    end
  end

  it "reloads on request and stays closed on ignore" do
    run_activated(TestApp.new) do |app|
      window = app.new_window
      settle
      app.config_errors = ["line 1: oops"]
      settle
      respond(window, "ignore")
      app.events.should_not contain "reload"
      dialog(window).null?.should be_true

      app.config_errors = ["line 1: oops"]
      settle
      respond(window, "reload")
      app.events.should contain "reload"
    end
  end

  it "shows errors set before the run once the application activates" do
    app = TestApp.new
    app.config_errors = ["line 2: missing value"]
    shown = nil.as(String?)
    app.on_activated = ->(app : TestApp) do
      window = app.new_window
      Apprt::Idle.add do
        settle
        shown = heading(window)
        app.quit
      end
      nil
    end
    run_app(app).should eq 0
    shown.should eq "Configuration Errors"
  end
end

describe "Surface#show_on_screen_keyboard" do
  before_all { GtkHarness.start }

  it "is refused by content without an input method" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      surface.show_on_screen_keyboard.should be_false
      trigger(window, Apprt::Action::ShowOnScreenKeyboard.new)
    end
  end
end
