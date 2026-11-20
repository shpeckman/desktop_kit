# spec/gtk/ui/menu_spec.cr
require "../harness"

lib MenuSpecLib
  fun gtk_menu_button_get_menu_model(button : Void*) : Void*
  fun g_menu_model_get_n_items(model : Void*) : Int32
  fun gtk_widget_get_parent(widget : Void*) : Void*
  fun gtk_widget_get_first_child(widget : Void*) : Void*
  fun gtk_widget_get_next_sibling(widget : Void*) : Void*
  fun g_type_name_from_instance(instance : Void*) : UInt8*
end

private class MenuContent < DesktopKit::WidgetContent
  getter clicks = [] of {Float64, Float64}
  property menu : DesktopKit::Menu? = nil

  def initialize
    super(DesktopKit::Widget.new(DesktopKit::C.gtk_entry_new))
  end

  protected def context_menu(x : Float64, y : Float64) : DesktopKit::Menu?
    @clicks << {x, y}
    @menu
  end
end

private def menu_app : TestApp
  app = TestApp.new
  app.make_content = ->(context : DesktopKit::SurfaceContext) { MenuContent.new.as(DesktopKit::Content) }
  app
end

private def sections(window : DesktopKit::Window) : Int32
  MenuSpecLib.g_menu_model_get_n_items(MenuSpecLib.gtk_menu_button_get_menu_model(window.@menu_button))
end

# Returns how many context menus the surface's overlay holds.
private def popovers(surface : DesktopKit::Surface) : Int32
  # Counts children rather than comparing pointers: a freed popover's
  # address is reused.
  count = 0
  child = MenuSpecLib.gtk_widget_get_first_child(surface.@overlay)
  until child.null?
    count += 1 if String.new(MenuSpecLib.g_type_name_from_instance(child)) == "GtkPopoverMenu"
    child = MenuSpecLib.gtk_widget_get_next_sibling(child)
  end
  count
end

private def right_click(surface : DesktopKit::Surface, x : Float64, y : Float64) : Nil
  DesktopKit::C.g_signal_emit_by_name(surface.@context_click, "pressed", 1, x, y)
end

describe "App#window_menu=" do
  before_all { GtkHarness.start }

  it "shows the default menu and replaces it in open and new windows" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      sections(window).should eq 5
      app.window_menu = DesktopKit::Menu.build { |menu| menu.item "New Tab", DesktopKit::Action::NewTab.new }
      settle
      sections(window).should eq 1
      sections(app.new_window).should eq 1
    end
  end
end

describe "Content#context_menu" do
  before_all { GtkHarness.start }

  it "pops up the content's menu where the surface was clicked" do
    run_steps(menu_app) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      content = surface.content.as(MenuContent)
      settle
      right_click(surface, 10.0, 20.0)
      content.clicks.should eq [{10.0, 20.0}]
      surface.@context_popover.null?.should be_true

      content.menu = DesktopKit::Menu.build { |menu| menu.item "Split Right", DesktopKit::Action::NewSplit.new(:right) }
      right_click(surface, 30.0, 40.0)
      popover = surface.@context_popover
      popover.null?.should be_false
      MenuSpecLib.gtk_widget_get_parent(popover).should eq surface.@overlay
      eventually { DesktopKit::C.gtk_widget_get_visible(popover) != 0 }.should be_true

      right_click(surface, 50.0, 60.0)
      content.clicks.size.should eq 3
      popovers(surface).should eq 1
      DesktopKit::C.gtk_popover_popdown(surface.@context_popover)
      eventually { surface.@context_popover.null? }.should be_true
      popovers(surface).should eq 0
    end
  end

  it "drops the open menu with its surface" do
    run_steps(menu_app) do |app|
      window = app.new_window
      surface = window.active_surface.not_nil!
      surface.content.as(MenuContent).menu = DesktopKit::Menu.window
      settle
      right_click(surface, 5.0, 5.0)
      surface.@context_popover.null?.should be_false
      surface.split(:right)
      settle
      surface.close
      eventually { surface.closed? }.should be_true
      surface.@context_popover.null?.should be_true
    end
  end
end
