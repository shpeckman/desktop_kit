# spec/gtk/window/window_style_spec.cr
require "../harness"
require "base64"

lib WindowStyleSpecLib
  fun gtk_widget_has_css_class(widget : Void*, css_class : UInt8*) : Int32
  fun gtk_widget_get_first_child(widget : Void*) : Void*
  fun gtk_widget_get_next_sibling(widget : Void*) : Void*
  fun gtk_label_get_label(label : Void*) : UInt8*
  fun adw_tab_page_get_icon(page : Void*) : Void*
  fun g_icon_to_string(icon : Void*) : UInt8*
  fun gtk_image_get_gicon(image : Void*) : Void*
  fun gtk_image_get_type : UInt64
  fun adw_window_title_get_subtitle(title : Void*) : UInt8*
  fun gtk_widget_is_ancestor(widget : Void*, ancestor : Void*) : Int32
  fun gtk_button_get_type : UInt64
  fun adw_tab_bar_get_autohide(bar : Void*) : Int32
  fun adw_toolbar_view_get_reveal_top_bars(view : Void*) : Int32
  fun adw_tab_view_get_shortcuts(view : Void*) : UInt32
end

private def css_class?(widget : DesktopKit::Widget, name : String) : Bool
  WindowStyleSpecLib.gtk_widget_has_css_class(widget, name) != 0
end

private def host(surface : DesktopKit::Surface) : DesktopKit::Widget
  surface.@host
end

private def header(surface : DesktopKit::Surface) : DesktopKit::Widget
  surface.@header
end

private def icon_string(icon : Void*) : String
  pointer = WindowStyleSpecLib.g_icon_to_string(icon)
  String.new(pointer).tap { DesktopKit::C.g_free(pointer) }
end

# A red 1x1 PNG.
private ICON_PNG = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")

# Writes the icon to a file in the temporary directory and returns its path.
private def icon_file : Path
  Path[Dir.tempdir, "desktop-kit-icon.png"].tap { |path| File.write(path, ICON_PNG) }
end

# Returns the icons of the images below *widget*.
private def image_icons(widget : Void*, icons = [] of String) : Array(String)
  child = WindowStyleSpecLib.gtk_widget_get_first_child(widget)
  until child.null?
    if DesktopKit::C.g_type_check_instance_is_a(child, WindowStyleSpecLib.gtk_image_get_type) != 0
      gicon = WindowStyleSpecLib.gtk_image_get_gicon(child)
      icons << icon_string(gicon) unless gicon.null?
    end
    image_icons(child, icons)
    child = WindowStyleSpecLib.gtk_widget_get_next_sibling(child)
  end
  icons
end

private def header_title(surface : DesktopKit::Surface) : String
  String.new(WindowStyleSpecLib.gtk_label_get_label(surface.@header_title))
end

# Returns the header buttons of *surface* in order.
private def header_buttons(surface : DesktopKit::Surface) : Array(Void*)
  buttons = [] of Void*
  child = WindowStyleSpecLib.gtk_widget_get_first_child(header(surface))
  until child.null?
    buttons << child if DesktopKit::C.g_type_check_instance_is_a(child, WindowStyleSpecLib.gtk_button_get_type) != 0
    child = WindowStyleSpecLib.gtk_widget_get_next_sibling(child)
  end
  buttons
end

private def inside?(widget : DesktopKit::Widget, ancestor : DesktopKit::Widget) : Bool
  WindowStyleSpecLib.gtk_widget_is_ancestor(widget, ancestor) != 0
end

describe DesktopKit::WindowStyle do
  it "rejects opacities outside 0..1" do
    expect_raises(ArgumentError, "opacity 1.5 outside 0..1") { DesktopKit::WindowStyle.new(opacity: 1.5) }
    expect_raises(ArgumentError, "unfocused_opacity -0.1 outside 0..1") { DesktopKit::WindowStyle.new(unfocused_opacity: -0.1) }
  end

  it "has no style sheet by default" do
    DesktopKit::WindowStyle.new.to_css.should be_empty
    css = DesktopKit::WindowStyle.new(cards: true, opacity: 0.8, unfocused_opacity: 0.5).to_css
    css.should contain "alpha(@window_bg_color, 0.8)"
    css.should contain "border-radius"
    css.should contain ".surface:not(.active) { opacity: 0.5; }"
  end
end

