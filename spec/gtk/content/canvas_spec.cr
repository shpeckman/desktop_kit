# spec/gtk/content/canvas_spec.cr
require "../harness"

# Canvas that records its hooks.
class TestCanvas < DesktopKit::Canvas
  getter events = [] of String
  getter keys = [] of DesktopKit::KeyEvent
  getter buttons = [] of DesktopKit::MouseButtonEvent
  getter motions = [] of DesktopKit::MouseMotionEvent
  getter scrolls = [] of DesktopKit::ScrollEvent
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

  protected def on_key(event : DesktopKit::KeyEvent) : Bool
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

  protected def on_mouse_button(event : DesktopKit::MouseButtonEvent) : Nil
    @buttons << event
  end

  protected def on_mouse_motion(event : DesktopKit::MouseMotionEvent) : Nil
    @motions << event
  end

  protected def on_mouse_enter(event : DesktopKit::MouseMotionEvent) : Nil
    @events << "enter #{event.x} #{event.y}"
  end

  protected def on_mouse_leave : Nil
    @events << "leave"
  end

  protected def on_scroll(event : DesktopKit::ScrollEvent) : Nil
    @scrolls << event
  end
end

private def canvas_app : TestApp
  TestApp.new.tap do |app|
    app.make_content = ->(context : DesktopKit::SurfaceContext) { TestCanvas.new.as(DesktopKit::Content) }
  end
end

private def canvas(surface : DesktopKit::Surface) : TestCanvas
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
private def key(canvas : TestCanvas, signal : String, keyval : UInt32, state : DesktopKit::C::GdkModifierType = :none,
                keycode : UInt32 = 0_u32) : Bool
  result = 0
  DesktopKit::C.g_signal_emit_by_name(canvas.@key_controller, signal, keyval, keycode, state.value, pointerof(result))
  result != 0
end

private def cursor_name(surface : DesktopKit::Surface) : String?
  cursor = DesktopKit::C.gtk_widget_get_cursor(surface.content.widget)
  DesktopKit::Native.string?(DesktopKit::C.gdk_cursor_get_name(cursor)) unless cursor.null?
end

