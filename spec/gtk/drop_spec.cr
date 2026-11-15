# spec/gtk/drop_spec.cr
require "./harness"

lib DropSpecLib
  fun gtk_widget_observe_controllers(widget : Void*) : Void*
  fun g_list_model_get_n_items(list : Void*) : UInt32
  fun g_list_model_get_item(list : Void*, position : UInt32) : Void*
  fun g_type_name_from_instance(instance : Void*) : UInt8*
  fun gtk_widget_has_css_class(widget : Void*, css_class : UInt8*) : Int32
  fun g_file_new_for_path(path : UInt8*) : Void*
  fun gdk_file_list_new_from_array(files : Void**, n_files : LibC::SizeT) : Void*
  fun g_value_set_object(value : Void*, object : Void*)
  fun g_value_take_boxed(value : Void*, boxed : Void*)
  fun g_file_get_type : UInt64
end

# Content that records what the user drops on it.
class DropContent < Apprt::WidgetContent
  getter drops = [] of Array(Path) | String
  property? takes = true

  def initialize
    super(Apprt::Widget.new(Apprt::C.gtk_entry_new))
  end

  protected def on_drop(files : Array(Path)) : Bool
    @drops << files
    takes?
  end

  protected def on_drop(text : String) : Bool
    @drops << text
    takes?
  end
end

private def drop_app : TestApp
  app = TestApp.new
  app.make_content = ->(_context : Apprt::SurfaceContext) { DropContent.new.as(Apprt::Content) }
  app
end

# Emits `drop` on *target* with *value* at (*x*, *y*) and returns the result.
private def emit_drop(target : Void*, value : Apprt::C::GValue*, x = 1.0, y = 1.0) : Bool
  result = 0
  Apprt::C.g_signal_emit_by_name(target, "drop", value, x, y, pointerof(result))
  Apprt::C.g_value_unset(value)
  result != 0
end

private def drop_text(surface : Apprt::Surface, text : String) : Bool
  value = Apprt::C::GValue.new
  Apprt::C.g_value_init(pointerof(value), Apprt::C::TYPE_STRING)
  Apprt::C.g_value_set_string(pointerof(value), text)
  emit_drop(surface.@data_drop_target, pointerof(value))
end

private def drop_files(surface : Apprt::Surface, paths : Array(String)) : Bool
  files = paths.map { |path| DropSpecLib.g_file_new_for_path(path) }
  value = Apprt::C::GValue.new
  Apprt::C.g_value_init(pointerof(value), Apprt::C.gdk_file_list_get_type)
  DropSpecLib.g_value_take_boxed(pointerof(value), DropSpecLib.gdk_file_list_new_from_array(files.to_unsafe, files.size))
  files.each { |file| Apprt::C.g_object_unref(file) }
  emit_drop(surface.@data_drop_target, pointerof(value))
end

private def drop_file(surface : Apprt::Surface, path : String) : Bool
  file = DropSpecLib.g_file_new_for_path(path)
  value = Apprt::C::GValue.new
  Apprt::C.g_value_init(pointerof(value), DropSpecLib.g_file_get_type)
  DropSpecLib.g_value_set_object(pointerof(value), file)
  Apprt::C.g_object_unref(file)
  emit_drop(surface.@data_drop_target, pointerof(value))
end

private def surface_value(surface : Apprt::Surface) : Apprt::C::GValue
  value = Apprt::C::GValue.new
  Apprt::C.g_value_init(pointerof(value), Apprt::C::TYPE_UINT64)
  Apprt::C.g_value_set_uint64(pointerof(value), surface.id)
  value
end

# Drops *source* on *target* at the fraction (*x*, *y*) of its size.
private def drop_surface(source : Apprt::Surface, target : Apprt::Surface, x : Float64, y : Float64) : Bool
  value = surface_value(source)
  host = target.@host
  emit_drop(target.@surface_drop_target, pointerof(value), x * host.width, y * host.height)
end

private def indicated?(surface : Apprt::Surface, css_class : String) : Bool
  DropSpecLib.gtk_widget_has_css_class(surface.@drop_indicator, css_class) != 0
end

private def handle_visible?(surface : Apprt::Surface) : Bool
  Apprt::C.gtk_widget_get_visible(surface.@handle) != 0
end

# Returns the type names of *widget*'s event controllers.
private def controllers(widget : Apprt::Widget) : Array(String)
  list = DropSpecLib.gtk_widget_observe_controllers(widget)
  names = Array(String).new(DropSpecLib.g_list_model_get_n_items(list)) do |index|
    item = DropSpecLib.g_list_model_get_item(list, index.to_u32)
    String.new(DropSpecLib.g_type_name_from_instance(item)).tap { Apprt::C.g_object_unref(item) }
  end
  Apprt::C.g_object_unref(list)
  names
end

