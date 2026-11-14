# spec/gtk/decoration_spec.cr
require "./harness"

lib DecorationSpecLib
  fun gtk_widget_get_css_name(widget : Void*) : UInt8*
  fun gtk_widget_get_first_child(widget : Void*) : Void*
  fun gtk_widget_get_next_sibling(widget : Void*) : Void*
end

private def decorated?(window : Apprt::Window) : Bool
  Apprt::C.gtk_window_get_decorated(window.widget) != 0
end

# Returns the number of toasts the window shows.
private def toasts(widget : Void*) : Int32
  count = String.new(DecorationSpecLib.gtk_widget_get_css_name(widget)) == "toast" ? 1 : 0
  child = DecorationSpecLib.gtk_widget_get_first_child(widget)
  until child.null?
    count += toasts(child)
    child = DecorationSpecLib.gtk_widget_get_next_sibling(child)
  end
  count
end

describe "window extras" do
  before_all { GtkHarness.start }

  it "decorates on the client by default and hides decorations" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      eventually { window.widget.realized? }.should be_true
      window.decoration.should eq Apprt::Decoration::Auto
      window.decoration = :client
      decorated?(window).should be_true
      window.decoration = :none
      decorated?(window).should be_false
      window.decoration = :client
      decorated?(window).should be_true
    end
  end

  it "leaves server decorations to sway" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      eventually { window.widget.realized? }.should be_true
      window.decoration = :server
      decorated?(window).should be_false
    end
  end

  it "applies the decoration chosen before the window is realized" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      window.decoration = :none
      eventually { window.widget.realized? }.should be_true
      decorated?(window).should be_false
    end
  end

  it "toggles the decorations back to the ones they replaced" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      window.decoration = :server
      trigger(window, Apprt::Action::ToggleWindowDecorations.new)
      window.decoration.should eq Apprt::Decoration::None
      trigger(window, Apprt::Action::ToggleWindowDecorations.new)
      window.decoration.should eq Apprt::Decoration::Server
    end
  end

  it "keeps the blur setting where the compositor cannot blur" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      eventually { window.widget.realized? }.should be_true
      window.background_blur = true
      window.background_blur?.should be_true
      settle
      window.background_blur = false
      window.background_blur?.should be_false
    end
  end

  # Headless sway has no keyboard, so its windows never become active.
  it "asks for attention while inactive" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      eventually { window.widget.realized? }.should be_true
      window.active?.should be_false
      window.urgent = true
      window.urgent?.should be_true
      settle
      window.urgent = false
      window.urgent?.should be_false
    end
  end

  it "asks for attention when the bell rings in an unfocused surface" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first = window.tabs.first.surfaces.first
      second = first.split(:right)
      eventually { second.focused? }.should be_true
      first.ring_bell
      window.urgent?.should be_true
    end
  end

  it "shows toasts" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      window.toast("Copied to clipboard", 10.seconds)
      eventually { toasts(window.widget.to_unsafe) == 1 }.should be_true
    end
  end
end
