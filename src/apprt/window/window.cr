# src/apprt/window/window.cr
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
    # :nodoc:
    STYLE = <<-CSS
      .key-state { margin: 12px; padding: 6px 12px; border-radius: 8px; font-feature-settings: "tnum"; }
      window.apprt-window.opaque { background-color: @window_bg_color; }
      window.apprt-window.opaque .surface { background-color: @view_bg_color; }
      CSS

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
    @palette : CommandPalette?
    @initial_size = {800, 600}
    @opaque = false
    @tabs_in_header = false
    @subtitle : String?
    @app_id : String?
    @idle_cookie = 0_u32
    @shortcuts_inhibited = false
    @suspended = false

    protected def initialize(@app : App, @panel : Panel? = nil)
      @widget = Widget.new(C.adw_application_window_new(@app))
      C.gtk_window_set_default_size(@widget, *@initial_size)
      if panel = @panel
        Panel.init(@widget)
        panel.apply(@widget)
        @decoration = Decoration::None
      end
      @tab_view = Widget.new(C.adw_tab_view_new)
      @title_widget = Widget.new(C.adw_window_title_new(Window.default_title, ""))
      @overview = Widget.new(C.adw_tab_overview_new)
      @toasts = Widget.new(C.adw_toast_overlay_new)
      @header = Widget.new(C.adw_header_bar_new)
      @title_box = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 12))
      @tab_bar = Widget.new(C.adw_tab_bar_new)
      @toolbar = Widget.new(C.adw_toolbar_view_new)
      @key_state = Widget.new(C.gtk_label_new(nil))
      @widget.add_css_class("apprt-window")
      layout
      apply_style(@app.window_style)
      install_actions
      connect_signals
    end

    # Returns the second line of the window title.
    getter subtitle : String?

    # Sets the second line of the window title in the header bar; `nil`
    # removes it.
    def subtitle=(subtitle : String?) : String?
      @subtitle = subtitle
      C.adw_window_title_set_subtitle(@title_widget, subtitle || "")
      subtitle
    end

    # Adds *widget* to the start of the header bar, after the earlier ones.
    def pack_start(widget : Widget) : Nil
      C.adw_header_bar_pack_start(@header, widget)
    end

    # Adds a button showing *icon* that performs *action* to the start of the
    # header bar.
    def pack_start(action : Action, icon : Icon, tooltip : String) : Nil
      C.adw_header_bar_pack_start(@header, button(icon, tooltip, action))
    end

    # Adds *widget* to the end of the header bar, before the earlier ones.
    def pack_end(widget : Widget) : Nil
      C.adw_header_bar_pack_end(@header, widget)
    end

    # Adds a button showing *icon* that performs *action* to the end of the
    # header bar.
    def pack_end(action : Action, icon : Icon, tooltip : String) : Nil
      C.adw_header_bar_pack_end(@header, button(icon, tooltip, action))
    end

    # Shows or hides the top bars and moves the tab bar between the header
    # bar and the row below it.
    protected def apply_style(style : WindowStyle) : Nil
      header = style.header_bar?
      @header.visible = !@panel
      C.adw_toolbar_view_set_reveal_top_bars(@toolbar, header ? 1 : 0)
      shortcuts = header ? C::AdwTabViewShortcuts::AllShortcuts : C::AdwTabViewShortcuts.new(0)
      C.adw_tab_view_set_shortcuts(@tab_view, shortcuts)
      inside = style.tabs_in_header?
      return if inside == @tabs_in_header
      @tabs_in_header = inside
      C.g_object_ref(@tab_bar)
      if inside
        C.adw_toolbar_view_remove(@toolbar, @tab_bar)
        C.gtk_box_append(@title_box, @tab_bar)
      else
        C.gtk_box_remove(@title_box, @tab_bar)
        C.adw_toolbar_view_add_top_bar(@toolbar, @tab_bar)
      end
      C.g_object_unref(@tab_bar)
      @tab_bar.hexpand = inside
      @title_box.hexpand = inside
      C.adw_tab_bar_set_autohide(@tab_bar, inside ? 0 : 1)
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

    # Returns whether the window fills its monitor without decorations.
    def fullscreen? : Bool
      C.gtk_window_is_fullscreen(@widget) != 0
    end

    # Asks the desktop to show the window fullscreen, or to leave
    # fullscreen; the desktop may refuse.
    def fullscreen=(fullscreen : Bool) : Bool
      fullscreen ? C.gtk_window_fullscreen(@widget) : C.gtk_window_unfullscreen(@widget)
      fullscreen
    end

    # Returns whether the window is maximized.
    def maximized? : Bool
      C.gtk_window_is_maximized(@widget) != 0
    end

    # Asks the desktop to maximize the window, or to restore its size; the
    # desktop may refuse.
    def maximized=(maximized : Bool) : Bool
      maximized ? C.gtk_window_maximize(@widget) : C.gtk_window_unmaximize(@widget)
      maximized
    end

    # Returns whether the user can resize the window.
    def resizable? : Bool
      C.gtk_window_get_resizable(@widget) != 0
    end

    # Sets whether the user can resize the window. A window that is not
    # resizable keeps the size its content asks for.
    def resizable=(resizable : Bool) : Bool
      C.gtk_window_set_resizable(@widget, resizable ? 1 : 0)
      resizable
    end

    # Returns the application id the desktop groups this window under, or
    # `nil` for the application's own.
    getter app_id : String?

    # Sets the application id the desktop groups this window under, for its
    # icon and window rules; `nil` restores the application's own. Raises
    # `ArgumentError` when *app_id* is not a valid application id.
    def app_id=(app_id : String?) : String?
      if app_id && C.g_application_id_is_valid(app_id) == 0
        raise ArgumentError.new("invalid application id: #{app_id.inspect}")
      end
      @app_id = app_id
      sync_app_id
      app_id
    end

    # Returns whether the window keeps the desktop from going idle.
    def idle_inhibited? : Bool
      @idle_cookie != 0
    end

    # Sets whether the window keeps the desktop from going idle (blanking
    # the screen or locking) while it is open; *reason* tells the user why.
    def idle_inhibited=(inhibited : Bool) : Bool
      set_idle_inhibited(inhibited)
    end

    # :ditto:
    def set_idle_inhibited(inhibited : Bool, reason : String? = nil) : Bool
      return inhibited if inhibited == idle_inhibited?
      if inhibited
        @idle_cookie = C.gtk_application_inhibit(@app, @widget, C::GtkApplicationInhibitFlags::Idle, reason)
      else
        release_idle
      end
      inhibited
    end

    # Returns whether the window asked to receive the desktop's own
    # keyboard shortcuts.
    getter? shortcuts_inhibited = false

    # Sets whether the desktop's own keyboard shortcuts reach the window
    # instead of the desktop while it has the focus; the desktop may ask
    # the user first, or refuse.
    def shortcuts_inhibited=(inhibited : Bool) : Bool
      @shortcuts_inhibited = inhibited
      sync_shortcuts
      inhibited
    end

    # Brings the window to the front and gives it the focus with *token*,
    # an activation token another application passed on (such as
    # `XDG_ACTIVATION_TOKEN`), so the desktop does not refuse it.
    def activate(token : String) : Nil
      C.gtk_window_set_startup_id(@widget, token)
      C.gtk_window_present(@widget)
    end

    # Returns the size of the monitor that shows most of the window, in
    # logical pixels, or `nil` while the window is not shown.
    def monitor_size : {Int32, Int32}?
      surface = C.gtk_native_get_surface(@widget)
      return if surface.null?
      monitor = C.gdk_display_get_monitor_at_surface(C.gtk_widget_get_display(@widget), surface)
      return if monitor.null?
      C.gdk_monitor_get_geometry(monitor, out geometry)
      {geometry.width, geometry.height}
    end

    # Returns whether the desktop stopped showing the window, such as on
    # another workspace or minimized; `App#on_window_suspended` reports
    # changes.
    getter? suspended = false

    # Asks the user *heading*, explained by *body*, in a dialog over the
    # window and yields whether they picked *confirm* rather than *cancel*.
    #
    # A *destructive* choice shows in red and is not the default. The block
    # runs once, after the user answers; it does not run when the window
    # closes first.
    #
    # ```
    # window.confirm("Discard Changes?", "The draft will be lost.", confirm: "Discard", destructive: true) do |discard|
    #   draft.clear if discard
    # end
    # ```
    def confirm(heading : String, body : String? = nil, *, confirm : String = "OK", cancel : String = "Cancel",
                destructive : Bool = false, &block : Bool ->) : Nil
      return if @closed
      Dialogs.confirm(@widget, heading, body, confirm, cancel, destructive, &block)
    end

    # Asks the user for a line of text in a dialog over the window, starting
    # from *text*, and yields what they entered when they pick *confirm*.
    #
    # The block does not run when the user cancels or the window closes
    # first.
    #
    # ```
    # window.prompt("Rename Session", text: session.name) { |name| session.name = name }
    # ```
    def prompt(heading : String, body : String? = nil, *, text : String = "", confirm : String = "OK",
               cancel : String = "Cancel", &block : String ->) : Nil
      return if @closed
      Dialogs.prompt(@widget, heading, body, text, confirm, cancel, &block)
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
      add_tab(Tab.new(@app, @app.create_surface(kind, parent)), nil)
    end

    # Inserts *tab* at *position*, or after the selected tab, and selects
    # it.
    protected def add_tab(tab : Tab, position : Int32?) : Tab
      position ||= begin
        selected = C.adw_tab_view_get_selected_page(@tab_view)
        selected.null? ? page_count : C.adw_tab_view_get_page_position(@tab_view, selected) + 1
      end
      page = C.adw_tab_view_insert(@tab_view, tab.root, position.clamp(0, page_count))
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

    # Closes the window without asking.
    protected def destroy : Nil
      return if @closed
      forget
      C.gtk_window_destroy(@widget)
    end

    # Marks the window closed and destroys its tabs, keeping their
    # surfaces for undo.
    private def forget : Nil
      ordered = tabs
      @closed = true
      states = ordered.compact_map { |tab| tab.state unless tab.state.tree.empty? }
      ordered.each(&.destroy(keep: true))
      @app.tabs.each { |tab| tab.destroy if tab.window == self }
      @app.undo_stack.record(UndoStack::ClosedWindow.new(states, @panel)) unless states.empty?
    end

    private def page_count : Int32
      C.adw_tab_view_get_n_pages(@tab_view)
    end

    private def tab_at(index : Int32) : Tab?
      @app.tab_for(C.adw_tab_page_get_child(C.adw_tab_view_get_nth_page(@tab_view, index)))
    end

    private def layout : Nil
      header = @header
      C.gtk_box_append(@title_box, @title_widget)
      C.adw_header_bar_set_title_widget(header, @title_box)
      C.adw_header_bar_pack_start(header, button("tab-new-symbolic", "New Tab", Action::NewTab.new))
      C.gtk_menu_button_set_icon_name(@menu_button, "open-menu-symbolic")
      self.menu = @app.window_menu
      @menu_button.tooltip = "Main Menu"
      C.adw_header_bar_pack_end(header, @menu_button)
      C.adw_header_bar_pack_end(header, button("view-grid-symbolic", "View Open Tabs", Action::ToggleTabOverview.new))

      tab_bar = @tab_bar
      C.adw_tab_bar_set_view(tab_bar, @tab_view)
      C.adw_tab_bar_set_autohide(tab_bar, 1)

      toolbar = @toolbar
      C.adw_toolbar_view_add_top_bar(toolbar, header)
      C.adw_toolbar_view_add_top_bar(toolbar, tab_bar)
      overlay = C.gtk_overlay_new
      C.gtk_overlay_set_child(overlay, @tab_view)
      @key_state.add_css_class("osd")
      @key_state.add_css_class("key-state")
      @key_state.visible = false
      C.gtk_widget_set_can_target(@key_state, 0)
      C.gtk_widget_set_halign(@key_state, C::GtkAlign::End)
      C.gtk_widget_set_valign(@key_state, C::GtkAlign::End)
      C.gtk_overlay_add_overlay(overlay, @key_state)
      C.adw_toast_overlay_set_child(@toasts, overlay)
      C.adw_toolbar_view_set_content(toolbar, @toasts)

      C.adw_tab_overview_set_view(@overview, @tab_view)
      C.adw_tab_overview_set_child(@overview, toolbar)
      C.adw_tab_overview_set_enable_new_tab(@overview, 1)
      C.adw_application_window_set_content(@widget, @overview)
    end

    private def button(icon : Icon, tooltip : String, action : Action) : Void*
      button = C.gtk_button_new
      C.gtk_button_set_child(button, GIcon.image(icon))
      Widget.new(button).add_css_class("image-button")
      C.gtk_actionable_set_detailed_action_name(button, action.detailed_name)
      Widget.new(button).tooltip = tooltip
      button
    end

    # Window actions act on the window; the tab and split groups act on the
    # selected tab and its active surface. The application's private `app`
    # group replaces the exported one.
    private def install_actions : Nil
      @widget.insert_action_group(Action::Scope::App.prefix, @app.actions)
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
      @sequence_keys = C.gtk_event_controller_key_new
      C.gtk_event_controller_set_propagation_phase(@sequence_keys, C::GtkPropagationPhase::Capture)
      Signals.connect(@sequence_keys, "key-pressed", ->(keyval : UInt32, _keycode : UInt32, state : UInt32) : Bool {
        sequence_key(keyval, state)
      })
      @widget.add_controller(@sequence_keys)
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
      Signals.notify(@widget, "is-active", -> do
        self.urgent = false if active?
        panel_focus_changed
      end)
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
      surface = C.gtk_native_get_surface(@widget)
      Signals.notify(surface, "state", -> { sync_suspended })
      sync_app_id
      sync_shortcuts
      sync_decoration
    end

    private def toplevel_state : C::GdkToplevelState
      surface = C.gtk_native_get_surface(@widget)
      surface.null? ? C::GdkToplevelState::None : C.gdk_toplevel_get_state(surface)
    end

    private def sync_suspended : Nil
      suspended = toplevel_state.suspended?
      return if suspended == @suspended
      @suspended = suspended
      @app.window_suspended(self, suspended)
    end

    private def sync_app_id : Nil
      surface = C.gtk_native_get_surface(@widget)
      return if surface.null?
      return unless C.g_type_check_instance_is_a(surface, C.gdk_wayland_toplevel_get_type) != 0
      id = @app_id || Native.string?(C.g_application_get_application_id(@app))
      C.gdk_wayland_toplevel_set_application_id(surface, id) if id
    end

    private def sync_shortcuts : Nil
      surface = C.gtk_native_get_surface(@widget)
      return if surface.null?
      if @shortcuts_inhibited
        C.gdk_toplevel_inhibit_system_shortcuts(surface, nil)
      else
        C.gdk_toplevel_restore_system_shortcuts(surface)
      end
    end

    private def release_idle : Nil
      cookie = @idle_cookie
      return if cookie == 0
      @idle_cookie = 0_u32
      C.gtk_application_uninhibit(@app, cookie)
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
        destroy unless @closed || !empty?
      end
    end

    private def empty? : Bool
      page_count == 0 && C.adw_tab_overview_get_open(@overview) == 0
    end

    private def close_page(page : Void*) : Nil
      tab = @app.tab_for(C.adw_tab_page_get_child(page))
      if tab.nil? || tab.close_unconfirmed?
        position = C.adw_tab_view_get_page_position(@tab_view, page)
        C.adw_tab_view_close_page_finish(@tab_view, page, 1)
        tab.try(&.destroy(position))
        return
      end
      C.g_object_ref(page)
      Dialogs.confirm_close(@widget, :tab) do |confirmed|
        unless @closed
          position = C.adw_tab_view_get_page_position(@tab_view, page)
          C.adw_tab_view_close_page_finish(@tab_view, page, confirmed ? 1 : 0)
          tab.destroy(position) if confirmed
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
      release_idle
      stop_sequence_timer
      forget unless @closed
      @app.unregister(self)
    end
  end
end
