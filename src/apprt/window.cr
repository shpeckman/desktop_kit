# src/apprt/window.cr
module Apprt
  # An application window: tabs of surfaces under a header bar, after
  # Ghostty's gtk/class/window.zig.
  #
  # The header bar has a new-tab button, a tab overview button and the
  # window menu; the tab bar shows while the window has more than one tab.
  # A window closes with its last tab. Window actions act on the window, tab
  # actions on its selected tab and split actions on that tab's active
  # surface. Use it on the GTK thread only.
  class Window
    private record Item, label : String, action : Action

    # Sections of the window menu.
    private MENU = [
      [Item.new("New Window", Action::NewWindow.new), Item.new("New Tab", Action::NewTab.new)],
      [
        Item.new("Split Up", Action::NewSplit.new(:up)),
        Item.new("Split Down", Action::NewSplit.new(:down)),
        Item.new("Split Left", Action::NewSplit.new(:left)),
        Item.new("Split Right", Action::NewSplit.new(:right)),
      ],
      [
        Item.new("Change Title…", Action::PromptTitle.new(:surface)),
        Item.new("Change Tab Title…", Action::PromptTitle.new(:tab)),
        Item.new("Change Window Title…", Action::PromptTitle.new(:window)),
      ],
      [Item.new("Close Tab", Action::CloseTab.new(:this)), Item.new("Close Window", Action::CloseWindow.new)],
    ]

    # The title the user chose; shown instead of the tab titles while set.
    getter title_override : String?

    # :nodoc:
    # The `AdwApplicationWindow`.
    getter widget : Widget

    protected getter tab_view : Widget

    # Returns how the window is decorated.
    getter decoration = Decoration::Auto

    getter? background_blur = false

    # Returns whether the window asks for the user's attention.
    getter? urgent = false

    @closed = false
    @destroy_pending = false
    @restored_decoration = Decoration::Auto
    @winproto : Winproto?

    protected def initialize(@app : App)
      @widget = Widget.new(C.adw_application_window_new(@app))
      C.gtk_window_set_default_size(@widget, 800, 600)
      @tab_view = Widget.new(C.adw_tab_view_new)
      @title_widget = Widget.new(C.adw_window_title_new(Window.default_title, ""))
      @overview = Widget.new(C.adw_tab_overview_new)
      @toasts = Widget.new(C.adw_toast_overlay_new)
      layout
      install_actions
      connect_signals
    end

    # Returns the title the application name falls back to.
    protected def self.default_title : String
      Native.string?(C.g_get_application_name) || ""
    end

    # Returns the title: `#title_override`, else the title of the selected
    # tab, else the application name.
    def title : String
      @title_override || active_tab.try(&.title) || Window.default_title
    end

    # Sets the title the user chose; `nil` restores the tab titles.
    def title_override=(title : String?) : String?
      @title_override = title
      sync_title
      title
    end

    # Sets how the window is decorated.
    def decoration=(decoration : Decoration) : Decoration
      @decoration = decoration
      sync_decoration
      decoration
    end

    # Sets whether the compositor blurs what shows through the translucent
    # parts of the window. Needs a compositor with the
    # `ext-background-effect-v1` Wayland protocol; elsewhere it has no
    # effect.
    def background_blur=(blur : Bool) : Bool
      @background_blur = blur
      sync_blur
      blur
    end

    # Sets whether the window asks for the user's attention; ignored while
    # the window is active, and cleared when it becomes active.
    def urgent=(urgent : Bool) : Bool
      urgent = false if active?
      return urgent if urgent == @urgent
      @urgent = urgent
      @winproto.try(&.urgent=(urgent))
      urgent
    end

    # Returns whether the window has the keyboard focus of the desktop.
    def active? : Bool
      C.gtk_window_is_active(@widget) != 0
    end

    # Shows *message* in a toast at the bottom of the window for *timeout*,
    # rounded up to whole seconds.
    def toast(message : String, timeout : Time::Span = 3.seconds) : Nil
      return if @closed
      toast = C.adw_toast_new(message)
      C.adw_toast_set_timeout(toast, timeout.total_seconds.ceil.to_u32)
      C.adw_toast_overlay_add_toast(@toasts, toast)
    end

    # Returns the tabs in their order on the tab bar.
    def tabs : Array(Tab)
      return [] of Tab if @closed
      (0...page_count).compact_map { |index| tab_at(index) }
    end

    # Returns the selected tab.
    def active_tab : Tab?
      return if @closed
      page = C.adw_tab_view_get_selected_page(@tab_view)
      @app.tab_for(C.adw_tab_page_get_child(page)) unless page.null?
    end

    # Returns the active surface of the selected tab.
    def active_surface : Surface?
      active_tab.try(&.active_surface)
    end

    def closed? : Bool
      @closed
    end

    # Opens a tab after the selected one, from its active surface, selects it
    # and returns it. Raises `RuntimeError` when the window is closed.
    def new_tab : Tab
      open_tab(:tab, active_surface)
    end

    # Brings the window to the front.
    def present : Nil
      C.gtk_window_present(@widget) unless @closed
    end

    # Closes the window, asking the user first when one of its surfaces has
    # `Surface#confirm_close?`.
    def close : Nil
      return if @closed
      if tabs.all?(&.close_unconfirmed?)
        destroy
      else
        Dialogs.confirm_close(@widget, :window) { |confirmed| destroy if confirmed }
      end
    end

    protected def open_tab(kind : SurfaceContext::Kind, parent : Surface?) : Tab
      raise RuntimeError.new("the window is closed") if @closed
      tab = Tab.new(@app, @app.create_surface(kind, parent))
      selected = C.adw_tab_view_get_selected_page(@tab_view)
      position = selected.null? ? page_count : C.adw_tab_view_get_page_position(@tab_view, selected) + 1
      page = C.adw_tab_view_insert(@tab_view, tab.root, position)
      C.adw_tab_view_set_selected_page(@tab_view, page)
      tab.sync_title
      tab
    end

    protected def select(tab : Tab) : Nil
      page = tab.page(self)
      C.adw_tab_view_set_selected_page(@tab_view, page) unless @closed || page.null?
    end

    # Selects the tab at *index*, counted from 0, or `Action::GotoTab::PREVIOUS`,
    # `NEXT` or `LAST`; the previous and next tabs wrap around.
    protected def goto_tab(index : Int32) : Bool
      total = page_count
      return false if total == 0
      selected = C.adw_tab_view_get_selected_page(@tab_view)
      current = selected.null? ? 0 : C.adw_tab_view_get_page_position(@tab_view, selected)
      target =
        case index
        when Action::GotoTab::PREVIOUS then current > 0 ? current - 1 : total - 1
        when Action::GotoTab::NEXT     then current + 1 < total ? current + 1 : 0
        when Action::GotoTab::LAST     then total - 1
        else
          return false if index < 0
          Math.min(index, total - 1)
        end
      return false if target == current
      C.adw_tab_view_set_selected_page(@tab_view, C.adw_tab_view_get_nth_page(@tab_view, target))
      true
    end

    # Moves *tab* by *amount* positions, wrapping around the ends.
    protected def move_tab(tab : Tab, amount : Int32) : Bool
      page = tab.page(self)
      return false if page.null?
      position = C.adw_tab_view_get_page_position(@tab_view, page)
      max = page_count - 1
      target = position.to_i64 + amount
      target += max + 1 if target < 0
      target -= max + 1 if target > max
      target = target.clamp(0, max).to_i
      return false if target == position
      C.adw_tab_view_reorder_page(@tab_view, page, target) != 0
    end

    protected def move_to_new_window(tab : Tab) : Bool
      page = tab.page(self)
      return false if page.null? || page_count < 2
      window = @app.open_window
      C.adw_tab_view_transfer_page(@tab_view, page, window.tab_view, 0)
      window.present
      true
    end

    protected def close_tabs(tab : Tab, mode : Action::CloseTab::Mode) : Bool
      page = tab.page(self)
      return false if @closed || page.null?
      case mode
      in .this?  then C.adw_tab_view_close_page(@tab_view, page)
      in .other? then C.adw_tab_view_close_other_pages(@tab_view, page)
      in .right? then C.adw_tab_view_close_pages_after(@tab_view, page)
      end
      true
    end

    # The selected page no longer needs attention.
    private def selected_changed : Nil
      page = C.adw_tab_view_get_selected_page(@tab_view)
      C.adw_tab_page_set_needs_attention(page, 0) unless page.null?
      sync_title
    end

    protected def sync_title : Nil
      return if @closed
      title = self.title
      C.gtk_window_set_title(@widget, title)
      C.adw_window_title_set_title(@title_widget, title)
    end

    protected def toggle_maximized : Nil
      if C.gtk_window_is_maximized(@widget) != 0
        C.gtk_window_unmaximize(@widget)
      else
        C.gtk_window_maximize(@widget)
      end
    end

    protected def toggle_fullscreen : Nil
      if C.gtk_window_is_fullscreen(@widget) != 0
        C.gtk_window_unfullscreen(@widget)
      else
        C.gtk_window_fullscreen(@widget)
      end
    end

    # Hides the decorations, or restores the ones they replaced.
    protected def toggle_decorations : Nil
      if @decoration.none?
        self.decoration = @restored_decoration
      else
        @restored_decoration = @decoration
        self.decoration = :none
      end
    end

    protected def toggle_overview : Nil
      C.adw_tab_overview_set_open(@overview, C.adw_tab_overview_get_open(@overview) != 0 ? 0 : 1)
    end

    protected def default_size(width : Int32, height : Int32) : Nil
      C.gtk_window_set_default_size(@widget, width, height)
    end

    # Sets the smallest size; 0 leaves a dimension unlimited.
    protected def min_size(width : Int32, height : Int32) : Nil
      @widget.size_request(width > 0 ? width : -1, height > 0 ? height : -1)
    end

    # Grows or shrinks the window so that its only surface gets *width* by
    # *height* pixels. Does nothing while the window is maximized or
    # fullscreen, or shows more than one surface.
    protected def resize(width : Int32, height : Int32) : Bool
      return false if C.gtk_window_is_maximized(@widget) != 0 || C.gtk_window_is_fullscreen(@widget) != 0
      return false unless page_count == 1
      surfaces = tabs.first?.try(&.surfaces) || return false
      return false unless surfaces.size == 1
      host = surfaces.first.host
      return false unless host.mapped?
      default_size(@widget.width + width - host.width, @widget.height + height - host.height)
      true
    end

    # Closes the window without asking.
    protected def destroy : Nil
      return if @closed
      forget
      C.gtk_window_destroy(@widget)
    end

    # Marks the window closed and destroys its tabs.
    private def forget : Nil
      @closed = true
      @app.tabs.each { |tab| tab.destroy if tab.window == self }
    end

    private def page_count : Int32
      C.adw_tab_view_get_n_pages(@tab_view)
    end

    private def tab_at(index : Int32) : Tab?
      @app.tab_for(C.adw_tab_page_get_child(C.adw_tab_view_get_nth_page(@tab_view, index)))
    end

    private def layout : Nil
      header = C.adw_header_bar_new
      C.adw_header_bar_set_title_widget(header, @title_widget)
      C.adw_header_bar_pack_start(header, button("tab-new-symbolic", "New Tab", Action::NewTab.new))
      menu = C.gtk_menu_button_new
      C.gtk_menu_button_set_icon_name(menu, "open-menu-symbolic")
      model = menu_model
      C.gtk_menu_button_set_menu_model(menu, model)
      C.g_object_unref(model)
      Widget.new(menu).tooltip = "Main Menu"
      C.adw_header_bar_pack_end(header, menu)
      C.adw_header_bar_pack_end(header, button("view-grid-symbolic", "View Open Tabs", Action::ToggleTabOverview.new))

      tab_bar = C.adw_tab_bar_new
      C.adw_tab_bar_set_view(tab_bar, @tab_view)
      C.adw_tab_bar_set_autohide(tab_bar, 1)

      toolbar = C.adw_toolbar_view_new
      C.adw_toolbar_view_add_top_bar(toolbar, header)
      C.adw_toolbar_view_add_top_bar(toolbar, tab_bar)
      C.adw_toast_overlay_set_child(@toasts, @tab_view)
      C.adw_toolbar_view_set_content(toolbar, @toasts)

      C.adw_tab_overview_set_view(@overview, @tab_view)
      C.adw_tab_overview_set_child(@overview, toolbar)
      C.adw_tab_overview_set_enable_new_tab(@overview, 1)
      C.adw_application_window_set_content(@widget, @overview)
    end

    private def button(icon : String, tooltip : String, action : Action) : Void*
      button = C.gtk_button_new_from_icon_name(icon)
      C.gtk_actionable_set_detailed_action_name(button, action.detailed_name)
      Widget.new(button).tooltip = tooltip
      button
    end

    private def menu_model : Void*
      menu = C.g_menu_new
      MENU.each do |items|
        section = C.g_menu_new
        items.each { |item| C.g_menu_append(section, item.label, item.action.detailed_name) }
        C.g_menu_append_section(menu, nil, section)
        C.g_object_unref(section)
      end
      menu
    end

    # Window actions act on the window; the tab and split groups act on the
    # selected tab and its active surface.
    private def install_actions : Nil
      Action.install(@widget.to_unsafe, :window) { |action| @app.dispatch(self, action) }
      install_group(Action::Scope::Tab) { |action| (tab = active_tab) ? @app.dispatch(tab, action) : false }
      install_group(Action::Scope::Split) { |action| (surface = active_surface) ? @app.dispatch(surface, action) : false }
    end

    private def install_group(scope : Action::Scope, &perform : Action -> Bool) : Nil
      group = C.g_simple_action_group_new
      Action.install(group, scope, &perform)
      @widget.insert_action_group(scope.prefix, group)
      C.g_object_unref(group)
    end

    private def connect_signals : Nil
      Signals.connect(@tab_view, "page-attached", ->(page : Void*, _position : Int32) { attached(page) })
      Signals.notify(@tab_view, "n-pages", -> { pages_changed })
      Signals.notify(@tab_view, "selected-page", -> { selected_changed })
      Signals.connect(@tab_view, "close-page", ->(page : Void*) : Bool { close_page(page); true })
      Signals.connect(@tab_view, "create-window", -> : Void* { create_window })
      Signals.connect(@overview, "create-tab", -> : Void* { new_tab.page(self) })
      Signals.notify(@overview, "open", -> { pages_changed })
      Signals.connect(@widget, "close-request", -> : Bool { close; true })
      Signals.connect(@widget, "destroy", -> { destroyed })
      Signals.connect(@widget, "realize", -> { realized })
      Signals.connect(@widget, "unrealize", -> { unrealized })
      Signals.notify(@widget, "is-active", -> { self.urgent = false if active? })
    end

    # Attaches the Wayland extras to the new surface and applies the
    # decoration, blur and urgency to it.
    private def realized : Nil
      if winproto = Winproto.attach(@widget)
        @winproto = winproto
        surface = C.gtk_native_get_surface(@widget)
        Signals.connect(surface, "layout", ->(_width : Int32, _height : Int32) { sync_blur })
        Signals.notify(surface, "state", -> { sync_blur })
        winproto.urgent = true if @urgent
      end
      sync_decoration
    end

    private def unrealized : Nil
      @winproto.try(&.release)
      @winproto = nil
    end

    private def sync_decoration : Nil
      winproto = @winproto
      csd = winproto ? winproto.client_side?(@decoration) : !@decoration.none?
      C.gtk_window_set_decorated(@widget, csd ? 1 : 0)
      winproto.try(&.sync_decoration(@decoration))
      sync_blur
    end

    private def sync_blur : Nil
      @winproto.try(&.sync_blur(@background_blur, C.gtk_window_get_decorated(@widget) != 0))
    end

    private def attached(page : Void*) : Nil
      @app.tab_for(C.adw_tab_page_get_child(page)).try do |tab|
        tab.window = self
        tab.sync_title
      end
    end

    # Closes the window once its last tab is gone and the overview is shut.
    private def pages_changed : Nil
      return if @closed
      sync_title
      return if @destroy_pending || !empty?
      @destroy_pending = true
      Idle.add do
        @destroy_pending = false
        destroy if empty?
      end
    end

    private def empty? : Bool
      page_count == 0 && C.adw_tab_overview_get_open(@overview) == 0
    end

    private def close_page(page : Void*) : Nil
      tab = @app.tab_for(C.adw_tab_page_get_child(page))
      if tab.nil? || tab.close_unconfirmed?
        C.adw_tab_view_close_page_finish(@tab_view, page, 1)
        tab.try(&.destroy)
        return
      end
      C.g_object_ref(page)
      Dialogs.confirm_close(@widget, :tab) do |confirmed|
        unless @closed
          C.adw_tab_view_close_page_finish(@tab_view, page, confirmed ? 1 : 0)
          tab.destroy if confirmed
        end
        C.g_object_unref(page)
      end
    end

    private def create_window : Void*
      window = @app.open_window
      window.present
      window.tab_view.to_unsafe
    end

    private def destroyed : Nil
      forget unless @closed
      @app.unregister(self)
    end
  end

  abstract class App
    protected def perform(target : Window, action : Action::CloseWindow) : Bool
      target.close
      true
    end

    protected def perform(target : Window, action : Action::ToggleMaximize) : Bool
      target.toggle_maximized
      true
    end

    protected def perform(target : Window, action : Action::ToggleFullscreen) : Bool
      target.toggle_fullscreen
      true
    end

    protected def perform(target : Window, action : Action::ToggleWindowDecorations) : Bool
      target.toggle_decorations
      true
    end

    protected def perform(target : Window, action : Action::ToggleTabOverview) : Bool
      target.toggle_overview
      true
    end

    protected def perform(target : Window, action : Action::GotoWindow) : Bool
      return false if @windows.size < 2
      index = @windows.index(target) || return false
      step = action.direction.next? ? 1 : -1
      @windows[(index + step) % @windows.size].present
      true
    end

    protected def perform(target : Window, action : Action::SetWindowTitle) : Bool
      target.title_override = action.title
      true
    end

    protected def perform(target : Window, action : Action::InitialSize) : Bool
      target.default_size(action.width.to_i32, action.height.to_i32)
      true
    end

    protected def perform(target : Window, action : Action::SizeLimit) : Bool
      target.min_size(action.min_width.to_i32, action.min_height.to_i32)
      true
    end

    protected def perform(target : Window, action : Action::ResizeWindow) : Bool
      target.resize(action.width.to_i32, action.height.to_i32)
    end

    protected def perform(target : Window, action : Action::SetWindowTheme) : Bool
      self.appearance = action.appearance
      true
    end

    protected def perform(target : Window, action : Action::NewTab) : Bool
      target.new_tab
      true
    end

    protected def perform(target : Window, action : Action::GotoTab) : Bool
      target.goto_tab(action.index)
    end
  end
end
