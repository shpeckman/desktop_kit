# spec/gtk/window/window_overlay_spec.cr
require "../harness"

private def label(text : String) : DesktopKit::Content
  DesktopKit::WidgetContent.new(DesktopKit::Widget.new(DesktopKit::C.gtk_label_new(text)))
end

private class ClosingLabel < DesktopKit::WidgetContent
  getter closes = 0

  def initialize
    super(DesktopKit::Widget.new(DesktopKit::C.gtk_label_new("closing")))
  end

  protected def on_close : Nil
    @closes += 1
  end
end

describe DesktopKit::Window::Overlay do
  it "tells its content once that it closed" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      closed, dropped = ClosingLabel.new, ClosingLabel.new
      overlay = window.add_overlay(closed, 0, 0, 10, 10)
      window.add_overlay(dropped, 0, 0, 10, 10)
      closed.closes.should eq 0
      overlay.close
      overlay.close
      closed.closes.should eq 1
      window.close
      eventually { window.closed? }.should be_true
      settle
      closed.closes.should eq 1
      dropped.closes.should eq 1
    end
  end

  it "shows content over the tabs at a place and size" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      overlay = window.add_overlay(label("over"), 20, 10, 120, 40)
      settle
      window.overlays.should eq [overlay]
      widget = overlay.content.widget
      widget.mapped?.should be_true
      widget.width.should eq 120
      widget.height.should eq 40
      overlay.place(5, 5, 200, 60)
      settle
      widget.width.should eq 200
      widget.height.should eq 60
      overlay.modal?.should be_false
    end
  end

  it "measures the tab area overlays lie over" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      window.overlay_area.should eq({0, 0})
      settle
      width, height = window.overlay_area
      width.should be > 0
      height.should be > 0
      width.should be <= window.widget.width
      height.should be < window.widget.height
    end
  end

  it "stacks overlays and raises one to the top" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first = window.add_overlay(label("first"), 0, 0, 50, 50)
      second = window.add_overlay(label("second"), 10, 10, 50, 50)
      window.overlays.should eq [first, second]
      first.raise
      window.overlays.should eq [second, first]
      settle
      first.content.widget.mapped?.should be_true
      second.content.widget.mapped?.should be_true
    end
  end

  it "holds the input while modal and closes" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      entry = DesktopKit::Widget.new(DesktopKit::C.gtk_entry_new)
      overlay = window.add_overlay(DesktopKit::WidgetContent.new(entry), 0, 0, 100, 30, modal: true)
      overlay.modal?.should be_true
      settle
      eventually do
        focus = DesktopKit::C.gtk_window_get_focus(window.widget)
        !focus.null? && DesktopKit::C.gtk_widget_is_ancestor(focus, entry) != 0
      end.should be_true
      overlay.modal = false
      overlay.modal?.should be_false
      overlay.modal = true
      overlay.close
      overlay.closed?.should be_true
      window.overlays.should be_empty
      overlay.close
      overlay.place(0, 0, 10, 10)
      settle
      app.active_surface.not_nil!.content.widget.mapped?.should be_true
    end
  end

  it "reports the presses outside a modal overlay" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      overlay = window.add_overlay(label("modal"), 30, 20, 100, 30, modal: true)
      presses = [] of {DesktopKit::MouseButton, Float64, Float64}
      overlay.on_outside_press { |button, x, y| presses << {button, x, y} }
      settle
      DesktopKit::C.g_signal_emit_by_name(overlay.@catcher_gesture, "pressed", 1, 10.0, 60.0)
      presses.should eq [{DesktopKit::MouseButton.new(0), -20.0, 40.0}]
    end
  end

  it "forgets its overlays when the window closes" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      overlay = window.add_overlay(label("gone"), 0, 0, 10, 10)
      window.close
      eventually { window.closed? }.should be_true
      settle
      overlay.closed?.should be_true
      window.overlays.should be_empty
      expect_raises(ArgumentError) { window.add_overlay(label("late"), 0, 0, 10, 10) }
    end
  end
end
