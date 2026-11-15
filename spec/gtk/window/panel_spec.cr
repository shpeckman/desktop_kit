# spec/gtk/window/panel_spec.cr
require "../harness"

# The harness's headless output is 1280x800 at scale 1.
private def size(window : Apprt::Window) : {Int32, Int32}
  {window.widget.width, window.widget.height}
end

private def eventually_sized(window : Apprt::Window, expected : {Int32, Int32}) : Nil
  eventually { size(window) == expected }
  size(window).should eq expected
end

describe "Apprt::Panel" do
  before_all { GtkHarness.start }

  it "is supported by sway and lists its outputs" do
    run_steps(TestApp.new) do |app|
      app.panels?.should be_true
      app.outputs.should contain "HEADLESS-1"
    end
  end

  it "docks to an edge at the given thickness" do
    run_steps(TestApp.new) do |app|
      top = app.new_panel(Apprt::Panel.new(edge: :top, height: 160))
      top.panel.should eq Apprt::Panel.new(edge: :top, height: 160)
      eventually_sized(top, {1280, 160})
      # The top panel reserves its height; -1 ignores that.
      left = app.new_panel(Apprt::Panel.new(edge: :left, width: 200))
      eventually_sized(left, {200, 640})
      left.panel = Apprt::Panel.new(edge: :left, width: 200, exclusive_zone: -1)
      eventually_sized(left, {200, 800})
    end
  end

  it "covers the monitor as a background or a centered panel" do
    run_steps(TestApp.new) do |app|
      eventually_sized(app.new_panel(Apprt::Panel.new(edge: :background)), {1280, 800})
      centered = Apprt::Panel.new(edge: :center, margin_top: 100, margin_right: 50, margin_bottom: 100, margin_left: 50)
      eventually_sized(app.new_panel(centered), {1180, 600})
    end
  end

  it "takes its own size when centered or in the corner" do
    run_steps(TestApp.new) do |app|
      eventually_sized(app.new_panel(Apprt::Panel.new(edge: :center_sized, width: 300, height: 200)), {300, 200})
      eventually_sized(app.new_panel(Apprt::Panel.new(edge: :none, width: 320, height: 240, margin_top: 10, margin_left: 10)), {320, 240})
    end
  end

  it "moves to another edge" do
    run_steps(TestApp.new) do |app|
      panel = app.new_panel(Apprt::Panel.new(edge: :top, height: 160))
      eventually_sized(panel, {1280, 160})
      panel.panel = Apprt::Panel.new(edge: :right, width: 250, output: "HEADLESS-1")
      eventually_sized(panel, {250, 800})
    end
  end

  it "has no header bar" do
    run_steps(TestApp.new) do |app|
      panel = app.new_panel(Apprt::Panel.new)
      panel.@header.visible?.should be_false
      app.new_window.@header.visible?.should be_true
    end
  end

  it "refuses to turn an ordinary window into a panel" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      window.panel.should be_nil
      expect_raises(ArgumentError) { window.panel = Apprt::Panel.new }
    end
  end

  it "toggles the panels of one name" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      quick = app.new_panel(Apprt::Panel.new(name: "quick"), shown: false)
      other = app.new_panel(Apprt::Panel.new(name: "other"))
      quick.widget.visible?.should be_false
      trigger(window, Apprt::Action::TogglePanel.new("quick"))
      quick.widget.visible?.should be_true
      other.widget.visible?.should be_true
      trigger(window, Apprt::Action::TogglePanel.new("quick"))
      quick.widget.visible?.should be_false
      window.widget.visible?.should be_true
    end
  end

  it "hides when it loses the focus and asks to" do
    run_steps(TestApp.new) do |app|
      keep = app.new_panel(Apprt::Panel.new)
      hide = app.new_panel(Apprt::Panel.new(hide_on_focus_loss: true))
      settle
      {keep, hide}.each { |window| Apprt::C.g_object_notify(window.widget, "is-active") }
      keep.widget.visible?.should be_true
      hide.widget.visible?.should be_false
    end
  end

  it "reopens a closed panel as a panel" do
    app = TestApp.new
    app.undo_timeout = 5.seconds
    run_steps(app) do
      keep = app.new_window
      placement = Apprt::Panel.new(edge: :bottom, height: 150)
      app.new_panel(placement).close
      settle
      trigger(keep, Apprt::Action::Undo.new)
      reopened = app.windows.last
      reopened.panel.should eq placement
      eventually_sized(reopened, {1280, 150})
    end
  end
end
