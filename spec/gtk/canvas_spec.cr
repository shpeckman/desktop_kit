# spec/gtk/canvas_spec.cr
require "./harness"

# Canvas that records its hooks.
class TestCanvas < Apprt::Canvas
  getter events = [] of String
  getter keys = [] of Apprt::KeyEvent
  getter buttons = [] of Apprt::MouseButtonEvent
  getter motions = [] of Apprt::MouseMotionEvent
  getter scrolls = [] of Apprt::ScrollEvent
  getter renders = 0
  property? handle_keys = false

  def count(event : String) : Int32
    @events.count(event)
  end

  protected def on_realize : Nil
    @events << "realize"
  end

  protected def on_unrealize : Nil
    @events << "unrealize"
  end

  protected def on_render : Nil
    @renders += 1
  end

  protected def on_resize(width : Int32, height : Int32) : Nil
    @events << "resize"
  end

  protected def on_key(event : Apprt::KeyEvent) : Bool
    @keys << event
    handle_keys?
  end

  protected def on_preedit(text : String?) : Nil
    @events << "preedit #{text.inspect}"
  end

  protected def on_commit(text : String) : Nil
    @events << "commit #{text}"
  end

  protected def on_focus(focused : Bool) : Nil
    @events << "focus #{focused}"
  end

  protected def on_mouse_button(event : Apprt::MouseButtonEvent) : Nil
    @buttons << event
  end

  protected def on_mouse_motion(event : Apprt::MouseMotionEvent) : Nil
    @motions << event
  end

  protected def on_mouse_leave : Nil
    @events << "leave"
  end

  protected def on_scroll(event : Apprt::ScrollEvent) : Nil
    @scrolls << event
  end
end

private def canvas_app : TestApp
  TestApp.new.tap do |app|
    app.make_content = ->(context : Apprt::SurfaceContext) { TestCanvas.new.as(Apprt::Content) }
  end
end

private def canvas(surface : Apprt::Surface) : TestCanvas
  surface.content.as(TestCanvas)
end

# Opens a window and returns its canvas once it is drawn.
private def drawn_canvas(app : TestApp) : TestCanvas
  canvas = canvas(app.new_window.active_surface.not_nil!)
  eventually { canvas.renders > 0 }.should be_true
  canvas
end

# Emits *signal* of a key controller as a key press or release does and
# returns the signal's result.
private def key(canvas : TestCanvas, signal : String, keyval : UInt32, state : Apprt::C::GdkModifierType = :none) : Bool
  result = 0
  Apprt::C.g_signal_emit_by_name(canvas.@key_controller, signal, keyval, 0_u32, state.value, pointerof(result))
  result != 0
end

private def cursor_name(surface : Apprt::Surface) : String?
  cursor = Apprt::C.gtk_widget_get_cursor(surface.content.widget)
  Apprt::Native.string?(Apprt::C.gdk_cursor_get_name(cursor)) unless cursor.null?
end

