# spec/gtk/window/float_spec.cr
require "../harness"

lib FloatSpecLib
  fun gtk_widget_get_last_child(widget : Void*) : Void*
  fun gtk_widget_has_css_class(widget : Void*, css_class : UInt8*) : Int32
  fun g_type_name_from_instance(instance : Void*) : UInt8*
end

private alias Action = DesktopKit::Action
private alias Bounds = DesktopKit::Bounds

private def floating_class?(surface : DesktopKit::Surface) : Bool
  FloatSpecLib.gtk_widget_has_css_class(surface.@host, "floating") != 0
end

# Returns the type name of the widget holding *surface*.
private def parent_type(surface : DesktopKit::Surface) : String?
  surface.@host.parent.try { |parent| String.new(FloatSpecLib.g_type_name_from_instance(parent)) }
end

# Returns the overlay of *tab*, which holds its tiles and floats.
private def overlay(tab : DesktopKit::Tab) : DesktopKit::Widget
  tab.@view.root
end

private def tiles(tab : DesktopKit::Tab) : DesktopKit::Widget
  tab.@view.@tiles
end

private def last_child(widget : DesktopKit::Widget) : DesktopKit::Widget?
  DesktopKit::Widget.new?(FloatSpecLib.gtk_widget_get_last_child(widget))
end

# Returns the top-left corner of *surface* in its tab's overlay.
private def position(surface : DesktopKit::Surface, tab : DesktopKit::Tab) : {Int32, Int32}
  DesktopKit::C.gtk_widget_translate_coordinates(surface.@host, overlay(tab), 0.0, 0.0, out x, out y)
  {x.round.to_i, y.round.to_i}
end

private def bounds(surface : DesktopKit::Surface) : Bounds
  surface.float_bounds || raise "surface #{surface.id} does not float"
end

# Compares surfaces by id: a failure inspects the whole widget graph else.
private def ids(surfaces : Enumerable(DesktopKit::Surface)) : Array(UInt64)
  surfaces.map(&.id)
end

# Matches bounds equal to *expected* within float rounding.
private struct NearBounds
  def initialize(@expected : Bounds)
  end

  def match(actual : Bounds) : Bool
    {actual.x - @expected.x, actual.y - @expected.y,
     actual.width - @expected.width, actual.height - @expected.height}.all?(&.abs.<=(1e-9))
  end

  def failure_message(actual : Bounds) : String
    "Expected: #{@expected}
     got: #{actual}"
  end

  def negative_failure_message(actual : Bounds) : String
    "Expected: not #{@expected}
     got: #{actual}"
  end
end

private def be_near(expected : Bounds) : NearBounds
  NearBounds.new(expected)
end

# Opens a window whose tab holds the splits *first* and *second*, laid out.
private def two_splits(app : TestApp) : {DesktopKit::Window, DesktopKit::Tab, DesktopKit::Surface, DesktopKit::Surface}
  window = app.new_window
  tab = window.tabs.first
  first = tab.surfaces.first
  second = first.split(:right)
  settle
  eventually { overlay(tab).width > 0 && second.@host.mapped? }.should be_true
  {window, tab, first, second}
end

