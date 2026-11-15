# src/apprt/window/surface_overlays.cr
module Apprt
  class Surface
    # How long `#show_size` shows its text.
    private SIZE_SHOWN = 750.milliseconds

    # How long after creation `#show_size` stays quiet, so the first
    # layout shows no size, as in Ghostty's resize overlay.
    private SIZE_GRACE = 250.milliseconds

    @created = Time.instant
    @size_label = Widget.new(C.gtk_label_new(""))
    @size_timer = 0_u32
    @hover_left = Widget.new(C.gtk_label_new(""))
    @hover_right = Widget.new(C.gtk_label_new(""))
    @hover_motion = {C.gtk_event_controller_motion_new, C.gtk_event_controller_motion_new}
    @search : SearchOverlay?

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

    # Adds the size, hover and search overlays to *overlay*.
    private def layout_overlays(overlay : Void*) : Nil
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
    end
  end
end
