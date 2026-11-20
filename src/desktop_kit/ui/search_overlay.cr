# src/desktop_kit/ui/search_overlay.cr
module DesktopKit
  # :nodoc:
  # A surface's search bar: a search entry, the match count, previous and next buttons and a close
  # button. Return goes to the next match, Shift+Return to the previous
  # one, Escape ends the search. Dragging the bar moves it to the corner
  # nearest the drop point; it starts top right.
  class SearchOverlay
    private KEY_RETURN    = 0xff0d_u32
    private KEY_KP_ENTER  = 0xff8d_u32
    private SHIFT_MASK    =      1_u32
    private MARGIN        =          8
    private ENTRY_CHARS   =         20
    private MATCHES_CHARS =          6

    getter widget : Widget
    getter? active = false
    @total : Int32?
    @selected : Int32?

    # Where the current drag started, in the bar's coordinates. GTK no
    # longer reports it once the drag ended.
    @drag_start = {0.0, 0.0}

    def initialize(@surface : Surface)
      @widget = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 6))
      @entry = Widget.new(C.gtk_search_entry_new)
      @matches = Widget.new(C.gtk_label_new(""))
      @drag = C.gtk_gesture_drag_new
      @keys = C.gtk_event_controller_key_new
      layout
      connect_signals
    end

    # Shows the bar and focuses its entry; a non-empty *needle* replaces
    # the text.
    def open(needle : String) : Nil
      @active = true
      @widget.visible = true
      C.gtk_editable_set_text(@entry, needle) unless needle.empty?
      @entry.grab_focus
    end

    # Hides the bar and forgets the match count.
    def close : Nil
      @active = false
      @widget.visible = false
      @total = nil
      @selected = nil
      sync_matches
    end

    def total=(total : Int32?) : Int32?
      @total = total
      sync_matches
      total
    end

    def selected=(selected : Int32?) : Int32?
      @selected = selected
      sync_matches
      selected
    end

    private def layout : Nil
      @widget.add_css_class("osd")
      @widget.add_css_class("surface-search")
      @widget.visible = false
      C.gtk_widget_set_halign(@widget, C::GtkAlign::End)
      C.gtk_widget_set_valign(@widget, C::GtkAlign::Start)
      {% for side in %w(start end top bottom) %}
        C.gtk_widget_set_margin_{{side.id}}(@widget, MARGIN)
      {% end %}
      C.gtk_search_entry_set_placeholder_text(@entry, DesktopKit.tr("Find…"))
      C.gtk_editable_set_width_chars(@entry, ENTRY_CHARS)
      C.gtk_box_append(@widget, @entry)
      @matches.add_css_class("dim-label")
      C.gtk_label_set_width_chars(@matches, MATCHES_CHARS)
      C.gtk_label_set_xalign(@matches, 1.0_f32)
      C.gtk_box_append(@widget, @matches)
      buttons = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 0))
      buttons.add_css_class("linked")
      C.gtk_box_append(buttons, button("go-up-symbolic", DesktopKit.tr("Previous Match")) { @surface.navigate_search(false) })
      C.gtk_box_append(buttons, button("go-down-symbolic", DesktopKit.tr("Next Match")) { @surface.navigate_search(true) })
      C.gtk_box_append(@widget, buttons)
      close = button("window-close-symbolic", DesktopKit.tr("End Search")) { @surface.end_search }
      C.gtk_button_set_has_frame(close, 0)
      C.gtk_box_append(@widget, close)
      sync_matches
    end

    private def button(icon : String, tooltip : String, &action : ->) : Widget
      button = Widget.new(C.gtk_button_new_from_icon_name(icon))
      button.focusable = false
      button.tooltip = tooltip
      Signals.connect(button, "clicked", -> { action.call })
      button
    end

    private def connect_signals : Nil
      # `search-changed` is GTK's debounced signal: no own debounce.
      Signals.connect(@entry, "search-changed", -> { @surface.search_changed(String.new(C.gtk_editable_get_text(@entry))) })
      Signals.connect(@entry, "stop-search", -> { @surface.end_search })
      C.gtk_event_controller_set_propagation_phase(@keys, C::GtkPropagationPhase::Capture)
      Signals.connect(@keys, "key-pressed", ->(keyval : UInt32, _keycode : UInt32, state : UInt32) : Bool {
        return false unless keyval.in?(KEY_RETURN, KEY_KP_ENTER)
        @surface.navigate_search(state & SHIFT_MASK == 0)
        true
      })
      @entry.add_controller(@keys)
      C.gtk_gesture_single_set_button(@drag, 1)
      # Start recorded at `drag-begin`: GTK no longer reports it at `drag-end`.
      Signals.connect(@drag, "drag-begin", ->(x : Float64, y : Float64) { @drag_start = {x, y} })
      Signals.connect(@drag, "drag-end", ->(dx : Float64, dy : Float64) { snap(dx, dy) })
      @widget.add_controller(@drag)
    end

    # Moves the bar to the corner of its parent nearest to where the drag
    # ended.
    private def snap(dx : Float64, dy : Float64) : Nil
      parent = @widget.parent || return
      return if dx.abs < 1 && dy.abs < 1
      x, y = @drag_start
      return if C.gtk_widget_translate_coordinates(@widget, parent, x + dx, y + dy, out px, out py) == 0
      C.gtk_widget_set_halign(@widget, px * 2 < parent.width ? C::GtkAlign::Start : C::GtkAlign::End)
      C.gtk_widget_set_valign(@widget, py * 2 < parent.height ? C::GtkAlign::Start : C::GtkAlign::End)
      # The overlay keeps a child's position until it lays itself out.
      C.gtk_widget_queue_resize(parent)
    end

    # Shows "selected/total", "-/total" without a selection, or nothing
    # while the content reported no count.
    private def sync_matches : Nil
      text = @total.try { |total| "#{@selected.try(&.+(1)) || "-"}/#{total}" } || ""
      C.gtk_label_set_label(@matches, text)
    end
  end
end