describe DesktopKit::Canvas do
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
      event.mods.should eq DesktopKit::Mods::None
      event.modifier?.should be_false

      canvas.handle_keys = true
      key(canvas, "key-pressed", 0x41_u32, :shift_mask).should be_true
      event = canvas.keys.last
      event.text.should eq "A"
      event.unshifted.should eq 'a'
      event.mods.should eq DesktopKit::Mods::Shift

      key(canvas, "key-pressed", 0x63_u32, :control_mask)
      canvas.keys.last.text.should eq "c"
      canvas.keys.last.mods.should eq DesktopKit::Mods::Ctrl

      key(canvas, "key-released", 0x63_u32, :control_mask)
      canvas.keys.last.pressed?.should be_false
      canvas.keys.last.text.should be_nil
    end
  end

  it "marks a press of a held key as a repeat until the key goes up" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      key(canvas, "key-pressed", 0x61_u32, keycode: 38_u32)
      canvas.keys.last.repeat?.should be_false
      canvas.keys.last.base.should eq 'a'
      key(canvas, "key-pressed", 0x61_u32, keycode: 38_u32)
      canvas.keys.last.repeat?.should be_true
      canvas.keys.last.text.should eq "a"
      key(canvas, "key-pressed", 0x62_u32, keycode: 56_u32)
      canvas.keys.last.repeat?.should be_false
      key(canvas, "key-released", 0x61_u32, keycode: 38_u32)
      canvas.keys.last.repeat?.should be_false
      key(canvas, "key-pressed", 0x61_u32, keycode: 38_u32)
      canvas.keys.last.repeat?.should be_false
    end
  end

  it "counts a modifier key in its own press but not in its release" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      key(canvas, "key-pressed", 0xffe3_u32)
      canvas.keys.last.modifier?.should be_true
      canvas.keys.last.mods.should eq DesktopKit::Mods::Ctrl
      canvas.keys.last.text.should be_nil
      key(canvas, "key-released", 0xffe3_u32, :control_mask)
      canvas.keys.last.mods.should eq DesktopKit::Mods::None
    end
  end

  it "tells the input method its input purpose" do
    run_steps(TestApp.new) do |app|
      app.new_window
      purpose = ->(canvas : TestCanvas) do
        value = DesktopKit::C::GValue.new
        DesktopKit::C.g_value_init(pointerof(value), DesktopKit::C.g_type_from_name("GtkInputPurpose"))
        DesktopKit::C.g_object_get_property(canvas.@im_context, "input-purpose", pointerof(value))
        DesktopKit::C.g_value_get_enum(pointerof(value)).tap { DesktopKit::C.g_value_unset(pointerof(value)) }
      end
      purpose.call(TestCanvas.new).should eq DesktopKit::C::GtkInputPurpose::FreeForm.value
      purpose.call(TestCanvas.new(input_purpose: :terminal)).should eq DesktopKit::C::GtkInputPurpose::Terminal.value
    end
  end

  it "reports input method text and ends a composition a key used" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      im = canvas.@im_context
      DesktopKit::C.g_signal_emit_by_name(im, "commit", "é")
      canvas.events.last(2).should eq ["preedit nil", "commit é"]

      DesktopKit::C.g_signal_emit_by_name(im, "preedit-start")
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
      DesktopKit::C.g_signal_emit_by_name(canvas.@click_gesture, "pressed", 1, 1.0, 1.0)
      eventually { canvas.surface.focused? }.should be_true
      second.focused?.should be_false
    end
  end

  it "reports buttons, motion and scrolls in framebuffer pixels" do
    run_steps(canvas_app) do |app|
      canvas = drawn_canvas(app)
      DesktopKit::C.g_signal_emit_by_name(canvas.@click_gesture, "pressed", 1, 10.5, 20.0)
      DesktopKit::C.g_signal_emit_by_name(canvas.@click_gesture, "released", 1, 11.0, 21.0)
      canvas.buttons.map { |event| {event.pressed?, event.x, event.y} }.should eq [{true, 10.5, 20.0}, {false, 11.0, 21.0}]

      DesktopKit::C.g_signal_emit_by_name(canvas.@motion_controller, "enter", 1.0, 2.0)
      canvas.events.last.should eq "enter 1.0 2.0"
      DesktopKit::C.g_signal_emit_by_name(canvas.@motion_controller, "motion", 3.0, 4.0)
      {canvas.motions.last.x, canvas.motions.last.y}.should eq({3.0, 4.0})
      DesktopKit::C.g_signal_emit_by_name(canvas.@motion_controller, "leave")
      canvas.events.last.should eq "leave"

      result = 0
      DesktopKit::C.g_signal_emit_by_name(canvas.@scroll_controller, "scroll", 0.0, 2.0, pointerof(result))
      result.should eq 1
      event = canvas.scrolls.last
      {event.dx, event.dy, event.precise?}.should eq({0.0, 2.0, false})
    end
  end
end

describe DesktopKit::Surface do
  before_all { GtkHarness.start }

  it "sets the pointer and hides it" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      cursor_name(surface).should be_nil
      surface.cursor = "text"
      cursor_name(surface).should eq "text"
      trigger(window, DesktopKit::Action::MouseVisibility.new(visible: false))
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
      trigger(window, DesktopKit::Action::RingBell.new)
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
      page = DesktopKit::C.adw_tab_view_get_nth_page(window.@tab_view, 0)
      DesktopKit::C.adw_tab_page_get_needs_attention(page).should eq 1
      tab.title.starts_with?("🔔 ").should be_true
      first.focus
      eventually { !first.bell_ringing? }.should be_true
      DesktopKit::C.adw_tab_page_get_needs_attention(page).should eq 0
      other.closed?.should be_false
    end
  end
end

