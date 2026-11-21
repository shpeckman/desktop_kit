# src/desktop_kit/window/tab_floats.cr
module DesktopKit
  class Tab
    # :nodoc:
    # A floating surface of a tab and its bounds in fractions of the tab
    # area.
    record Floating, surface : Surface, bounds : Bounds

    # A float without bounds takes this fraction of the tab area each way,
    # its corner this far from the top-left one, then cascades by
    # CASCADE_STEP per float over CASCADE_COUNT steps.
    private FLOAT_SIZE    =  0.6
    private FLOAT_ORIGIN  =  0.2
    private CASCADE_STEP  = 0.04
    private CASCADE_COUNT =    5

    # Returns the floating surfaces, from the bottom one to the top one.
    def floats : Array(Surface)
      @view.floats.map(&.surface)
    end

    protected def floating?(surface : Surface) : Bool
      @view.floats.any? { |float| float.surface == surface }
    end

    protected def floating(surface : Surface) : Floating?
      @view.floats.find { |float| float.surface == surface }
    end

    # Lifts the split *surface* out of the tree to float on top at *bounds*,
    # or cascaded near the middle, and focuses it; moves a floating
    # *surface* to *bounds*. False for the tab's only split.
    protected def float(surface : Surface, bounds : Bounds? = nil) : Bool
      return false if @destroyed
      return bounds ? place_float(surface, bounds) : false if floating?(surface)
      tree = @view.tree
      return false if tree.size == 1 || !tree.locate(surface)
      unless bounds
        offset = FLOAT_ORIGIN + CASCADE_STEP * (@view.floats.size % CASCADE_COUNT)
        bounds = Bounds.new(offset, offset, FLOAT_SIZE, FLOAT_SIZE)
      end
      # The host leaves its pane before it joins the overlay.
      @view.release_widgets
      @view.tree = tree.without(surface)
      @view.floats = @view.floats + [Floating.new(surface, bounds.clamped)]
      activate(surface)
      true
    end

    # Splits the floating *surface* back in beside the split under its
    # centre, or the zoomed one, and focuses it.
    protected def tile(surface : Surface) : Bool
      return false if @destroyed
      float = floating(surface) || return false
      tree = @view.tree
      handle = tree.zoomed || tile_at(tree, *float.bounds.center) || return false
      host = tree.view(handle).host
      direction = host.width >= host.height ? Direction::Right : Direction::Down
      @view.floats = without(surface)
      @view.tree = tree.split(handle, direction, surface)
      activate(surface)
      true
    end

    # Moves the floating *surface* to *bounds*, kept inside the tab area,
    # without rebuilding the splits.
    protected def place_float(surface : Surface, bounds : Bounds) : Bool
      floats = @view.floats
      index = floats.index { |float| float.surface == surface } || return false
      bounds = bounds.clamped
      return true if floats.unsafe_fetch(index).bounds == bounds
      floats = floats.dup
      floats[index] = Floating.new(surface, bounds)
      @view.floats = floats
      true
    end

    # Moves the floating *surface* by *amount* pixels in *direction*; false
    # when it cannot move further.
    protected def move_float(surface : Surface, direction : Direction, amount : UInt32) : Bool
      float = floating(surface) || return false
      width, height = root.width, root.height
      return false if width <= 0 || height <= 0
      step = amount.to_f
      moved =
        case direction
        in .left?  then float.bounds.moved(-step / width, 0.0)
        in .right? then float.bounds.moved(step / width, 0.0)
        in .up?    then float.bounds.moved(0.0, -step / height)
        in .down?  then float.bounds.moved(0.0, step / height)
        end
      return false if moved == float.bounds
      place_float(surface, moved)
    end

    # Grows the floating *surface* by *amount* pixels to the right or down,
    # or shrinks it to the left or up, down to its minimum size; its top-left
    # corner stays.
    protected def resize_float(surface : Surface, direction : Direction, amount : UInt32) : Bool
      float = floating(surface) || return false
      width, height = root.width, root.height
      return false if width <= 0 || height <= 0
      min_width, min_height = float_minimum(surface)
      step = amount.to_f
      resized =
        case direction
        in .left?  then float.bounds.resized(-step / width, 0.0, min_width, min_height)
        in .right? then float.bounds.resized(step / width, 0.0, min_width, min_height)
        in .up?    then float.bounds.resized(0.0, -step / height, min_width, min_height)
        in .down?  then float.bounds.resized(0.0, step / height, min_width, min_height)
        end
      return false if resized == float.bounds
      place_float(surface, resized)
    end

    # The smallest width and height of *surface* in fractions of the tab
    # area, which has a size.
    protected def float_minimum(surface : Surface) : {Float64, Float64}
      width, height = @view.minimum(surface.host)
      {width.to_f / root.width, height.to_f / root.height}
    end

    # Puts the floating *surface* on top of the other floats.
    protected def raise_float(surface : Surface) : Nil
      floats = @view.floats
      index = floats.index { |float| float.surface == surface } || return
      return if index == floats.size - 1
      floats = floats.dup
      floats << floats.delete_at(index)
      @view.floats = floats
    end

    private def without(surface : Surface) : Array(Floating)
      @view.floats.reject { |float| float.surface == surface }
    end

    # The split focused last while it is still in the tree, else the first.
    private def last_tile : Surface?
      tree = @view.tree
      @last_tile.try { |tile| return tile if tree.locate(tile) }
      tree.first?.try(&.[1])
    end

    # The handle of the split whose rectangle holds the point *x*, *y* in
    # fractions of the tab area, else of the first split.
    private def tile_at(tree : SplitTree(Surface), x : Float64, y : Float64) : Int32?
      slots = tree.spatial
      fallback = nil
      tree.each do |handle, _|
        fallback ||= handle
        slot = slots.unsafe_fetch(handle)
        return handle if slot.x <= x && x <= slot.max_x && slot.y <= y && y <= slot.max_y
      end
      fallback
    end
  end
end
