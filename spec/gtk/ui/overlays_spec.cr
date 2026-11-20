# spec/gtk/ui/overlays_spec.cr
require "../harness"

# Content that records the search hooks and reports two matches.
class SearchContent < DesktopKit::WidgetContent
  getter events = [] of String

  def initialize
    super(DesktopKit::Widget.new(DesktopKit::C.gtk_entry_new))
  end

  protected def on_search(needle : String) : Nil
    @events << "search #{needle}"
    surface.search_total = needle.empty? ? nil : 2
    surface.search_selected = needle.empty? ? nil : 0
  end

  protected def on_search_navigate(forward : Bool) : Nil
    @events << (forward ? "next" : "previous")
  end

  protected def on_search_end : Nil
    @events << "end"
  end
end

private def search_app : TestApp
  TestApp.new.tap do |app|
    app.make_content = ->(context : DesktopKit::SurfaceContext) { SearchContent.new.as(DesktopKit::Content) }
  end
end

private def overlay(surface : DesktopKit::Surface) : DesktopKit::SearchOverlay
  surface.@search.not_nil!
end

private def label(widget : DesktopKit::Widget) : String
  String.new(DesktopKit::C.gtk_label_get_text(widget))
end

private def entry_text(surface : DesktopKit::Surface) : String
  String.new(DesktopKit::C.gtk_editable_get_text(overlay(surface).@entry))
end

describe "Surface search" do
  before_all { GtkHarness.start }

  it "opens with the action, reports the needle and closes" do
    run_steps(search_app) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      content = surface.content.as(SearchContent)
      surface.search_active?.should be_false

      trigger(window, DesktopKit::Action::StartSearch.new)
      surface.search_active?.should be_true
      overlay(surface).widget.visible?.should be_true

      DesktopKit::C.gtk_editable_set_text(overlay(surface).@entry, "foo")
      eventually { content.events.includes?("search foo") }.should be_true
      label(overlay(surface).@matches).should eq "1/2"

      trigger(window, DesktopKit::Action::NavigateSearch.new(direction: :next))
      trigger(window, DesktopKit::Action::NavigateSearch.new(direction: :previous))
      content.events.last(2).should eq ["next", "previous"]

      trigger(window, DesktopKit::Action::EndSearch.new)
      surface.search_active?.should be_false
      overlay(surface).widget.visible?.should be_false
      label(overlay(surface).@matches).should eq ""
      content.events.last.should eq "end"
    end
  end

  it "searches for a given needle" do
    run_steps(search_app) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      trigger(window, DesktopKit::Action::Search.new(needle: "bar"))
      surface.search_active?.should be_true
      entry_text(surface).should eq "bar"
      eventually { surface.content.as(SearchContent).events.includes?("search bar") }.should be_true
    end
  end

  it "navigates with Return and Shift+Return and ends with Escape" do
    run_steps(search_app) do |app|
      surface = app.new_window.active_surface.not_nil!
      content = surface.content.as(SearchContent)
      surface.start_search("x")
      keys = overlay(surface).@keys
      handled = 0
      DesktopKit::C.g_signal_emit_by_name(keys, "key-pressed", 0xff0d_u32, 36_u32, 0_u32, pointerof(handled))
      DesktopKit::C.g_signal_emit_by_name(keys, "key-pressed", 0xff0d_u32, 36_u32, 1_u32, pointerof(handled))
      content.events.last(2).should eq ["next", "previous"]
      DesktopKit::C.g_signal_emit_by_name(overlay(surface).@entry, "stop-search")
      surface.search_active?.should be_false
      content.events.last.should eq "end"
    end
  end

  it "shows no count without matches and a dash without a selection" do
    run_steps(search_app) do |app|
      surface = app.new_window.active_surface.not_nil!
      surface.start_search
      label(overlay(surface).@matches).should eq ""
      surface.search_total = 5
      label(overlay(surface).@matches).should eq "-/5"
      surface.search_selected = 4
      label(overlay(surface).@matches).should eq "5/5"
    end
  end

  it "refuses navigation and ending while closed" do
    run_steps(search_app) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      DesktopKit::C.gtk_widget_activate_action_variant(window.widget, "split.end-search", nil)
      DesktopKit::C.gtk_widget_activate_action_variant(window.widget, "split.navigate-search", DesktopKit::Action::NavigateSearch.new(direction: :next).to_variant.not_nil!.to_unsafe)
      settle
      surface.content.as(SearchContent).events.should be_empty
    end
  end

  it "snaps to the corner nearest to where a drag ends" do
    run_steps(search_app) do |app|
      surface = app.new_window.active_surface.not_nil!
      surface.start_search
      bar = overlay(surface)
      eventually { bar.widget.width > 0 }
      DesktopKit::C.g_signal_emit_by_name(bar.@drag, "drag-begin", 10.0, 10.0)
      DesktopKit::C.g_signal_emit_by_name(bar.@drag, "drag-end", -600.0, 400.0)
      DesktopKit::C.gtk_widget_get_halign(bar.widget).should eq DesktopKit::C::GtkAlign::Start
      DesktopKit::C.gtk_widget_get_valign(bar.widget).should eq DesktopKit::C::GtkAlign::End
    end
  end
end

describe "Surface#hover_text" do
  before_all { GtkHarness.start }

  it "shows the text at the bottom left and moves it away from the pointer" do
    run_steps(TestApp.new) do |app|
      surface = app.new_window.active_surface.not_nil!
      left, right = surface.@hover_left, surface.@hover_right
      left.visible?.should be_false

      surface.hover_text = "https://example.com"
      surface.hover_text.should eq "https://example.com"
      left.visible?.should be_true
      right.visible?.should be_false
      label(right).should eq "https://example.com"

      motion = surface.@hover_motion[0]
      DesktopKit::C.g_signal_emit_by_name(motion, "enter", 1.0, 1.0)
      left.visible?.should be_false
      right.visible?.should be_true

      surface.hover_text = nil
      left.visible?.should be_false
      right.visible?.should be_false
    end
  end
end

describe "Surface#show_size" do
  before_all { GtkHarness.start }

  it "shows the text for a moment, but not right after creation" do
    run_steps(TestApp.new) do |app|
      surface = app.new_window.active_surface.not_nil!
      size = surface.@size_label
      surface.show_size("80 × 24")
      size.visible?.should be_false

      settle 300.milliseconds
      surface.show_size("100 × 30")
      size.visible?.should be_true
      label(size).should eq "100 × 30"
      eventually(2.seconds) { !size.visible? }.should be_true
    end
  end
end
