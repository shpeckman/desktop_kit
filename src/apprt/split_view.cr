# src/apprt/split_view.cr
module Apprt
  # :nodoc:
  # Shows a tab's `SplitTree` of surfaces as nested `GtkPaned`s inside one
  # `AdwBin`, after the widget of Ghostty's gtk/class/split_tree.zig.
  #
  # Every tree change schedules one idle rebuild. The rebuild takes the
  # surface hosts out of the old panes, which can outlive it, and drops them;
  # each host holds a reference of its own. It then builds panes for the
  # zoomed node or the root and focuses `#focus` when it is on screen.
  #
  # A `Divider` per pane keeps the pane position and the split ratio in step:
  # when the pane's size limits change it applies the ratio, and when only the
  # position changed (a drag) it stores the new ratio with `#store_ratio`,
  # which does not rebuild. Dividers touch GTK only from idle callbacks, which
  # are cancelled before their pane goes away.
  class SplitView
    getter root : Widget

    getter tree : SplitTree(Surface) = SplitTree(Surface).new

    # The surface to focus after the next rebuild.
    property focus : Surface?

    @rebuild = 0_u32
    @dividers = [] of Divider
    @destroyed = false

    def initialize
      @root = Widget.new(C.adw_bin_new)
      @root.hexpand = true
      @root.vexpand = true
    end

    def tree=(tree : SplitTree(Surface)) : SplitTree(Surface)
      @tree = tree
      if !@destroyed && @rebuild == 0
        @rebuild = Idle.add { rebuild }
      end
      tree
    end

    def pending? : Bool
      @rebuild != 0
    end

    # Returns the ratio of the split at *handle*, or `nil` while a rebuild is
    # pending.
    def ratio(handle : Int32) : Float64?
      return if @destroyed || pending?
      @tree[handle].as?(SplitTree::Split).try(&.ratio)
    end

    def store_ratio(handle : Int32, ratio : Float64) : Nil
      return if @destroyed || pending?
      @tree = @tree.with_ratio(handle, ratio.clamp(0.0, 1.0))
    end

    # Stops all callbacks; the widgets stay as GTK disposes them.
    def destroy : Nil
      return if @destroyed
      @destroyed = true
      Idle.cancel(@rebuild) if pending?
      @rebuild = 0_u32
      @dividers.each(&.cancel)
      @dividers.clear
    end

    private def rebuild : Nil
      @rebuild = 0_u32
      return if @destroyed
      release_focus
      @dividers.each(&.detach)
      @dividers.clear
      C.adw_bin_set_child(@root, nil)
      C.adw_bin_set_child(@root, build(@tree.zoomed || SplitTree::ROOT)) unless @tree.empty?
      @focus.try(&.grab_focus)
    end

    # Takes the keyboard focus out of the panes before they lose their
    # children; a `GtkPaned` warns when its focused child goes first.
    private def release_focus : Nil
      window = @root.root || return
      focus = C.gtk_root_get_focus(window)
      C.gtk_root_set_focus(window, nil) if !focus.null? && C.gtk_widget_is_ancestor(focus, @root) != 0
    end

    private def build(handle : Int32) : Void*
      node = @tree[handle]
      return node.host.to_unsafe if node.is_a?(Surface)
      orientation = node.layout.horizontal? ? C::GtkOrientation::Horizontal : C::GtkOrientation::Vertical
      paned = C.gtk_paned_new(orientation)
      C.gtk_paned_set_start_child(paned, build(node.left))
      C.gtk_paned_set_end_child(paned, build(node.right))
      C.gtk_paned_set_resize_start_child(paned, 1)
      C.gtk_paned_set_resize_end_child(paned, 1)
      C.gtk_paned_set_shrink_start_child(paned, 0)
      C.gtk_paned_set_shrink_end_child(paned, 0)
      @dividers << Divider.new(self, paned, handle, orientation)
      paned
    end

    private class Divider
      # Smallest ratio change worth storing.
      EPSILON = 0.001

      @settle = 0_u32
      @alive = true
      @min = -1
      @max = -1
      @position = -1

      def initialize(@view : SplitView, @paned : Void*, @handle : Int32, @orientation : C::GtkOrientation)
        Signals.notify(@paned, "min-position", -> { schedule })
        Signals.notify(@paned, "max-position", -> { schedule })
        Signals.notify(@paned, "position", -> { schedule })
      end

      def cancel : Nil
        @alive = false
        Idle.cancel(@settle) unless @settle == 0
        @settle = 0_u32
      end

      # Cancels the divider and unparents the pane's children.
      def detach : Nil
        cancel
        C.gtk_paned_set_start_child(@paned, nil)
        C.gtk_paned_set_end_child(@paned, nil)
      end

      private def schedule : Nil
        return if !@alive || @settle != 0
        @settle = Idle.add { settle }
      end

      private def settle : Nil
        @settle = 0_u32
        return unless @alive
        ratio = @view.ratio(@handle) || return
        min = int_property("min-position")
        max = int_property("max-position")
        position = C.gtk_paned_get_position(@paned)
        return if max == Int32::MAX
        size = max + end_minimum
        return if size <= 0
        if min != @min || max != @max
          @min, @max = min, max
          @position = (size * ratio).round.to_i.clamp(min, Math.max(min, max))
          C.gtk_paned_set_position(@paned, @position)
        elsif position != @position
          @position = position
          stored = position / size
          @view.store_ratio(@handle, stored) if (stored - ratio).abs >= EPSILON
        end
      end

      private def end_minimum : Int32
        child = C.gtk_paned_get_end_child(@paned)
        return 0 if child.null?
        minimum = 0
        natural = 0
        C.gtk_widget_measure(child, @orientation, -1, pointerof(minimum), pointerof(natural), nil, nil)
        minimum
      end

      private def int_property(name : String) : Int32
        value = C::GValue.new
        C.g_value_init(pointerof(value), C::TYPE_INT)
        C.g_object_get_property(@paned, name, pointerof(value))
        C.g_value_get_int(pointerof(value))
      end
    end
  end
end
