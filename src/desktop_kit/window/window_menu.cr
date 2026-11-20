# src/desktop_kit/window/window_menu.cr
module DesktopKit
  class Window
    @menu_button = Widget.new(C.gtk_menu_button_new)

    # Shows *menu* from the header's menu button.
    protected def menu=(menu : Menu) : Menu
      model = menu.to_model
      C.gtk_menu_button_set_menu_model(@menu_button, model)
      C.g_object_unref(model)
      menu
    end
  end

  abstract class App
    @window_menu : Menu = Menu.window

    # Returns the menu of each window's header; `Menu.window` by default.
    getter window_menu : Menu

    # Replaces the menu of each window's header, the open windows' too.
    def window_menu=(menu : Menu) : Menu
      @window_menu = menu
      UIThread.dispatch { @windows.each(&.menu=(menu)) } if running?
      menu
    end
  end
end
