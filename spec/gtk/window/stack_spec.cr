# spec/gtk/window/stack_spec.cr
require "../harness"

lib StackSpecLib
  fun gtk_widget_has_css_class(widget : Void*, css_class : UInt8*) : Int32
  fun g_type_name_from_instance(instance : Void*) : UInt8*
end

private alias Action = DesktopKit::Action

# Returns the type name of the widget holding *surface*.
private def parent_type(surface : DesktopKit::Surface) : String?
  surface.@host.parent.try { |parent| String.new(StackSpecLib.g_type_name_from_instance(parent)) }
end

private def in_stack_box?(surface : DesktopKit::Surface) : Bool
  surface.@host.parent.try { |parent| StackSpecLib.gtk_widget_has_css_class(parent, "surface-stack") != 0 } || false
end

private def tiles(tab : DesktopKit::Tab) : DesktopKit::Widget
  tab.@view.@tiles
end

# Returns the stack position the header of *surface* shows, if any.
private def badge(surface : DesktopKit::Surface) : String?
  label = surface.@stack_badge
  String.new(DesktopKit::C.gtk_label_get_text(label)) if label.visible?
end

# Compares surfaces by id: a failure inspects the whole widget graph else.
private def ids(surfaces : Enumerable(DesktopKit::Surface)) : Array(UInt64)
  surfaces.map(&.id)
end

private def shown?(surface : DesktopKit::Surface) : Bool
  surface.@host.visible? && surface.@host.mapped?
end

# Opens a window whose tab holds the splits *first* and *second*, laid out.
private def two_splits(app : TestApp) : {DesktopKit::Window, DesktopKit::Tab, DesktopKit::Surface, DesktopKit::Surface}
  window = app.new_window
  tab = window.tabs.first
  first = tab.surfaces.first
  second = first.split(:right)
  settle
  eventually { second.@host.mapped? }.should be_true
  {window, tab, first, second}
end

# Opens a window whose tab holds *first* and, to its right, a stack of
# *second* and *third*, *third* shown and focused.
private def split_and_stack(app : TestApp) : {DesktopKit::Window, DesktopKit::Tab, DesktopKit::Surface, DesktopKit::Surface, DesktopKit::Surface}
  window, tab, first, second = two_splits(app)
  third = second.split(:down)
  settle
  third.stack_into(:up).should be_true
  settle
  eventually { shown?(third) }.should be_true
  {window, tab, first, second, third}
end

# Presses *keyval* on the window's sequence controller.
private def press(window : DesktopKit::Window, keyval : Char | UInt32) : Nil
  code = keyval.is_a?(Char) ? keyval.ord.to_u32 : keyval
  result = 0
  DesktopKit::C.g_signal_emit_by_name(window.@sequence_keys, "key-pressed", code, 0_u32, 0_u32, pointerof(result))
  settle
end