describe "floating surfaces" do
  before_all { GtkHarness.start }

  it "floats a split over its tab" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      trigger(window, Action::ToggleFloat.new)
      second.floating?.should be_true
      floating_class?(second).should be_true
      second.@host.parent.should eq overlay(tab)
      first.@host.parent.should eq tiles(tab)
      ids(tab.floats).should eq ids([second])
      ids(tab.surfaces).should eq ids([first, second])
      tab.active_surface.try(&.id).should eq second.id
      bounds(second).should be_near(Bounds.new(0.2, 0.2, 0.6, 0.6))
      width, height = overlay(tab).width, overlay(tab).height
      eventually { position(second, tab) == {(0.2 * width).round.to_i, (0.2 * height).round.to_i} }.should be_true
      second.@host.width.should eq (0.6 * width).round.to_i
      eventually { second.focused? }.should be_true
      first.float.should be_false
    end
  end

  it "keeps a tab's only split in place" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      only = tab.surfaces.first
      settle
      app.perform_action(only, Action::ToggleFloat.new).should be_false
      only.float(Bounds.new(0.1, 0.1, 0.5, 0.5)).should be_false
      only.tile.should be_false
      settle
      only.floating?.should be_false
      only.float_bounds.should be_nil
      tab.floats.should be_empty
      only.@host.parent.should eq tiles(tab)
    end
  end

  it "moves a float by pixels without rebuilding the splits" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      second.float.should be_true
      settle
      tile_parent = first.@host.parent
      width = overlay(tab).width
      x = bounds(second).x
      app.perform_action(second, Action::MoveFloat.new(:right, 40_u32)).should be_true
      tab.@view.pending?.should be_false
      first.@host.parent.should eq tile_parent
      second.@host.parent.should eq overlay(tab)
      bounds(second).x.should be_close(x + 40.0 / width, 1e-9)
      eventually { position(second, tab)[0] == (bounds(second).x * width).round.to_i }.should be_true
      trigger(window, Action::MoveFloat.new(:left, 10000_u32))
      bounds(second).x.should eq 0.0
      app.perform_action(second, Action::MoveFloat.new(:left, 10_u32)).should be_false
      app.perform_action(first, Action::MoveFloat.new(:left, 10_u32)).should be_false
      trigger(window, Action::MoveFloat.new(:down, 10000_u32))
      (bounds(second).y + bounds(second).height).should be_close(1.0, 1e-9)
    end
  end

  it "resizes a float from its bottom-right corner down to its minimum" do
    app = TestApp.new
    run_steps(app) do
      window, tab, _, second = two_splits(app)
      second.float.should be_true
      settle
      width = overlay(tab).width
      before = bounds(second)
      trigger(window, Action::ResizeSplit.new(:right, 50_u32))
      bounds(second).width.should be_close(before.width + 50.0 / width, 1e-9)
      bounds(second).x.should eq before.x
      trigger(window, Action::ResizeSplit.new(:left, 10000_u32))
      minimum = tab.@view.minimum(second.@host)[0]
      (bounds(second).width * width).should be_close(minimum, 1e-6)
      bounds(second).x.should eq before.x
      eventually { second.@host.width == minimum }.should be_true
    end
  end

  it "raises the focused float above the others" do
    app = TestApp.new
    run_steps(app) do
      _, tab, first, second = two_splits(app)
      third = second.split(:right)
      settle
      second.float.should be_true
      third.float.should be_true
      ids(tab.floats).should eq ids([second, third])
      bounds(third).should be_near(Bounds.new(0.24, 0.24, 0.6, 0.6))
      last_child(overlay(tab)).should eq third.@host
      second.focus
      ids(tab.floats).should eq ids([third, second])
      last_child(overlay(tab)).should eq second.@host
      ids(tab.surfaces).should eq ids([first, third, second])
      eventually { second.focused? }.should be_true
      ids(tab.floats).should eq ids([third, second])
    end
  end

  it "splits a float back in beside the split under its centre" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      third = second.split(:right)
      settle
      third.float(Bounds.new(0.0, 0.1, 0.3, 0.3)).should be_true
      settle
      trigger(window, Action::ToggleFloat.new)
      third.floating?.should be_false
      floating_class?(third).should be_false
      tab.floats.should be_empty
      eventually { parent_type(third) == "GtkPaned" }.should be_true
      third.@host.parent.should eq first.@host.parent
      third.@host.parent.should_not eq second.@host.parent
      tab.active_surface.try(&.id).should eq third.id
      third.tile.should be_false
    end
  end

  it "focuses the top float or the split focused last when a float closes" do
    app = TestApp.new
    app.undo_timeout = 5.seconds
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      third = second.split(:right)
      settle
      first.focus
      second.float.should be_true
      third.float(Bounds.new(0.5, 0.5, 0.25, 0.25)).should be_true
      settle
      third.close
      settle
      tab.active_surface.try(&.id).should eq second.id
      ids(tab.floats).should eq ids([second])
      third.@host.parent.should be_nil
      second.close
      settle
      tab.active_surface.try(&.id).should eq first.id
      tab.floats.should be_empty
      trigger(window, Action::Undo.new)
      ids(tab.floats).should eq ids([second])
      bounds(second).should be_near(Bounds.new(0.2, 0.2, 0.6, 0.6))
      trigger(window, Action::Undo.new)
      ids(tab.floats).should eq ids([second, third])
      bounds(third).should be_near(Bounds.new(0.5, 0.5, 0.25, 0.25))
      tab.active_surface.try(&.id).should eq third.id
      third.@host.parent.should eq overlay(tab)
    end
  end

  it "keeps the tab when its last split closes under a float" do
    app = TestApp.new
    app.undo_timeout = 5.seconds
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      second.float(Bounds.new(0.1, 0.2, 0.5, 0.4)).should be_true
      settle
      first.close
      settle
      tab.closed?.should be_false
      ids(tab.surfaces).should eq ids([second])
      tab.floats.should be_empty
      second.floating?.should be_false
      second.@host.parent.should eq tiles(tab)
      tab.active_surface.try(&.id).should eq second.id
      trigger(window, Action::Undo.new)
      eventually { first.@host.parent == tiles(tab) }.should be_true
      ids(tab.surfaces).should eq ids([first, second])
      ids(tab.floats).should eq ids([second])
      bounds(second).should be_near(Bounds.new(0.1, 0.2, 0.5, 0.4))
      second.@host.parent.should eq overlay(tab)
    end
  end

  it "cycles the focus through the splits, then the floats" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      third = second.split(:right)
      settle
      third.float.should be_true
      settle
      tab.active_surface.try(&.id).should eq third.id
      trigger(window, Action::GotoSplit.new(:next))
      tab.active_surface.try(&.id).should eq first.id
      trigger(window, Action::GotoSplit.new(:next))
      tab.active_surface.try(&.id).should eq second.id
      trigger(window, Action::GotoSplit.new(:next))
      tab.active_surface.try(&.id).should eq third.id
      trigger(window, Action::GotoSplit.new(:previous))
      tab.active_surface.try(&.id).should eq second.id
      third.focus
      app.perform_action(third, Action::GotoSplit.new(:left)).should be_false
      tab.active_surface.try(&.id).should eq third.id
    end
  end

  it "hides the floats while a split is zoomed" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      third = second.split(:right)
      settle
      third.float.should be_true
      settle
      app.perform_action(third, Action::ToggleSplitZoom.new).should be_false
      tab.zoomed?.should be_false
      second.focus
      trigger(window, Action::ToggleSplitZoom.new)
      tab.zoomed?.should be_true
      eventually { !third.@host.mapped? }.should be_true
      third.@host.visible?.should be_false
      third.@host.parent.should eq overlay(tab)
      trigger(window, Action::GotoSplit.new(:next))
      tab.zoomed?.should be_false
      tab.active_surface.try(&.id).should eq third.id
      eventually { third.@host.mapped? }.should be_true
      eventually { third.focused? }.should be_true
      first.focus
      trigger(window, Action::ToggleSplitZoom.new)
      eventually { !third.@host.mapped? }.should be_true
      trigger(window, Action::ToggleSplitZoom.new)
      tab.zoomed?.should be_false
      eventually { third.@host.mapped? }.should be_true
      tab.active_surface.try(&.id).should eq first.id
    end
  end

  it "moves a float to a new window as its only split" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      third = first.split(:down)
      settle
      second.float.should be_true
      settle
      tile_parent = first.@host.parent
      trigger(window, Action::MoveSurfaceToNewWindow.new)
      tab.@view.pending?.should be_false
      first.@host.parent.should eq tile_parent
      app.windows.size.should eq 2
      moved = app.windows.last.tabs.first
      ids(moved.surfaces).should eq ids([second])
      moved.floats.should be_empty
      second.floating?.should be_false
      second.tab.try(&.object_id).should eq moved.object_id
      ids(tab.surfaces).should eq ids([first, third])
      tab.floats.should be_empty
      eventually { second.@host.parent == tiles(moved) }.should be_true
    end
  end

  it "reopens a closed tab with its floats" do
    app = TestApp.new
    app.undo_timeout = 5.seconds
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      third = second.split(:right)
      settle
      second.float(Bounds.new(0.1, 0.1, 0.4, 0.4)).should be_true
      third.float(Bounds.new(0.3, 0.3, 0.5, 0.5)).should be_true
      settle
      trigger(window, Action::NewTab.new)
      tab.close
      settle
      window.tabs.size.should eq 1
      trigger(window, Action::Undo.new)
      reopened = window.tabs.find { |other| other.surfaces.includes?(first) } || raise "tab not reopened"
      ids(reopened.surfaces).should eq ids([first, second, third])
      ids(reopened.floats).should eq ids([second, third])
      bounds(second).should be_near(Bounds.new(0.1, 0.1, 0.4, 0.4))
      bounds(third).should be_near(Bounds.new(0.3, 0.3, 0.5, 0.5))
      eventually { third.@host.parent == overlay(reopened) && third.@host.mapped? }.should be_true
      second.floating?.should be_true
    end
  end
end