describe "drag and drop" do
  before_all { GtkHarness.start }

  it "hands dropped text and files to the content" do
    app = drop_app
    run_steps(app) do
      window = app.new_window
      surface = window.tabs.first.surfaces.first
      content = surface.content.as(DropContent)
      settle
      drop_text(surface, "hello").should be_true
      drop_file(surface, "/tmp/one").should be_true
      drop_files(surface, ["/tmp/a b", "/tmp/c"]).should be_true
      content.drops.should eq ["hello", [Path["/tmp/one"]], [Path["/tmp/a b"], Path["/tmp/c"]]]
      content.takes = false
      drop_text(surface, "no").should be_false
    end
  end

  it "takes no drops in plain widget content" do
    app = TestApp.new
    run_steps(app) do
      surface = app.new_window.tabs.first.surfaces.first
      settle
      drop_text(surface, "ignored").should be_false
    end
  end

  it "shows the drag handle only while the tab is split" do
    app = TestApp.new
    run_steps(app) do
      first = app.new_window.tabs.first.surfaces.first
      settle
      handle_visible?(first).should be_false
      second = first.split(:right)
      settle
      handle_visible?(first).should be_true
      handle_visible?(second).should be_true
      second.close
      settle
      handle_visible?(first).should be_false
    end
  end

  it "drags the surface from its pane header as from its handle" do
    app = TestApp.new
    run_steps(app) do
      surface = app.new_window.tabs.first.surfaces.first
      settle
      controllers(surface.@handle).count("GtkDragSource").should eq 1
      controllers(surface.@header).count("GtkDragSource").should eq 1
    end
  end

  it "highlights the side of the surface nearest to the pointer" do
    app = TestApp.new
    run_steps(app) do
      first = app.new_window.tabs.first.surfaces.first
      second = first.split(:right)
      settle
      host = second.@host
      {
        {0.1, 0.5, "drop-left"}, {0.9, 0.5, "drop-right"},
        {0.5, 0.1, "drop-up"}, {0.5, 0.9, "drop-down"},
      }.each do |x, y, css_class|
        action = 0
        Apprt::C.g_signal_emit_by_name(second.@surface_drop_target, "motion", x * host.width, y * host.height, pointerof(action))
        action.should eq Apprt::C::GdkDragAction::Move.value
        indicated?(second, css_class).should be_true
        (%w[drop-left drop-right drop-up drop-down] - [css_class]).none? { |other| indicated?(second, other) }.should be_true
      end
      Apprt::C.g_signal_emit_by_name(second.@surface_drop_target, "leave")
      %w[drop-left drop-right drop-up drop-down].none? { |css_class| indicated?(second, css_class) }.should be_true
    end
  end

  it "moves a split next to another surface of its tab" do
    app = TestApp.new
    run_steps(app) do
      tab = app.new_window.tabs.first
      first = tab.surfaces.first
      second = first.split(:right)
      third = second.split(:right)
      settle
      tab.surfaces.should eq [first, second, third]
      drop_surface(third, first, 0.1, 0.5).should be_true
      settle
      tab.surfaces.should eq [third, first, second]
      tab.active_surface.should eq third
      third.tab.should eq tab
      eventually { third.focused? }.should be_true
    end
  end

  it "moves a surface into another tab and closes the tab it left empty" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first_tab = window.tabs.first
      first = first_tab.surfaces.first
      second_tab = window.new_tab
      moved = second_tab.surfaces.first
      trigger(window, Apprt::Action::GotoTab.new(0))
      settle
      drop_surface(moved, first, 0.5, 0.9).should be_true
      settle
      second_tab.closed?.should be_true
      window.tabs.should eq [first_tab]
      first_tab.surfaces.should eq [first, moved]
      moved.tab.should eq first_tab
      moved.closed?.should be_false
      eventually { moved.@host.mapped? }.should be_true
    end
  end

  it "moves one split of a tab into another tab" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      first_tab = window.tabs.first
      first = first_tab.surfaces.first
      second_tab = window.new_tab
      kept = second_tab.surfaces.first
      moved = kept.split(:down)
      trigger(window, Apprt::Action::GotoTab.new(0))
      settle
      drop_surface(moved, first, 0.9, 0.5).should be_true
      settle
      second_tab.surfaces.should eq [kept]
      first_tab.surfaces.should eq [first, moved]
      trigger(window, Apprt::Action::GotoTab.new(0))
      eventually { moved.@host.mapped? }.should be_true
      trigger(window, Apprt::Action::GotoTab.new(1))
      eventually { kept.@host.mapped? }.should be_true
    end
  end

  it "refuses a surface dropped on itself" do
    app = TestApp.new
    run_steps(app) do
      tab = app.new_window.tabs.first
      first = tab.surfaces.first
      second = first.split(:right)
      settle
      drop_surface(first, first, 0.1, 0.5).should be_false
      tab.surfaces.should eq [first, second]
    end
  end
end
