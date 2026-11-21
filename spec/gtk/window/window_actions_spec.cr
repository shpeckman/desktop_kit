# spec/gtk/window/window_actions_spec.cr
require "../harness"

lib WindowActionsSpecLib
  fun gtk_window_set_default_size(window : Void*, width : Int32, height : Int32)
  fun gtk_window_get_default_size(window : Void*, width : Int32*, height : Int32*)
  fun gtk_widget_has_css_class(widget : Void*, name : UInt8*) : Int32
end

private def default_size(window : DesktopKit::Window) : {Int32, Int32}
  WindowActionsSpecLib.gtk_window_get_default_size(window.widget, out width, out height)
  {width, height}
end

private def css_class?(widget : DesktopKit::Widget, name : String) : Bool
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
      trigger(first, DesktopKit::Action::ToggleVisibility.new)
      first.widget.visible?.should be_false
      second.widget.visible?.should be_false
      trigger(first, DesktopKit::Action::ToggleVisibility.new)
      first.widget.visible?.should be_true
      second.widget.visible?.should be_true
    end
  end

  it "returns to the initial size" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      trigger(window, DesktopKit::Action::InitialSize.new(640, 480))
      WindowActionsSpecLib.gtk_window_set_default_size(window.widget, 900, 700)
      trigger(window, DesktopKit::Action::ResetWindowSize.new)
      default_size(window).should eq({640, 480})
    end
  end

  it "toggles the background opacity of translucent windows" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      trigger(window, DesktopKit::Action::ToggleBackgroundOpacity.new)
      css_class?(window.widget, "opaque").should be_false
      app.window_style = DesktopKit::WindowStyle.new(opacity: 0.8)
      trigger(window, DesktopKit::Action::ToggleBackgroundOpacity.new)
      css_class?(window.widget, "opaque").should be_true
      trigger(window, DesktopKit::Action::ToggleBackgroundOpacity.new)
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
      trigger(window, DesktopKit::Action::CopyTitleToClipboard.new)
      DesktopKit::Clipboard.read { |text| copied.send(text) }
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
      trigger(window, DesktopKit::Action::ToggleReadOnly.new)
      surface.read_only?.should be_true
      surface.@read_only_badge.visible?.should be_true
      css_class?(surface.@host, "read-only").should be_true
      surface.read_only = false
      surface.@read_only_badge.visible?.should be_false
      css_class?(surface.@host, "read-only").should be_false
    end
  end

  it "reports and changes the window state" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      window.monitor_size.should eq({1280, 800})
      window.fullscreen = true
      eventually { window.fullscreen? }.should be_true
      window.fullscreen = false
      eventually { !window.fullscreen? }.should be_true
      window.resizable = false
      window.resizable?.should be_false
      window.resizable = true
      window.suspended?.should be_false
    end
  end

  it "sets the window's application id" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      window.app_id = "org.example.Other"
      window.app_id.should eq("org.example.Other")
      window.app_id = "scratchpad"
      window.app_id.should eq("scratchpad")
      expect_raises(ArgumentError) { window.app_id = "" }
      expect_raises(ArgumentError) { window.app_id = "a\0b" }
      window.app_id = nil
      window.app_id.should be_nil
    end
  end

  it "inhibits idling and the desktop's shortcuts" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      window.set_idle_inhibited(true, "testing")
      window.idle_inhibited?.should be_true
      window.idle_inhibited = false
      window.idle_inhibited?.should be_false
      window.shortcuts_inhibited = true
      settle
      window.shortcuts_inhibited?.should be_true
      window.shortcuts_inhibited = false
    end
  end

  it "reports the user idle" do
    app = IdleApp.new
    run_steps(app) do
      app.new_window
      app.idle_timeout = 300.milliseconds
      eventually { app.user_idle? }.should be_true
      app.idles.should eq([true])
      app.idle_timeout = nil
      app.user_idle?.should be_false
      app.idles.should eq([true, false])
    end
  end

  it "opens a window at the size its surface asks for" do
    app = TestApp.new
    run_steps(app) do
      app.window_style = DesktopKit::WindowStyle.new(header_bar: false)
      window = app.new_window
      window.decoration = :none
      trigger(window, DesktopKit::Action::SizeLimit.new(0, 0, 0, 0))
      host = window.active_surface.not_nil!.@host
      trigger(window, DesktopKit::Action::ResizeWindow.new(120, 60))
      eventually { host.mapped? && {host.width, host.height} == {120, 60} }.should be_true
      {window.widget.width, window.widget.height}.should eq({120, 60})
      trigger(window, DesktopKit::Action::ResizeWindow.new(90, 40))
      eventually { {host.width, host.height} == {90, 40} }.should be_true
    end
  end

  it "keeps the tab overview's page hidden while closed" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      page = DesktopKit::Widget.new(DesktopKit::C.gtk_widget_get_last_child(window.@overview))
      page.visible?.should be_false
      trigger(window, DesktopKit::Action::ToggleTabOverview.new)
      page.visible?.should be_true
      eventually { page.mapped? }.should be_true
      trigger(window, DesktopKit::Action::ToggleTabOverview.new)
      eventually { !page.visible? }.should be_true
    end
  end
end

class IdleApp < TestApp
  getter idles = [] of Bool

  protected def on_user_idle(idle : Bool) : Nil
    @idles << idle
  end
end