describe "window style" do
  before_all { GtkHarness.start }

  it "shows pane headers that act on their surface" do
    app = TestApp.new
    app.window_style = DesktopKit::WindowStyle.new(pane_headers: true)
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      surface = tab.surfaces.first
      settle
      header(surface).visible?.should be_true
      header_title(surface).should eq DesktopKit::Native.string?(DesktopKit::C.g_get_application_name)
      surface.title = "shell"
      header_title(surface).should eq "shell"
      surface.title_override = "custom"
      header_title(surface).should eq "custom"
      buttons = header_buttons(surface)
      buttons.size.should eq 4
      DesktopKit::C.g_signal_emit_by_name(buttons[0], "clicked")
      settle
      tab.surfaces.size.should eq 2
      second = tab.surfaces.last
      DesktopKit::C.g_signal_emit_by_name(header_buttons(second)[3], "clicked")
      settle
      tab.surfaces.should eq [surface]
      app.window_style = DesktopKit::WindowStyle.new
      settle
      header(surface).visible?.should be_false
    end
  end

  it "hides pane headers by default" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      header(window.tabs.first.surfaces.first).visible?.should be_false
    end
  end

  it "marks the active surface" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      first = tab.surfaces.first
      settle
      css_class?(host(first), "active").should be_true
      trigger(window, DesktopKit::Action::NewSplit.new(:right))
      settle
      second = tab.surfaces.last
      css_class?(host(first), "active").should be_false
      css_class?(host(second), "active").should be_true
      trigger(window, DesktopKit::Action::GotoSplit.new(:previous))
      settle
      css_class?(host(first), "active").should be_true
      css_class?(host(second), "active").should be_false
    end
  end

  it "shows the active surface's icon on its tab" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      tab = window.tabs.first
      surface = tab.surfaces.first
      settle
      page = DesktopKit::C.adw_tab_view_get_selected_page(window.@tab_view)
      WindowStyleSpecLib.adw_tab_page_get_icon(page).null?.should be_true
      surface.icon = "utilities-terminal"
      surface.icon.should eq "utilities-terminal"
      WindowStyleSpecLib.adw_tab_page_get_icon(page).null?.should be_false
      surface.@header_icon.visible?.should be_true
      trigger(window, DesktopKit::Action::NewSplit.new(:right))
      settle
      WindowStyleSpecLib.adw_tab_page_get_icon(page).null?.should be_true
      trigger(window, DesktopKit::Action::GotoSplit.new(:previous))
      settle
      WindowStyleSpecLib.adw_tab_page_get_icon(page).null?.should be_false
      surface.icon = nil
      WindowStyleSpecLib.adw_tab_page_get_icon(page).null?.should be_true
      surface.@header_icon.visible?.should be_false
    end
  end

  it "shows icons from image files" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      surface = window.tabs.first.surfaces.first
      settle
      page = DesktopKit::C.adw_tab_view_get_selected_page(window.@tab_view)
      path = icon_file
      surface.icon = path
      surface.icon.should eq path
      icon_string(WindowStyleSpecLib.adw_tab_page_get_icon(page)).should eq path.to_s
      icon_string(WindowStyleSpecLib.gtk_image_get_gicon(surface.@header_icon)).should eq path.to_s
      surface.icon = "utilities-terminal"
      icon_string(WindowStyleSpecLib.adw_tab_page_get_icon(page)).should eq "utilities-terminal"
    end
  end

  it "moves the tab bar into the header bar and back" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      tab_bar = window.@tab_bar
      inside?(tab_bar, window.@header).should be_false
      app.window_style = DesktopKit::WindowStyle.new(tabs_in_header: true)
      settle
      inside?(tab_bar, window.@header).should be_true
      WindowStyleSpecLib.adw_tab_bar_get_autohide(tab_bar).should eq 0
      other = app.new_window
      inside?(other.@tab_bar, other.@header).should be_true
      app.window_style = DesktopKit::WindowStyle.new
      settle
      inside?(tab_bar, window.@header).should be_false
      WindowStyleSpecLib.adw_tab_bar_get_autohide(tab_bar).should eq 1
    end
  end

  it "hides the header bar and the tab keys without one" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      WindowStyleSpecLib.adw_toolbar_view_get_reveal_top_bars(window.@toolbar).should eq 1
      WindowStyleSpecLib.adw_tab_view_get_shortcuts(window.@tab_view).should eq DesktopKit::C::AdwTabViewShortcuts::AllShortcuts.value
      app.window_style = DesktopKit::WindowStyle.new(header_bar: false)
      WindowStyleSpecLib.adw_toolbar_view_get_reveal_top_bars(window.@toolbar).should eq 0
      window.@header.visible?.should be_false
      window.@tab_bar.visible?.should be_false
      WindowStyleSpecLib.adw_tab_view_get_shortcuts(window.@tab_view).should eq 0
      other = app.new_window
      WindowStyleSpecLib.adw_toolbar_view_get_reveal_top_bars(other.@toolbar).should eq 0
      app.window_style = DesktopKit::WindowStyle.new
      WindowStyleSpecLib.adw_toolbar_view_get_reveal_top_bars(window.@toolbar).should eq 1
      window.@header.visible?.should be_true
      window.@tab_bar.visible?.should be_true
      WindowStyleSpecLib.adw_tab_view_get_shortcuts(window.@tab_view).should eq DesktopKit::C::AdwTabViewShortcuts::AllShortcuts.value
    end
  end

  it "takes header bar content and a subtitle" do
    app = TestApp.new
    run_steps(app) do
      window = app.new_window
      settle
      window.subtitle = "Mac Studio"
      window.subtitle.should eq "Mac Studio"
      String.new(WindowStyleSpecLib.adw_window_title_get_subtitle(window.@title_widget)).should eq "Mac Studio"
      window.subtitle = nil
      String.new(WindowStyleSpecLib.adw_window_title_get_subtitle(window.@title_widget)).should be_empty
      label = DesktopKit::Widget.new(DesktopKit::C.gtk_label_new("host"))
      window.pack_start(label)
      inside?(label, window.@header).should be_true
      window.pack_end(DesktopKit::Action::ToggleCommandPalette.new, "system-search-symbolic", "Commands")
      path = icon_file
      window.pack_start(DesktopKit::Action::NewTab.new, path, "New tab")
      settle
      icons = image_icons(window.@header.to_unsafe)
      icons.should contain "system-search-symbolic"
      icons.should contain path.to_s
    end
  end

  it "calls on_window for each new window" do
    app = WindowHookApp.new
    run_steps(app) do
      app.new_window
      trigger(app.windows.first, DesktopKit::Action::NewWindow.new)
      settle
      app.hooked.size.should eq 2
    end
  end
end

class WindowHookApp < TestApp
  getter hooked = [] of DesktopKit::Window

  protected def on_window(window : DesktopKit::Window) : Nil
    @hooked << window
  end
end
