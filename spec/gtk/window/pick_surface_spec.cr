# spec/gtk/window/pick_surface_spec.cr
require "../harness"

private ESCAPE = 0xff1b_u32

# Presses *keyval* on the window's sequence controller and returns whether
# the window took the key.
private def press(window : DesktopKit::Window, keyval : Char | UInt32) : Bool
  code = keyval.is_a?(Char) ? keyval.ord.to_u32 : keyval
  result = 0
  DesktopKit::C.g_signal_emit_by_name(window.@sequence_keys, "key-pressed", code, 0_u32, 0_u32, pointerof(result))
  settle
  result != 0
end

describe "Window#pick_surface" do
  before_all { GtkHarness.start }

  it "calls the block with the surface whose label is typed" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      second = first.split(:right)
      third = second.split(:down)
      settle
      picked = [] of DesktopKit::Surface
      window.pick_surface(except: third) { |surface| picked << surface }.should be_true
      window.picking?.should be_true
      press(window, 's').should be_true
      picked.should eq [second]
      window.picking?.should be_false
      press(window, 'a').should be_false
      picked.should eq [second]
    end
  end

  it "labels the floats after the splits" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      second = first.split(:right)
      third = second.split(:right)
      settle
      second.float.should be_true
      settle
      picked = [] of DesktopKit::Surface
      window.pick_surface(except: first) { |surface| picked << surface }.should be_true
      press(window, 's').should be_true
      picked.should eq [second]
      window.pick_surface { |surface| picked << surface }.should be_true
      press(window, 'd').should be_true
      picked.should eq [second, second]
      window.pick_surface { |surface| picked << surface }.should be_true
      press(window, 'a').should be_true
      picked.should eq [second, second, first]
    end
  end

  it "cancels on another key" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      window.tabs.first.surfaces.first.split(:right)
      settle
      picked = [] of DesktopKit::Surface
      window.pick_surface { |surface| picked << surface }.should be_true
      press(window, ESCAPE).should be_true
      window.picking?.should be_false
      picked.should be_empty
      window.pick_surface { |surface| picked << surface }
      window.cancel_pick
      press(window, 'a').should be_false
      picked.should be_empty
    end
  end

  it "has nothing to pick without other surfaces" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      only = window.active_surface.not_nil!
      window.pick_surface(except: only) { }.should be_false
      window.picking?.should be_false
    end
  end

  it "swaps a picked surface with the focused one" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      second = first.split(:right)
      settle
      window.pick_surface(except: second) { |surface| second.swap_with(surface) }
      press(window, 'a').should be_true
      tab.surfaces.should eq [second, first]
      tab.active_surface.should eq second
      second.swap_with(second).should be_false
    end
  end
end
