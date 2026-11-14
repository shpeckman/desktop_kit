# spec/gtk/window_actions_spec.cr
require "./harness"

lib WindowActionsSpecLib
  fun gtk_window_set_default_size(window : Void*, width : Int32, height : Int32)
  fun gtk_window_get_default_size(window : Void*, width : Int32*, height : Int32*)
  fun gtk_widget_has_css_class(widget : Void*, name : UInt8*) : Int32
end

private def default_size(window : Apprt::Window) : {Int32, Int32}
  WindowActionsSpecLib.gtk_window_get_default_size(window.widget, out width, out height)
  {width, height}
end

private def css_class?(widget : Apprt::Widget, name : String) : Bool
  WindowActionsSpecLib.gtk_widget_has_css_class(widget, name) != 0
end

describe "window actions" do
  before_all { GtkHarness.start }

  it "hides every window and shows them again" do
    app = TestApp.new
    run_steps(app) do
      first = app.new_window
      second = app.new_window
      settle
      trigger(first, Apprt::Action::ToggleVisibility.new)
      first.widget.visible?.should be_false
      second.widget.visible?.should be_false
      trigger(first, Apprt::Action::ToggleVisibility.new)
      first.widget.visible?.should be_true
      second.widget.visible?.should be_true
    end
  end

  it "returns to the initial size" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      trigger(window, Apprt::Action::InitialSize.new(640, 480))
      WindowActionsSpecLib.gtk_window_set_default_size(window.widget, 900, 700)
      trigger(window, Apprt::Action::ResetWindowSize.new)
      default_size(window).should eq({640, 480})
    end
  end

  it "toggles the background opacity of translucent windows" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      trigger(window, Apprt::Action::ToggleBackgroundOpacity.new)
      css_class?(window.widget, "opaque").should be_false
      app.window_style = Apprt::WindowStyle.new(opacity: 0.8)
      trigger(window, Apprt::Action::ToggleBackgroundOpacity.new)
      css_class?(window.widget, "opaque").should be_true
      trigger(window, Apprt::Action::ToggleBackgroundOpacity.new)
      css_class?(window.widget, "opaque").should be_false
    end
  end

  it "copies the surface title" do
    app = TestApp.new
    copied = Channel(String?).new(1)
    run_steps(app) do
      window = app.new_window
      settle
      window.active_surface.not_nil!.title = "copy me"
      trigger(window, Apprt::Action::CopyTitleToClipboard.new)
      Apprt::Clipboard.read { |text| copied.send(text) }
      settle
    end
    copied.receive.should eq "copy me"
  end

  it "marks surfaces read-only" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      surface = window.active_surface.not_nil!
      surface.read_only?.should be_false
      surface.@read_only_badge.visible?.should be_false
      trigger(window, Apprt::Action::ToggleReadOnly.new)
      surface.read_only?.should be_true
      surface.@read_only_badge.visible?.should be_true
      css_class?(surface.@host, "read-only").should be_true
      surface.read_only = false
      surface.@read_only_badge.visible?.should be_false
      css_class?(surface.@host, "read-only").should be_false
    end
  end
end
