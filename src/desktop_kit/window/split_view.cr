# src/desktop_kit/window/split_view.cr
module DesktopKit
  # :nodoc:
  # Shows a tab's `SplitTree` of surfaces as nested `GtkPaned`s inside one
  # `AdwBin`, the tiles, and its floats over them, in a `GtkOverlay`.
  #
  # Every tree change schedules one idle rebuild. The rebuild takes the
  # surface hosts out of the old panes, which can outlive it, and drops them;
  # each host holds a reference of its own. It then builds panes for the
  # zoomed node or the root and focuses `#focus` when it is on screen.
  #
  # A stack is a vertical `GtkBox` of its surfaces' hosts with only the
  # shown one visible. Showing another one with `#show` swaps the
  # visibility at once, without a rebuild: the hosts keep their parent, so
  # their content stays realized.
  #
  # Floats are overlay children in z order, the top one last, placed by
  # `get-child-position` from their bounds on every allocation. A float
  # change applies at once and never rebuilds the tiles: moving, resizing
  # and raising neither unparent nor reparent a host. Floats hide while the
  # tiles show a zoom.
  #
  # A `Divider` per pane keeps the pane position and the split ratio in step:
  # when the pane's size limits change it applies the ratio, and when only the
  # position changed (a drag) it stores the new ratio with `#store_ratio`,
  # which does not rebuild. Dividers touch GTK only from idle callbacks, which
  # are cancelled before their pane goes away.
  class SplitView
    getter root : Widget

    getter tree : SplitTree(Surface) = SplitTree(Surface).new

    # The floating surfaces, the top one last.
    getter floats = [] of Tab::Floating

    # The surface to focus after the next rebuild.
    property focus : Surface?

    @rebuild = 0_u32
    @dividers = [] of Divider
    @stacks = [] of StackBox
    @destroyed = false
    # Whether the tiles show a zoom, as of the last rebuild.
    @zoomed = false

    def initialize
      @tiles = Widget.new(C.adw_bin_new)
      @root = Widget.new(C.gtk_overlay_new)
      @root.add_css_class("split-view")
      @root.hexpand = true
      @root.vexpand = true
      C.gtk_overlay_set_child(@root, @tiles)
      Signals.connect(@root, "get-child-position", ->(child : Widget, allocation : Void*) : Bool { place(child, allocation) })
    end

    # Shows *floats* over the tiles at once, without a rebuild.
    def floats=(floats : Array(Tab::Floating)) : Array(Tab::Floating)
      old = @floats
      @floats = floats
      sync_floats(old) unless @destroyed
      floats
    end

    # Returns the smallest width and height *widget* takes.
    def minimum(widget : Widget) : {Int32, Int32}
      width = height = natural = 0
      C.gtk_widget_measure(widget, C::GtkOrientation::Horizontal, -1, pointerof(width), pointerof(natural), nil, nil)
      C.gtk_widget_measure(widget, C::GtkOrientation::Vertical, -1, pointerof(height), pointerof(natural), nil, nil)
      {width, height}
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

    # Takes *tree*, which differs from `#tree` at most in the shown
    # surface of its stacks, and shows it without a rebuild.
    def show(tree : SplitTree(Surface)) : SplitTree(Surface)
      @tree = tree
      sync_stacks unless @destroyed || pending?
      tree
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
      @stacks.clear
    end

    # Takes every widget out of the view now and rebuilds it on an idle, so
    # a surface can move to another view first.
    def release_widgets : Nil
      return if @destroyed
      release_focus
      detach_tiles
      @rebuild = Idle.add { rebuild } if @rebuild == 0
    end

    private def rebuild : Nil
      @rebuild = 0_u32
      return if @destroyed
      release_focus
      detach_tiles
      C.adw_bin_set_child(@tiles, build(@tree.zoomed || SplitTree::ROOT)) unless @tree.empty?
      @zoomed = !@tree.zoomed.nil?
      # Shown before the focus moves, so a float can take it.
      @floats.each { |float| float.surface.host.visible = !@zoomed }
      sync_draggable
      @focus.try(&.grab_focus)
    end

    # Takes every host out of its pane or stack, then the panes out of the
    # tiles: old panes and stacks outlive `adw_bin_set_child(nil)` and GTK
    # rejects parented children.
    private def detach_tiles : Nil
      # Stacks first: a pane that lets go of a stack box frees it, and with
      # it the host of a closed surface the box alone still holds.
      @stacks.each(&.detach)
      @stacks.clear
      @dividers.each(&.detach)
      @dividers.clear
      C.adw_bin_set_child(@tiles, nil)
    end

    # Shows the shown surface of every stack and hides the others, taking
    # the keyboard focus out of the hosts it hides.
    private def sync_stacks : Nil
      @stacks.each do |stack|
        node = @tree[stack.handle]
        next unless node.is_a?(SplitTree::Stack(Surface))
        shown = node.view
        shown.host.visible = true
        node.views.each do |surface|
          next if surface == shown
          release_focus(surface.host)
          surface.host.visible = false
        end
      end
    end

    # Unparents the hosts that stopped floating, stacks the floats in their
    # order and lays them out again.
    private def sync_floats(old : Array(Tab::Floating)) : Nil
      old.each do |float|
        surface = float.surface
        next if @floats.any? { |kept| kept.surface == surface }
        host = surface.host
        if host.parent == @root
          release_focus(host)
          host.unparent
        end
        host.visible = true
        surface.floating = false
      end
      @floats.each(&.surface.stack_position = nil)
      unless same_order?(old)
        # Reordering within the overlay neither unrealizes nor unmaps.
        @floats.each { |float| C.gtk_widget_insert_before(float.surface.host, @root, nil) }
      end
      @floats.each do |float|
        float.surface.floating = true
        float.surface.host.visible = !@zoomed
      end
      C.gtk_widget_queue_resize(@root)
      sync_draggable unless @floats.size == old.size
    end

    private def same_order?(old : Array(Tab::Floating)) : Bool
      @floats.size == old.size && @floats.each_index.all? { |index| @floats.unsafe_fetch(index).surface == old.unsafe_fetch(index).surface }
    end

    # Allocates the float host *child* its bounds in pixels of the overlay,
    # no smaller than its minimum and inside the overlay where it fits.
    private def place(child : Widget, allocation : Void*) : Bool
      float = @floats.find { |float| float.surface.host == child } || return false
      bounds = float.bounds
      min_width, min_height = minimum(child)
      area_width, area_height = @root.width, @root.height
      width = Math.max(min_width, Math.min((bounds.width * area_width).round.to_i, area_width))
      height = Math.max(min_height, Math.min((bounds.height * area_height).round.to_i, area_height))
      x = (bounds.x * area_width).round.to_i.clamp(0, Math.max(0, area_width - width))
      y = (bounds.y * area_height).round.to_i.clamp(0, Math.max(0, area_height - height))
      allocation.as(C::GdkRectangle*).value = C::GdkRectangle.new(x: x, y: y, width: width, height: height)
      true
    end

    # Shows the drag handles while the tab holds more than one surface.
    private def sync_draggable : Nil
      many = @tree.size + @floats.size > 1
      @tree.each { |_, surface| surface.draggable = many }
      @floats.each { |float| float.surface.draggable = many }
    end

    # Takes the keyboard focus out of *widget* before it loses its children
    # or its parent; a `GtkPaned` warns when its focused child goes first.
    # Floats keep the focus while the tiles rebuild.
    private def release_focus(widget : Widget = @tiles) : Nil
      # Else GTK warns "Error finding last focus widget".
      window = @root.root || return
      focus = C.gtk_root_get_focus(window)
      C.gtk_root_set_focus(window, nil) if !focus.null? && C.gtk_widget_is_ancestor(focus, widget) != 0
    end

    private def build(handle : Int32) : Void*
      case node = @tree[handle]
      in Surface
        node.host.visible = true
        node.stack_position = nil
        node.host.to_unsafe
      in SplitTree::Stack(Surface)
        build_stack(handle, node)
      in SplitTree::Split
        build_split(handle, node)
      end
    end

    private def build_stack(handle : Int32, stack : SplitTree::Stack(Surface)) : Void*
      box = Widget.new(C.gtk_box_new(C::GtkOrientation::Vertical, 0))
      box.add_css_class("surface-stack")
      box.hexpand = true
      box.vexpand = true
      shown = stack.view
      size = stack.views.size
      stack.views.each_with_index do |surface, index|
        surface.stack_position = {index + 1, size}
        surface.host.visible = surface == shown
        C.gtk_box_append(box, surface.host)
      end
      @stacks << StackBox.new(handle, box, stack.views)
      box.to_unsafe
    end

    private def build_split(handle : Int32, node : SplitTree::Split) : Void*
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

    # The box built for the stack at *handle* and the surfaces in it.
    private record StackBox, handle : Int32, box : Widget, surfaces : Array(Surface) do
      # Takes the hosts out of the box.
      def detach : Nil
        @surfaces.each do |surface|
          host = surface.host
          C.gtk_box_remove(@box, host) if host.parent == @box
        end
      end
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
        # `max-position` Int32::MAX = pane not allocated yet.
        return if max == Int32::MAX
        # Full size = `max-position` + end child's minimum.
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
