# src/desktop_kit/window/surface.cr
module DesktopKit
  # A pane of a tab showing one `Content`.
  #
  # The runtime opens surfaces for new windows, tabs and splits and asks
  # `App#new_surface` for their content. A surface lives until it closes. Use
  # it on the GTK thread only.
  class Surface
    @@last_id = 0_u64

    # Returns the identifier, unique within the process; `App#surface` finds
    # the surface by it.
    getter id : UInt64

    getter content : Content

    # The title the content reports.
    getter title : String = ""

    # The title the user chose; shown instead of `#title` while set.
    getter title_override : String?

    # Whether closing the surface asks the user first. While any surface
    # asks, the application also asks the desktop not to log out.
    getter? confirm_close : Bool = false

    # :ditto:
    def confirm_close=(confirm : Bool) : Bool
      return confirm if confirm == @confirm_close
      @confirm_close = confirm
      @app.sync_logout_inhibit
      confirm
    end

    # Returns the CSS name of the pointer shown over the surface, such as
    # `"text"`, or `nil` for the default pointer.
    getter cursor : String?

    # Whether the pointer shows over the surface.
    getter? mouse_visible : Bool = true

    # Whether the bell rang while the surface was not focused; it rings until
    # the surface gets the focus.
    getter? bell_ringing : Bool = false

    # Whether the surface holds its window's keyboard focus.
    getter? focused : Bool = false

    # The message of the banner across the surface; nil while none shows.
    getter banner : String?

    @banner_action : Proc(Nil)? = nil

    # :nodoc:
    # The style of the pane header, the drag handle, the drop indicator and
    # floating surfaces, which the app loads at application priority.
    STYLE = <<-CSS
      .surface-header { padding: 2px 4px 2px 10px; }
      .surface-read-only { margin: 8px; padding: 6px; border-radius: 6px; }
      .surface-bell-border { border: 3px solid alpha(@accent_bg_color, 0.5); }
      .surface-progress.paused progress { background-color: @warning_bg_color; }
      .surface-progress.error progress { background-color: @error_bg_color; }
      .surface-drag-handle {
        background-color: alpha(@window_fg_color, 0.15);
        opacity: 0;
        transition: opacity 0.1s;
      }
      .surface-drag-handle:hover { opacity: 1; }
      .surface-drop-indicator { opacity: 0; }
      .canvas-frame { transform: scaleY(-1); }
      .surface-search { padding: 6px; border-radius: 8px; }
      .surface-size { padding: 6px 12px; border-radius: 6px; }
      .surface-pick { padding: 12px 24px; border-radius: 12px; font-size: 2.5em; font-weight: bold; }
      .surface-hover { margin: 4px; padding: 2px 8px; border-radius: 6px; }
      .surface-drop-indicator.drop-left { opacity: 1; background: linear-gradient(to right, alpha(@accent_bg_color, 0.3) 50%, transparent 50%); }
      .surface-drop-indicator.drop-right { opacity: 1; background: linear-gradient(to left, alpha(@accent_bg_color, 0.3) 50%, transparent 50%); }
      .surface-drop-indicator.drop-up { opacity: 1; background: linear-gradient(to bottom, alpha(@accent_bg_color, 0.3) 50%, transparent 50%); }
      .surface-drop-indicator.drop-down { opacity: 1; background: linear-gradient(to top, alpha(@accent_bg_color, 0.3) 50%, transparent 50%); }
      window.desktop-kit-window .surface.floating {
        margin: 0;
        border-radius: 12px;
        background-color: @view_bg_color;
        box-shadow: 0 0 0 1px alpha(@borders, 0.6), 0 6px 18px alpha(black, 0.3);
      }
      .surface-float-grip { min-width: 16px; min-height: 16px; }
      CSS

    @tab : Tab?
    @closed = false
    @floating = false
    @icon : Icon?

    protected def initialize(@app : App, @content : Content)
      raise ArgumentError.new("the content already belongs to a surface") if @content.surface?
      @id = @@last_id += 1
      # Own ref (sunk): host survives split rebuilds unparented; `release` drops it.
      @host = Widget.new(C.g_object_ref_sink(C.adw_bin_new))
      @host.add_css_class("surface")
      @host.hexpand = true
      @host.vexpand = true
      @handle = Widget.new(C.gtk_center_box_new)
      @drop_indicator = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 0))
      @header = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 6))
      @header_icon = Widget.new(C.gtk_image_new_from_icon_name(nil))
      @header_title = Widget.new(C.gtk_label_new(Window.default_title))
      @stack_badge = Widget.new(C.gtk_label_new(nil))
      @read_only_badge = Widget.new(C.gtk_image_new_from_icon_name("changes-prevent-symbolic"))
      @progress_bar = Widget.new(C.gtk_progress_bar_new)
      @bell_border = Widget.new(C.gtk_revealer_new)
      @banner_bar = Widget.new(C.adw_banner_new(""))
      @overlay = C.gtk_overlay_new
      layout
      apply_style(@app.window_style)
      install_drag_and_drop
      focus = C.gtk_event_controller_focus_new
      Signals.connect(focus, "enter", -> { focus_changed(true) })
      Signals.connect(focus, "leave", -> { focus_changed(false) })
      @host.add_controller(focus)
      @notifications = Notifications.new(@app.to_unsafe, @id)
      @content.surface = self
    end

    def title=(title : String) : String
      @title = title
      sync_title
      title
    end

    # Returns the icon shown in the pane header and on the tab while the
    # surface is active.
    getter icon : Icon?

    # Sets the icon: a themed icon name such as `"utilities-terminal"` or
    # the `Path` of an image file; `nil` removes it.
    def icon=(icon : Icon?) : Icon?
      @icon = icon
      GIcon.set(@header_icon, icon)
      @header_icon.visible = !icon.nil?
      @tab.try(&.sync_title)
      icon
    end

    # Returns whether the surface is marked read-only.
    getter? read_only = false

    # Returns the progress shown on the surface, or nil.
    getter progress : Progress? = nil

    @pulse = 0_u32

    # Shows *progress* as a bar along the top of the surface, a spinner on
    # its tab and the taskbar entry's progress; nil removes it.
    def progress=(progress : Progress?) : Progress?
      @progress = progress
      return progress if @closed
      sync_progress
      @tab.try(&.sync_progress)
      @app.sync_progress
      progress
    end

    # Marks the surface read-only, which shows a lock over it, or writable.
    # The content decides what read-only stops; it reads `#read_only?`.
    def read_only=(read_only : Bool) : Bool
      @read_only = read_only
      @read_only_badge.visible = read_only
      read_only ? @host.add_css_class("read-only") : @host.remove_css_class("read-only") unless @closed
      read_only
    end

    # Sets the title the user chose; `nil` restores `#title`.
    def title_override=(title : String?) : String?
      @title_override = title
      sync_title
      title
    end

    # Returns the tab showing the surface, or `nil` once it is closed.
    def tab : Tab?
      @tab
    end

    # Returns the window showing the surface, or `nil` once it is closed.
    def window : Window?
      @tab.try(&.window)
    end

    def closed? : Bool
      @closed
    end

    # Sets the pointer shown over the surface by its CSS name, such as
    # `"text"` or `"pointer"`; `nil` restores the default pointer.
    def cursor=(name : String?) : String?
      @cursor = name
      sync_cursor
      name
    end

    # Shows or hides the pointer over the surface.
    def mouse_visible=(visible : Bool) : Bool
      @mouse_visible = visible
      sync_cursor
      visible
    end

    # Rings the bell as `App#bell` says: beeps, plays `App#bell_sound` and,
    # unless the surface is focused, marks it until it gets the focus: a
    # border, a bell before the tab title, and a request for the user's
    # attention while its window is inactive (`Window#urgent=`).
    def ring_bell : Nil
      return if @closed
      bell = @app.bell
      if bell.system?
        @host.native.try do |native|
          surface = C.gtk_native_get_surface(native)
          C.gdk_surface_beep(surface) unless surface.null?
        end
      end
      @app.play_bell_sound if bell.audio?
      return if @focused || @bell_ringing
      @bell_ringing = true
      C.gtk_revealer_set_reveal_child(@bell_border, bell.border? ? 1 : 0)
      @tab.try(&.bell(bell.attention?))
      window.try(&.urgent=(true)) if bell.attention?
    end

    # Shows *message* in a banner across the bottom of the surface, with a
    # *button* that runs the block.
    #
    # The banner stays until `#hide_banner` or the next `#show_banner`.
    def show_banner(message : String, button : String, &action : ->) : Nil
      show_banner(message, button, action)
    end

    # Shows *message* in a banner across the bottom of the surface.
    #
    # The banner stays until `#hide_banner` or the next `#show_banner`.
    def show_banner(message : String) : Nil
      show_banner(message, nil, nil)
    end

    # Hides the banner.
    def hide_banner : Nil
      @banner = nil
      @banner_action = nil
      C.adw_banner_set_revealed(@banner_bar, 0) unless @closed
    end

    # Asks the user to allow *request* with *text*, the clipboard text it
    # concerns, and yields whether they did. Yields `false` when the surface
    # has no window.
    def confirm_clipboard(request : Clipboard::Request, text : String, &done : Bool ->) : Nil
      # Parent = window, not host: a fresh surface's host stays unparented
      # until the split view rebuilds.
      parent = window.try(&.widget)
      return done.call(false) if @closed || parent.nil?
      Dialogs.confirm_clipboard(parent, request, text, &done)
    end

    # Asks the input method to show its on-screen keyboard; returns whether
    # it did. Only `Canvas` content has one.
    def show_on_screen_keyboard : Bool
      !@closed && @content.show_on_screen_keyboard
    end

    # Focuses the surface: selects its tab and moves the keyboard focus to
    # it, ending a zoom on another surface.
    def focus : Nil
      @tab.try(&.activate(self))
    end

    # Trades places with *other*, a surface of the same tab, and returns
    # whether it could; the focus stays where it was.
    def swap_with(other : Surface) : Bool
      tab = @tab || return false
      return false unless other.tab.same?(tab)
      tab.swap(self, other)
    end

    # Focuses the surface and raises its window.
    def present : Nil
      tab = @tab || return
      tab.activate(self)
      tab.window.try(&.present)
    end

    # Shows a desktop notification from the surface; clicking it presents
    # the surface. Sending the same *title* and *body* again replaces it.
    #
    # One sent while the surface is focused is withdrawn after a few seconds;
    # all are withdrawn once the surface gets the focus or closes.
    def notify(title : String, body : String) : Nil
      @notifications.send(title, body, @focused) unless @closed
    end

    # Opens a new surface beside this one, or beside the split focused last
    # when this one floats, in *direction*, focuses it and returns it.
    # Raises `RuntimeError` when the surface is closed.
    def split(direction : Direction) : Surface
      tab = @tab || raise RuntimeError.new("the surface is closed")
      tab.split(self, direction)
    end

    # Returns whether the surface floats over its tab instead of filling a
    # split.
    def floating? : Bool
      @floating
    end

    # Returns the bounds of a floating surface in fractions of its tab area,
    # else `nil`.
    def float_bounds : Bounds?
      @tab.try(&.floating(self)).try(&.bounds)
    end

    # Lifts the surface out of the splits to float over its tab at *bounds*,
    # fractions of the tab area, or cascaded near the middle, and focuses it;
    # moves a floating surface to *bounds*. False for the tab's only split
    # or a closed surface.
    def float(bounds : Bounds? = nil) : Bool
      @tab.try(&.float(self, bounds)) || false
    end

    # Splits a floating surface back in beside the split under its centre
    # and focuses it. False when the surface does not float.
    def tile : Bool
      @tab.try(&.tile(self)) || false
    end

    # Returns whether `Action::ResizeSplit` in *direction* makes the surface
    # larger. False when nothing would resize it along that axis.
    def grows?(direction : Direction) : Bool
      @tab.try(&.grows?(self, direction)) || false
    end

    # Returns whether the surface shares its split with other surfaces, one
    # shown at a time.
    def stacked? : Bool
      @tab.try(&.stacked?(self)) || false
    end

    # Returns the surfaces stacked with this one, itself included, in order;
    # just itself when it is not stacked.
    def stack : Array(Surface)
      @tab.try(&.stack(self)) || [self]
    end

    # Moves the surface into the stack of the split next to it in
    # *direction*, the split becoming a stack if it is none, shows it and
    # focuses it. False for a floating surface or without a split there.
    def stack_into(direction : Direction) : Bool
      @tab.try(&.stack_into(self, direction)) || false
    end

    # Moves the surface into the stack of the split *other* fills, the split
    # becoming a stack if it is none, shows it and focuses it. False unless
    # *other* is another split of the same tab.
    def stack_with(other : Surface) : Bool
      tab = @tab || return false
      return false unless other.tab == tab
      tab.stack_with(self, other)
    end

    # Takes the stacked surface out of its stack to split the stack's place
    # with it, beside the stack along *layout*, and focuses it. False when
    # the surface is not stacked.
    def unstack(layout : Action::Unstack::Layout = :auto) : Bool
      @tab.try(&.unstack(self, layout)) || false
    end

    # Closes the surface, asking the user first when `#confirm_close?`.
    # Closing the last surface of a tab closes the tab.
    def close : Nil
      tab = @tab || return
      return tab.remove(self) unless confirm_close?
      kind = tab.surfaces.size > 1 ? Dialogs::Close::Split : Dialogs::Close::Tab
      Dialogs.confirm_close(@host, kind) { |confirmed| tab.remove(self) if confirmed }
    end

    # The title shown for the surface, or nil when it has none.
    protected def shown_title : String?
      @title_override || (@title unless @title.empty?)
    end

    # The widget the surface's splits place: a bin around the content's
    # widget, holding a reference of its own so that it survives the split
    # rebuilds that unparent it.
    protected def host : Widget
      @host
    end

    protected def tab=(tab : Tab?) : Tab?
      @tab = tab
    end

    # Shows the place of a stacked surface in its stack, counted from 1, in
    # the pane header; `nil` hides it.
    protected def stack_position=(position : {Int32, Int32}?) : {Int32, Int32}?
      if position
        C.gtk_label_set_label(@stack_badge, "#{position[0]}/#{position[1]}")
      end
      @stack_badge.visible = !position.nil?
      position
    end

    # Shows or hides the pane header; a floating surface keeps it, to be
    # dragged by.
    protected def apply_style(style : WindowStyle) : Nil
      @header.visible = style.pane_headers? || @floating
    end

    # Marks the surface as its tab's active one, for styling.
    protected def active=(active : Bool) : Bool
      return active if @closed
      active ? @host.add_css_class("active") : @host.remove_css_class("active")
      active
    end

    # Moves the keyboard focus to the content when it is on screen.
    protected def grab_focus : Nil
      @content.widget.grab_focus if !@closed && @host.mapped?
    end

    # Stacks the content under the drag handle and the drop indicator.
    private def layout : Nil
      overlay = @overlay
      C.gtk_overlay_set_child(overlay, @content.widget)
      image = C.gtk_image_new_from_icon_name("view-more-horizontal-symbolic")
      C.gtk_center_box_set_center_widget(@handle, image)
      @handle.add_css_class("surface-drag-handle")
      @handle.cursor_name = "grab"
      @handle.visible = false
      C.gtk_widget_set_valign(@handle, C::GtkAlign::Start)
      C.gtk_overlay_add_overlay(overlay, @handle)
      @drop_indicator.add_css_class("surface-drop-indicator")
      C.gtk_widget_set_can_target(@drop_indicator, 0)
      C.gtk_overlay_add_overlay(overlay, @drop_indicator)
      @progress_bar.add_css_class("osd")
      @progress_bar.add_css_class("surface-progress")
      @progress_bar.visible = false
      C.gtk_widget_set_can_target(@progress_bar, 0)
      C.gtk_widget_set_valign(@progress_bar, C::GtkAlign::Start)
      C.gtk_progress_bar_set_pulse_step(@progress_bar, 0.1)
      C.gtk_overlay_add_overlay(overlay, @progress_bar)
      @read_only_badge.add_css_class("osd")
      @read_only_badge.add_css_class("surface-read-only")
      @read_only_badge.tooltip = DesktopKit.tr("Read-only")
      @read_only_badge.visible = false
      C.gtk_widget_set_halign(@read_only_badge, C::GtkAlign::End)
      C.gtk_widget_set_valign(@read_only_badge, C::GtkAlign::Start)
      C.gtk_overlay_add_overlay(overlay, @read_only_badge)
      bell_border = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 0))
      bell_border.add_css_class("surface-bell-border")
      C.gtk_revealer_set_child(@bell_border, bell_border)
      C.gtk_revealer_set_transition_type(@bell_border, C::GtkRevealerTransitionType::Crossfade)
      C.gtk_revealer_set_transition_duration(@bell_border, 500)
      C.gtk_widget_set_can_target(@bell_border, 0)
      C.gtk_widget_set_can_focus(@bell_border, 0)
      C.gtk_overlay_add_overlay(overlay, @bell_border)
      C.gtk_widget_set_valign(@banner_bar, C::GtkAlign::End)
      Signals.connect(@banner_bar, "button-clicked", -> { @banner_action.try(&.call); nil })
      C.gtk_overlay_add_overlay(overlay, @banner_bar)
      layout_overlays(overlay)
      Widget.new(overlay).vexpand = true
      build_header
      box = C.gtk_box_new(C::GtkOrientation::Vertical, 0)
      C.gtk_box_append(box, @header)
      C.gtk_box_append(box, overlay)
      C.adw_bin_set_child(@host, box)
      C.gtk_widget_set_overflow(@host, C::GtkOverflow::Hidden)
    end

    private def build_header : Nil
      @header.add_css_class("surface-header")
      @header_icon.visible = false
      C.gtk_box_append(@header, @header_icon)
      C.gtk_label_set_xalign(@header_title, 0)
      C.gtk_label_set_ellipsize(@header_title, C::PANGO_ELLIPSIZE_END)
      @header_title.hexpand = true
      C.gtk_box_append(@header, @header_title)
      @stack_badge.add_css_class("surface-stack-badge")
      @stack_badge.add_css_class("dim-label")
      @stack_badge.visible = false
      C.gtk_box_append(@header, @stack_badge)
      {
        {"view-dual-symbolic", DesktopKit.tr("Split Right"), Action::NewSplit.new(:right)},
        {"view-paged-symbolic", DesktopKit.tr("Split Down"), Action::NewSplit.new(:down)},
        {"view-fullscreen-symbolic", DesktopKit.tr("Zoom Split"), Action::ToggleSplitZoom.new},
        {"window-close-symbolic", DesktopKit.tr("Close Split"), Action::CloseSurface.new},
      }.each do |icon, tooltip, action|
        button = Widget.new(C.gtk_button_new_from_icon_name(icon))
        C.gtk_button_set_has_frame(button, 0)
        button.focusable = false
        button.tooltip = tooltip
        Signals.connect(button, "clicked", -> { header_action(action) })
        C.gtk_box_append(@header, button)
      end
      click = C.gtk_gesture_click_new
      Signals.connect(click, "pressed", ->(_count : Int32, _x : Float64, _y : Float64) { grab_focus })
      @header.add_controller(click)
    end

    private def header_action(action : Action) : Nil
      Log.warn { "pane header: action #{action.detailed_name} not handled" } unless @app.dispatch(self, action)
    end

    private def sync_title : Nil
      C.gtk_label_set_label(@header_title, shown_title || Window.default_title)
      @tab.try(&.sync_title)
    end

    private def show_banner(message : String, button : String?, action : Proc(Nil)?) : Nil
      @banner = message
      @banner_action = action
      return if @closed
      C.adw_banner_set_title(@banner_bar, message)
      C.adw_banner_set_button_label(@banner_bar, button)
      C.adw_banner_set_revealed(@banner_bar, 1)
    end

    private def focus_changed(focused : Bool) : Nil
      @focused = focused
      return unless focused
      @notifications.clear
      if @bell_ringing
        @bell_ringing = false
        C.gtk_revealer_set_reveal_child(@bell_border, 0)
        @tab.try(&.sync_title)
      end
      @tab.try(&.focused(self))
    end

    private def sync_cursor : Nil
      @content.widget.cursor_name = @mouse_visible ? @cursor : "none" unless @closed
    end

    # Forgets the surface once its tab dropped it.
    protected def release : Nil
      return if @closed
      @closed = true
      @tab = nil
      @banner_action = nil
      @notifications.clear
      stop_pulse
      release_overlays
      @app.unregister(self)
      @app.sync_progress if @progress
      @app.sync_logout_inhibit if @confirm_close
      C.g_object_unref(@host)
      @content.close
    end

    # Updates the bar: a fraction, or a pulse every `PULSE` while the
    # value is unknown.
    private def sync_progress : Nil
      progress = @progress
      @progress_bar.visible = !progress.nil?
      {Progress::State::Error => "error", Progress::State::Paused => "paused"}.each do |state, name|
        progress.try(&.state) == state ? @progress_bar.add_css_class(name) : @progress_bar.remove_css_class(name)
      end
      if value = progress.try(&.value)
        stop_pulse
        C.gtk_progress_bar_set_fraction(@progress_bar, value)
      elsif progress && @pulse == 0
        pulse
      elsif progress.nil?
        stop_pulse
      end
    end

    private PULSE = 100.milliseconds

    private def pulse : Nil
      C.gtk_progress_bar_pulse(@progress_bar)
      @pulse = Idle.after(PULSE) do
        @pulse = 0_u32
        pulse if !@closed && @progress.try(&.indeterminate?)
      end
    end

    private def stop_pulse : Nil
      return if @pulse == 0
      Idle.cancel(@pulse)
      @pulse = 0_u32
    end
  end
end