describe Apprt::Canvas do
  before_all { GtkHarness.start }

  it "makes a GL context, sizes the framebuffer and draws" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      canvas.error.should be_nil
      canvas.api.should_not be_nil
      canvas.events.first.should eq "realize"
      canvas.events.should contain("resize")
      canvas.scale.should eq 1
      canvas.width.should eq canvas.widget.width
      canvas.height.should eq canvas.widget.height
      canvas.width.should be > 0
      renders = canvas.renders
      canvas.queue_render
      eventually { canvas.renders > renders }.should be_true
    end
  end

  it "realizes again after a split moves it" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      canvas.surface.split(:right)
      eventually { canvas.count("realize") == 2 }.should be_true
      canvas.count("unrealize").should eq 1
      canvas.events.should contain("focus false")
    end
  end

  it "hands keys to on_key with their text and modifiers" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      key(canvas, "key-pressed", 0x61_u32).should be_false
      event = canvas.keys.last
      event.pressed?.should be_true
      event.keyval.should eq 0x61
      event.text.should eq "a"
      event.unshifted.should eq 'a'
      event.mods.should eq Apprt::Mods::None
      event.modifier?.should be_false

      canvas.handle_keys = true
      key(canvas, "key-pressed", 0x41_u32, :shift_mask).should be_true
      event = canvas.keys.last
      event.text.should eq "A"
      event.unshifted.should eq 'a'
      event.mods.should eq Apprt::Mods::Shift

      key(canvas, "key-pressed", 0x63_u32, :control_mask)
      canvas.keys.last.text.should eq "c"
      canvas.keys.last.mods.should eq Apprt::Mods::Ctrl

      key(canvas, "key-released", 0x63_u32, :control_mask)
      canvas.keys.last.pressed?.should be_false
      canvas.keys.last.text.should be_nil
    end
  end

  it "counts a modifier key in its own press but not in its release" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      key(canvas, "key-pressed", 0xffe3_u32)
      canvas.keys.last.modifier?.should be_true
      canvas.keys.last.mods.should eq Apprt::Mods::Ctrl
      canvas.keys.last.text.should be_nil
      key(canvas, "key-released", 0xffe3_u32, :control_mask)
      canvas.keys.last.mods.should eq Apprt::Mods::None
    end
  end

  it "reports input method text and ends a composition a key used" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      im = canvas.@im_context
      Apprt::C.g_signal_emit_by_name(im, "commit", "é")
      canvas.events.last(2).should eq ["preedit nil", "commit é"]

      Apprt::C.g_signal_emit_by_name(im, "preedit-start")
      canvas.handle_keys = true
      key(canvas, "key-pressed", 0x61_u32).should be_true
      canvas.keys.last.composing?.should be_true
      canvas.events.last.should eq "preedit nil"
    end
  end

  it "takes the focus on a button press" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      second = canvas.surface.split(:right)
      eventually { second.focused? }.should be_true
      Apprt::C.g_signal_emit_by_name(canvas.@click_gesture, "pressed", 1, 1.0, 1.0)
      eventually { canvas.surface.focused? }.should be_true
      second.focused?.should be_false
    end
  end

  it "reports buttons, motion and scrolls in framebuffer pixels" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      Apprt::C.g_signal_emit_by_name(canvas.@click_gesture, "pressed", 1, 10.5, 20.0)
      Apprt::C.g_signal_emit_by_name(canvas.@click_gesture, "released", 1, 11.0, 21.0)
      canvas.buttons.map { |event| {event.pressed?, event.x, event.y} }.should eq [{true, 10.5, 20.0}, {false, 11.0, 21.0}]

      Apprt::C.g_signal_emit_by_name(canvas.@motion_controller, "motion", 3.0, 4.0)
      {canvas.motions.last.x, canvas.motions.last.y}.should eq({3.0, 4.0})
      Apprt::C.g_signal_emit_by_name(canvas.@motion_controller, "leave")
      canvas.events.last.should eq "leave"

      result = 0
      Apprt::C.g_signal_emit_by_name(canvas.@scroll_controller, "scroll", 0.0, 2.0, pointerof(result))
      result.should eq 1
      event = canvas.scrolls.last
      {event.dx, event.dy, event.precise?}.should eq({0.0, 2.0, false})
    end
  end
end

describe Apprt::Surface do
  before_all { GtkHarness.start }

  it "sets the pointer and hides it" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      cursor_name(surface).should be_nil
      surface.cursor = "text"
      cursor_name(surface).should eq "text"
      trigger(window, Apprt::Action::MouseVisibility.new(visible: false))
      surface.mouse_visible?.should be_false
      cursor_name(surface).should eq "none"
      surface.mouse_visible = true
      cursor_name(surface).should eq "text"
      surface.cursor = nil
      cursor_name(surface).should be_nil
    end
  end

  it "rings the bell of a surface without the focus until it gets it" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      first = window.active_surface.not_nil!
      first.title = "shell"
      eventually { first.focused? }.should be_true
      trigger(window, Apprt::Action::RingBell.new)
      first.bell_ringing?.should be_false

      second = first.split(:right)
      second.title = "shell"
      eventually { second.focused? && !first.focused? }.should be_true
      first.ring_bell
      first.bell_ringing?.should be_true
      tab = first.tab.not_nil!
      tab.title.should eq "🔔 shell"

      first.focus
      eventually { first.focused? }.should be_true
      first.bell_ringing?.should be_false
      tab.title.should eq "shell"
    end
  end

  it "marks a ringing tab that is not selected" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      first = window.active_surface.not_nil!
      tab = first.tab.not_nil!
      other = window.new_tab
      settle
      first.ring_bell
      page = Apprt::C.adw_tab_view_get_nth_page(window.@tab_view, 0)
      Apprt::C.adw_tab_page_get_needs_attention(page).should eq 1
      tab.title.starts_with?("🔔 ").should be_true
      first.focus
      eventually { !first.bell_ringing? }.should be_true
      Apprt::C.adw_tab_page_get_needs_attention(page).should eq 0
      other.closed?.should be_false
    end
  end
end

describe Apprt::Clipboard do
  before_all { GtkHarness.start }

  it "reads back what it wrote" do
    run_steps(TestApp.new) do |app|
      app.new_window
      texts = [] of String?
      Apprt::Clipboard.write("hello apprt")
      Apprt::Clipboard.read { |text| texts << text }
      Apprt::Clipboard.write("selected", :primary)
      Apprt::Clipboard.read(:primary) { |text| texts << text }
      eventually { texts.size == 2 }.should be_true
      texts.should eq ["hello apprt", "selected"]
    end
  end

  it "raises off the GTK thread" do
    expect_raises(RuntimeError, "GTK called outside the UI thread") { Apprt::Clipboard.write("x") }
  end
end
