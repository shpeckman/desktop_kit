# src/desktop_kit/window/window_overlay.cr
module DesktopKit
  class Window
    # Content shown over a window's tabs, splits and pane headers, below
    # its header bar, at a rectangle the application places.
    #
    # Input inside the rectangle goes to the content; elsewhere it reaches
    # the splits underneath, unless the overlay is `#modal?`. Overlays
    # added later lie above earlier ones. `Window#add_overlay` makes one.
    #
    # The content's `Content#on_close` runs once the overlay closed, by
    # `#close` or with its window.
    class Overlay
      # Returns the content the overlay shows.
      getter content : Content
      getter? modal : Bool
      getter? closed = false
      @catcher : Widget? = nil
      @catcher_gesture = Pointer(Void).null
      @outside_press : (MouseButton, Float64, Float64 ->)? = nil
      @x = 0
      @y = 0

      protected def initialize(@window : Window, @content : Content, @modal : Bool)
      end

      # Moves the overlay to *x*, *y* (logical pixels from the top left of
      # the tab area) and sizes it to *width* × *height*.
      def place(x : Int32, y : Int32, width : Int32, height : Int32) : Nil
        return if @closed
        @x, @y = x, y
        widget = @content.widget
        C.gtk_widget_set_margin_start(widget, x)
        C.gtk_widget_set_margin_top(widget, y)
        widget.size_request(width, height)
      end

      # Sets whether the overlay holds the input: while modal, the pointer
      # does not reach the splits and the content keeps the keyboard focus.
      def modal=(modal : Bool) : Bool
        return modal if @closed || modal == @modal
        @modal = modal
        if modal
          attach_catcher
          @content.widget.grab_focus
        else
          detach_catcher
        end
        modal
      end

      # Calls *block* with the button and the pointer position, in logical
      # pixels from the overlay's top left corner, at each press outside
      # the overlay while it is `#modal?`.
      def on_outside_press(&block : MouseButton, Float64, Float64 ->) : Nil
        @outside_press = block
      end

      # Lifts the overlay above the window's other overlays.
      def raise : Nil
        return if @closed
        @window.raise_overlay(self)
      end

      # Removes the overlay and gives the keyboard focus back to the active
      # surface.
      def close : Nil
        return if @closed
        @window.remove_overlay(self)
      end

      protected def attach(parent : Void*, before : Void*) : Nil
        attach_catcher(parent, before) if @modal
        widget = @content.widget
        C.gtk_widget_set_halign(widget, C::GtkAlign::Start)
        C.gtk_widget_set_valign(widget, C::GtkAlign::Start)
        C.gtk_widget_insert_before(widget, parent, before)
        @content.widget.grab_focus if @modal
      end

      # Moves the overlay's widgets, which *parent* holds, before *before*.
      protected def restack(parent : Void*, before : Void*) : Nil
        @catcher.try { |catcher| C.gtk_widget_insert_before(catcher, parent, before) }
        C.gtk_widget_insert_before(@content.widget, parent, before)
      end

      protected def detach : Nil
        detach_catcher
        @content.widget.unparent
        @closed = true
        @content.close
      end

      # Marks the overlay closed once its window's widgets are gone.
      protected def forget : Nil
        return if @closed
        @closed = true
        @catcher = nil
        @content.close
      end

      private def attach_catcher(parent : Void* = @window.overlay_parent,
                                 before : Void* = @content.widget.to_unsafe) : Nil
        catcher = @catcher = Widget.new(C.gtk_box_new(C::GtkOrientation::Horizontal, 0))
        catcher.hexpand = true
        catcher.vexpand = true
        gesture = @catcher_gesture = C.gtk_gesture_click_new
        C.gtk_gesture_single_set_button(gesture, 0)
        Signals.connect(gesture, "pressed", ->(_count : Int32, x : Float64, y : Float64) {
          button = MouseButton.new(C.gtk_gesture_single_get_current_button(gesture).to_i32)
          @outside_press.try(&.call(button, x - @x, y - @y))
        })
        catcher.add_controller(gesture)
        C.gtk_widget_insert_before(catcher, parent, before)
      end

      private def detach_catcher : Nil
        @catcher.try(&.unparent)
        @catcher = nil
      end
    end

    @overlays = [] of Overlay

    # Returns the open overlays, the topmost last.
    def overlays : Array(Overlay)
      @overlays.dup
    end

    # Returns the size of the tab area overlays lie over, in logical
    # pixels; `{0, 0}` while the window is not shown.
    def overlay_area : {Int32, Int32}
      {@overlay_parent.width, @overlay_parent.height}
    end

    # Shows *content* over the window's tabs at *x*, *y* (logical pixels
    # from the top left of the tab area), *width* × *height*, above the
    # other overlays, and returns the overlay. A *modal* overlay takes the
    # keyboard focus and keeps the pointer from the splits.
    #
    # The content belongs to the overlay: it is not a surface's, and
    # `Content#surface` raises for it.
    def add_overlay(content : Content, x : Int32, y : Int32, width : Int32, height : Int32,
                    *, modal : Bool = false) : Overlay
      raise ArgumentError.new("window is closed") if @closed
      overlay = Overlay.new(self, content, modal)
      overlay.attach(overlay_parent, @key_state.to_unsafe)
      overlay.place(x, y, width, height)
      @overlays << overlay
      overlay
    end

    protected def overlay_parent : Void*
      @overlay_parent.to_unsafe
    end

    protected def raise_overlay(overlay : Overlay) : Nil
      return if @overlays.last?.same?(overlay)
      @overlays.delete(overlay)
      @overlays << overlay
      overlay.restack(overlay_parent, @key_state.to_unsafe)
    end

    protected def remove_overlay(overlay : Overlay) : Nil
      @overlays.delete(overlay)
      overlay.detach
      active_surface.try(&.focus)
    end

    private def forget_overlays : Nil
      @overlays.each(&.forget)
      @overlays.clear
    end
  end
end