describe DesktopKit::Clipboard do
  before_all { GtkHarness.start }

  it "reads back what it wrote" do
    run_steps(TestApp.new) do |app|
      app.new_window
      texts = [] of String?
      DesktopKit::Clipboard.write("hello desktop_kit")
      DesktopKit::Clipboard.read { |text| texts << text }
      DesktopKit::Clipboard.write("selected", :primary)
      DesktopKit::Clipboard.read(:primary) { |text| texts << text }
      eventually { texts.size == 2 }.should be_true
      texts.should eq ["hello desktop_kit", "selected"]
    end
  end

  it "offers and reads back items by MIME type" do
    run_steps(TestApp.new) do |app|
      app.new_window
      items = [{"text/html", "<b>hi</b>".to_slice}, {"text/plain;charset=utf-8", "hi".to_slice}]
      DesktopKit::Clipboard.write(items)
      DesktopKit::Clipboard.offered.should eq ["text/html", "text/plain;charset=utf-8"]
      DesktopKit::Clipboard.items.should eq items
      reads = [] of String?
      DesktopKit::Clipboard.read("text/html") { |data| reads << data.try { |bytes| String.new(bytes) } }
      DesktopKit::Clipboard.read("image/png") { |data| reads << data.try { |bytes| String.new(bytes) } }
      eventually { reads.size == 2 }.should be_true
      reads.sort_by(&.to_s).should eq [nil, "<b>hi</b>"]
      DesktopKit::Clipboard.write("plain")
      DesktopKit::Clipboard.items.should be_nil
      DesktopKit::Clipboard.write([] of {String, Bytes})
      DesktopKit::Clipboard.offered.should be_empty
      expect_raises(ArgumentError, "repeated MIME type") { DesktopKit::Clipboard.write([items[0], items[0]]) }
    end
  end

  it "raises off the GTK thread" do
    expect_raises(RuntimeError, "GTK called outside the UI thread") { DesktopKit::Clipboard.write("x") }
  end
end

describe "DesktopKit::Drag" do
  before_all { GtkHarness.start }

  # A drag's content answers clipboard reads too, which exercises it
  # without a pointer to drag with.
  it "produces its data on request" do
    run_steps(TestApp.new) do |app|
      app.new_window
      requests = [] of String
      source = DesktopKit::DragContent::Source.new(["text/uri-list", "text/plain"], ->(request : DesktopKit::Drag::Request) {
        requests << request.mime_type
        request.mime_type == "text/plain" ? request.reply("dragged".to_slice) : request.fail
        request.reply("again".to_slice)
        nil
      })
      provider = DesktopKit::DragContent.new(source)
      DesktopKit::C.gdk_clipboard_set_content(DesktopKit::C.gdk_display_get_clipboard(DesktopKit::C.gdk_display_get_default), provider)
      DesktopKit::C.g_object_unref(provider)
      DesktopKit::Clipboard.offered.should eq ["text/uri-list", "text/plain"]
      reads = [] of String?
      DesktopKit::Clipboard.read("text/plain") { |data| reads << data.try { |bytes| String.new(bytes) } }
      eventually { reads.size == 1 }.should be_true
      DesktopKit::Clipboard.read("text/uri-list") { |data| reads << data.try { |bytes| String.new(bytes) } }
      eventually { reads.size == 2 }.should be_true
      # A local read of a failed request ends with no data, not an error.
      reads.should eq ["dragged", ""]
      requests.should eq ["text/plain", "text/uri-list"]
    end
  end

  it "maps actions to GDK" do
    DesktopKit::DragAction.from_gdk(DesktopKit::C::GdkDragAction::Move | DesktopKit::C::GdkDragAction::Ask).should eq DesktopKit::DragAction::Move
    (DesktopKit::DragAction::Copy | DesktopKit::DragAction::Link).to_gdk.should eq DesktopKit::C::GdkDragAction::Copy | DesktopKit::C::GdkDragAction::Link
  end
end

describe "Canvas#show_on_screen_keyboard" do
  before_all { GtkHarness.start }

  it "asks the input method for the on-screen keyboard" do
    run_steps(canvas_app) do |app|
      surface = app.new_window.active_surface.not_nil!
      eventually { surface.focused? }.should be_true
      surface.show_on_screen_keyboard.should be_true
      surface.close
      eventually { surface.closed? }.should be_true
      surface.show_on_screen_keyboard.should be_false
    end
  end
end
