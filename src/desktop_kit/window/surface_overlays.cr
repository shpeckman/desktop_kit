# src/desktop_kit/window/surface_overlays.cr
module DesktopKit
  class Surface
    # How long `#show_size` shows its text.
    private SIZE_SHOWN = 750.milliseconds

    # How long after creation `#show_size` stays quiet, so the first
    # layout shows no size.
    private SIZE_GRACE = 250.milliseconds

    @created = Time.instant
    @size_label = Widget.new(C.gtk_label_new(""))
    @size_timer = 0_u32
    @pick_label = Widget.new(C.gtk_label_new(""))
    @hover_left = Widget.new(C.gtk_label_new(""))
    @hover_right = Widget.new(C.gtk_label_new(""))
    @hover_motion = {C.gtk_event_controller_motion_new, C.gtk_event_controller_motion_new}
    @search : SearchOverlay?
    @context_click = C.gtk_gesture_click_new
    # The open context menu's popover, parented to the overlay; null when
    # closed.
    @context_popover = Pointer(Void).null

    # Returns the text shown at the bottom of the surface, such as the
    # target of a hovered link.
    getter hover_text : String?

    # Shows *text* at the bottom left of the surface, or hides it when
    # `nil`. The text moves to the right while the pointer is over it.
    def hover_text=(text : String?) : String?
      @hover_text = text
      C.gtk_label_set_label(@hover_left, text || "")
      C.gtk_label_set_label(@hover_right, text || "")
      @hover_left.visible = !text.nil?
      @hover_right.visible = false
      text
    end

    # Shows *text*, such as the new size after a resize, centered over the
    # surface for a moment.
    #
    # Does nothing for a short while after the surface was created, so the
    # first layout shows no size.
    def show_size(text : String) : Nil
      return if @closed || Time.instant - @created < SIZE_GRACE
      C.gtk_label_set_label(@size_label, text)
      @size_label.visible = true
      Idle.cancel(@size_timer) unless @size_timer == 0
      @size_timer = Idle.after(SIZE_SHOWN) do
        @size_timer = 0_u32
        @size_label.visible = false
      end
    end

    # Returns whether the search bar is open.
    def search_active? : Bool
      @search.try(&.active?) || false
    end

    # Opens the search bar and focuses it; a non-empty *needle* replaces
    # its text.
    #
    # The content hears of the search through its `Content#on_search`,
    # `Content#on_search_navigate` and `Content#on_search_end` hooks.
    def start_search(needle : String = "") : Nil
      return if @closed
      search = @search ||= SearchOverlay.new(self).tap do |overlay|
        C.gtk_overlay_add_overlay(@overlay, overlay.widget)
      end
      search.open(needle)
    end

    # Closes the search bar and returns the focus to the content.
    def end_search : Nil
      search = @search || return
      return unless search.active?
      search.close
      @content.search_end
      grab_focus
    end

    # Shows *total* matches in the search bar; `nil` shows no count.
    def search_total=(total : Int32?) : Int32?
      @search.try(&.total = total)
      total
    end

    # Marks the match at index *selected* (from 0) as the current one in the
    # search bar; `nil` marks none.
    def search_selected=(selected : Int32?) : Int32?
      @search.try(&.selected = selected)
      selected
    end

    protected def search_changed(needle : String) : Nil
      @content.search(needle)
    end

    protected def navigate_search(forward : Bool) : Nil
      @content.search_navigate(forward) if search_active?
    end

    # Shows *label* large in the middle of the surface while
    # `Window#pick_surface` waits for a key; `nil` hides it.
    protected def pick_label=(label : String?) : String?
      C.gtk_label_set_label(@pick_label, label || "")
      @pick_label.visible = !label.nil?
      label
    end

    # Adds the size, hover, pick and search overlays to *overlay*.
    private def layout_overlays(overlay : Void*) : Nil
      @pick_label.add_css_class("osd")
      @pick_label.add_css_class("surface-pick")
      @pick_label.visible = false
      C.gtk_widget_set_can_target(@pick_label, 0)
      C.gtk_widget_set_halign(@pick_label, C::GtkAlign::Center)
      C.gtk_widget_set_valign(@pick_label, C::GtkAlign::Center)
      C.gtk_overlay_add_overlay(overlay, @pick_label)
      @size_label.add_css_class("osd")
      @size_label.add_css_class("surface-size")
      @size_label.visible = false
      C.gtk_widget_set_can_target(@size_label, 0)
      C.gtk_widget_set_halign(@size_label, C::GtkAlign::Center)
      C.gtk_widget_set_valign(@size_label, C::GtkAlign::Center)
      C.gtk_overlay_add_overlay(overlay, @size_label)
      {@hover_left, @hover_right}.each_with_index do |label, index|
        label.add_css_class("osd")
        label.add_css_class("surface-hover")
        label.visible = false
        C.gtk_widget_set_halign(label, index == 0 ? C::GtkAlign::Start : C::GtkAlign::End)
        C.gtk_widget_set_valign(label, C::GtkAlign::End)
        motion = @hover_motion[index]
        Signals.connect(motion, "enter", ->(_x : Float64, _y : Float64) { swap_hover(index == 0) })
        label.add_controller(motion)
        C.gtk_overlay_add_overlay(overlay, label)
      end
      C.gtk_gesture_single_set_button(@context_click, 3)
      C.gtk_event_controller_set_propagation_phase(@context_click, C::GtkPropagationPhase::Capture)
      Signals.connect(@context_click, "pressed", ->(_count : Int32, x : Float64, y : Float64) { show_context_menu(x, y) })
      Widget.new(overlay).add_controller(@context_click)
    end

    # Pops up the content's context menu at *x*, *y*, claiming the click,
    # after focusing the surface so split actions act on it.
    private def show_context_menu(x : Float64, y : Float64) : Nil
      return if @closed
      menu = @content.context_menu_at(x, y) || return
      C.gtk_gesture_set_state(@context_click, C::GtkEventSequenceState::Claimed)
      focus
      close_context_menu
      model = menu.to_model
      popover = C.gtk_popover_menu_new_from_model(model)
      C.g_object_unref(model)
      @context_popover = popover
      C.gtk_popover_set_has_arrow(popover, 0)
      C.gtk_widget_set_halign(popover, C::GtkAlign::Start)
      C.gtk_widget_set_parent(popover, @overlay)
      rect = C::GdkRectangle.new(x: x.to_i32, y: y.to_i32, width: 1, height: 1)
      C.gtk_popover_set_pointing_to(popover, pointerof(rect))
      # Unparenting waits for an idle: GTK may close the menu while it
      # activates the chosen item.
      Signals.connect(popover, "closed", -> { UIThread.post { close_context_menu(popover) } })
      C.gtk_popover_popup(popover)
    end

    # Unparents the context menu *popover*, the open one by default.
    private def close_context_menu(popover : Void* = @context_popover) : Nil
      return if popover.null? || popover != @context_popover
      @context_popover = Pointer(Void).null
      C.gtk_widget_unparent(popover)
    end

    # Moves the hover text away from the pointer: to the right when it
    # entered the left label.
    private def swap_hover(to_right : Bool) : Nil
      return if @hover_text.nil?
      @hover_left.visible = !to_right
      @hover_right.visible = to_right
    end

    private def release_overlays : Nil
      Idle.cancel(@size_timer) unless @size_timer == 0
      @size_timer = 0_u32
      close_context_menu
    end
  end
end
