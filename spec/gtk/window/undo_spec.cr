# spec/gtk/window/undo_spec.cr
require "../harness"

# Content that counts its `#on_close` calls.
private class ClosingContent < DesktopKit::WidgetContent
  getter closes = 0

  def initialize
    super(DesktopKit::Widget.new(DesktopKit::C.gtk_entry_new))
  end

  protected def on_close : Nil
    @closes += 1
  end
end

private def closing(app : TestApp) : Array(ClosingContent)
  made = [] of ClosingContent
  app.make_content = ->(context : DesktopKit::SurfaceContext) do
    ClosingContent.new.tap { |c| made << c }.as(DesktopKit::Content)
  end
  made
end

describe "undo" do
  before_all { GtkHarness.start }

  it "reopens a closed split in place and closes it again on redo" do
    app = TestApp.new
    app.undo_timeout = 5.seconds
    run_steps(app) do
      window = app.new_window
      settle
      tab = window.active_tab.not_nil!
      first = tab.surfaces.first
      second = first.split(:right)
      settle
      second.close
      settle
      tab.surfaces.should eq [first]
      second.closed?.should be_false
      trigger(window, DesktopKit::Action::Undo.new)
      tab.surfaces.should eq [first, second]
      second.tab.should be tab
      tab.active_surface.should be second
      trigger(window, DesktopKit::Action::Redo.new)
      tab.surfaces.should eq [first]
    end
  end

  it "reopens a closed tab at its position" do
    app = TestApp.new
    app.undo_timeout = 5.seconds
    run_steps(app) do
      window = app.new_window
      first = window.active_tab.not_nil!
      trigger(window, DesktopKit::Action::NewTab.new)
      trigger(window, DesktopKit::Action::NewTab.new)
      _, second, third = window.tabs
      second.title_override = "middle"
      surface = second.surfaces.first
      second.close
      settle
      window.tabs.should eq [first, third]
      trigger(window, DesktopKit::Action::Undo.new)
      window.tabs.size.should eq 3
      reopened = window.tabs[1]
      reopened.surfaces.should eq [surface]
      reopened.title_override.should eq "middle"
      window.active_tab.should be reopened
    end
  end

  it "reopens a closed window with its tabs" do
    app = TestApp.new
    app.undo_timeout = 5.seconds
    run_steps(app) do
      keep = app.new_window
      window = app.new_window
      trigger(window, DesktopKit::Action::NewTab.new)
      surfaces = window.tabs.map(&.surfaces.first)
      window.close
      settle
      app.windows.should eq [keep]
      surfaces.none?(&.closed?).should be_true
      trigger(keep, DesktopKit::Action::Undo.new)
      settle
      app.windows.size.should eq 2
      app.windows.last.tabs.map(&.surfaces.first).should eq surfaces
    end
  end

  it "releases closed surfaces after the timeout" do
    app = TestApp.new
    made = closing(app)
    run_steps(app) do
      app.undo_timeout = 300.milliseconds
      window = app.new_window
      settle
      surface = window.active_tab.not_nil!.surfaces.first.split(:down)
      settle
      surface.close
      settle
      surface.closed?.should be_false
      made.last.closes.should eq 0
      eventually { surface.closed? }
      made.last.closes.should eq 1
      made.first.closes.should eq 0
      trigger(window, DesktopKit::Action::Undo.new)
      window.active_tab.not_nil!.surfaces.size.should eq 1
    end
  end

  it "releases at once without undo" do
    app = TestApp.new
    made = closing(app)
    run_steps(app) do
      app.undo_timeout = Time::Span.zero
      window = app.new_window
      settle
      surface = window.active_tab.not_nil!.surfaces.first.split(:down)
      settle
      surface.close
      settle
      surface.closed?.should be_true
      made.last.closes.should eq 1
    end
  end

  it "keeps the content of a surface undo reopens" do
    app = TestApp.new
    made = closing(app)
    run_steps(app) do
      app.undo_timeout = 5.seconds
      window = app.new_window
      settle
      first = window.active_tab.not_nil!.surfaces.first
      second = first.split(:right)
      settle
      second.close
      settle
      trigger(window, DesktopKit::Action::Undo.new)
      settle
      made.map(&.closes).should eq [0, 0]
      app.undo_timeout = Time::Span.zero
      second.close
      settle
      made.map(&.closes).should eq [0, 1]
    end
  end
end