describe "stacked surfaces" do
  before_all { GtkHarness.start }

  it "stacks a split into its neighbor and shows it" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      trigger(window, Action::StackInto.new(:left))
      settle
      second.stacked?.should be_true
      first.stacked?.should be_true
      ids(first.stack).should eq ids([first, second])
      ids(tab.surfaces).should eq ids([first, second])
      in_stack_box?(first).should be_true
      in_stack_box?(second).should be_true
      eventually { shown?(second) }.should be_true
      shown?(first).should be_false
      eventually { second.focused? }.should be_true
      tab.active_surface.try(&.id).should eq second.id
      badge(first).should eq "1/2"
      badge(second).should eq "2/2"
    end
  end

  it "refuses a stack without a split next to it" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      only = window.tabs.first.surfaces.first
      settle
      only.stack_into(:left).should be_false
      app.perform_action(only, Action::StackInto.new(:right)).should be_false
      only.stacked?.should be_false
      ids(only.stack).should eq ids([only])
      badge(only).should be_nil
    end
  end

  it "switches the shown surface without rebuilding the splits" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second, third = split_and_stack(app)
      ids(second.stack).should eq ids([second, third])
      box = third.@host.parent
      trigger(window, Action::GotoStacked.new(Action::GotoStacked::NEXT))
      tab.@view.pending?.should be_false
      second.@host.parent.should eq box
      third.@host.parent.should eq box
      shown?(second).should be_true
      shown?(third).should be_false
      eventually { second.focused? }.should be_true
      tab.active_surface.try(&.id).should eq second.id
      trigger(window, Action::GotoStacked.new(Action::GotoStacked::PREVIOUS))
      tab.@view.pending?.should be_false
      shown?(third).should be_true
      trigger(window, Action::GotoStacked.new(0))
      shown?(second).should be_true
      trigger(window, Action::GotoStacked.new(Action::GotoStacked::LAST))
      shown?(third).should be_true
      app.perform_action(third, Action::GotoStacked.new(5)).should be_false
      app.perform_action(first, Action::GotoStacked.new(Action::GotoStacked::NEXT)).should be_false
      second.@host.realized?.should be_true
    end
  end

  it "shows a hidden stacked surface it focuses" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second, third = split_and_stack(app)
      first.focus
      second.focus
      tab.@view.pending?.should be_false
      shown?(second).should be_true
      shown?(third).should be_false
      eventually { second.focused? }.should be_true
      tab.active_surface.try(&.id).should eq second.id
    end
  end

  it "splits a stacked surface out beside its stack" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      second.stack_into(:left).should be_true
      settle
      second.unstack.should be_true
      settle
      first.stacked?.should be_false
      second.stacked?.should be_false
      ids(tab.surfaces).should eq ids([first, second])
      parent_type(second).should eq "GtkPaned"
      tab.@view.tree[DesktopKit::SplitTree::ROOT].as(DesktopKit::SplitTree::Split).layout.horizontal?.should be_true
      eventually { shown?(first) && shown?(second) }.should be_true
      eventually { second.focused? }.should be_true
      second.unstack.should be_false
      second.stack_into(:left).should be_true
      settle
      second.unstack(:vertical).should be_true
      tab.@view.tree[DesktopKit::SplitTree::ROOT].as(DesktopKit::SplitTree::Split).layout.vertical?.should be_true
    end
  end

  it "shows the next surface of a stack when the shown one closes" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second, third = split_and_stack(app)
      second.focus
      settle
      second.close
      settle
      third.stacked?.should be_false
      ids(tab.surfaces).should eq ids([first, third])
      eventually { shown?(third) }.should be_true
      tab.active_surface.try(&.id).should eq third.id
      badge(third).should be_nil
      eventually { !in_stack_box?(third) }.should be_true
    end
  end

  it "keeps the tab when a closed surface leaves a stack as its only split" do
    app = TestApp.new
    app.undo_timeout = 5.seconds
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      second.stack_into(:left).should be_true
      settle
      trigger(window, Action::CloseSurface.new)
      settle
      tab.closed?.should be_false
      ids(tab.surfaces).should eq ids([first])
      first.stacked?.should be_false
      eventually { first.@host.parent == tiles(tab) && shown?(first) }.should be_true
      trigger(window, Action::Undo.new)
      settle
      ids(tab.surfaces).should eq ids([first, second])
      ids(first.stack).should eq ids([first, second])
      eventually { shown?(second) }.should be_true
      shown?(first).should be_false
    end
  end

  it "labels only the shown surface of a stack to pick" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second, third = split_and_stack(app)
      picked = [] of DesktopKit::Surface
      window.pick_surface { |surface| picked << surface }.should be_true
      second.@pick_label.visible?.should be_false
      third.@pick_label.visible?.should be_true
      press(window, 's')
      ids(picked).should eq ids([third])
      window.pick_surface { |surface| picked << surface }.should be_true
      press(window, 'd')
      ids(picked).should eq ids([third])
      window.picking?.should be_false
    end
  end

  it "moves a stacked surface to a new window alone" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second, third = split_and_stack(app)
      trigger(window, Action::MoveSurfaceToNewWindow.new)
      settle
      app.windows.size.should eq 2
      moved = app.windows.last.tabs.first
      ids(moved.surfaces).should eq ids([third])
      third.stacked?.should be_false
      ids(tab.surfaces).should eq ids([first, second])
      second.stacked?.should be_false
      eventually { shown?(second) && shown?(third) }.should be_true
    end
  end

  it "stacks a float with a split" do
    app = TestApp.new
    run_steps(app) do
      window, tab, first, second = two_splits(app)
      second.float.should be_true
      settle
      second.stack_with(first).should be_true
      settle
      tab.floats.should be_empty
      second.floating?.should be_false
      ids(first.stack).should eq ids([first, second])
      eventually { shown?(second) && in_stack_box?(second) }.should be_true
      first.stack_with(first).should be_false
    end
  end
end
