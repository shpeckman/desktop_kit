# src/apprt/window/split_tree.cr
module Apprt
  # :nodoc:
  # Immutable binary tree of views, ported from Ghostty's
  # `src/datastruct/split_tree.zig`. Nodes live in one array with the root at
  # `ROOT`; a node is a view (a leaf) or a `Split` holding the handles of its
  # two children. Every operation returns a new tree, and trees share node
  # arrays, which are never mutated after construction. A handle is an index
  # into one tree's array and is only valid for that tree.
  struct SplitTree(V)
    include Enumerable({Int32, V})

    ROOT = 0

    # Orientation of a split: `Horizontal` places its children side by side,
    # `Vertical` stacks them.
    enum Layout
      Horizontal
      Vertical

      # Returns the layout that places a new view in *direction*.
      def self.of(direction : Direction) : Layout
        direction.left? || direction.right? ? Horizontal : Vertical
      end
    end

    enum Side
      Left
      Right

      def opposite : Side
        left? ? Right : Left
      end
    end

    # Moves in leaf order for `#goto`. The wrapped variants continue from the
    # other end of the tree.
    enum Goto
      Previous
      Next
      PreviousWrapped
      NextWrapped
    end

    # Inner node: *ratio* is the share of the left (or top) child.
    record Split, layout : Layout, ratio : Float64, left : Int32, right : Int32 do
      def child(side : Side) : Int32
        side.left? ? left : right
      end

      def offset(by : Int32) : Split
        copy_with(left: left + by, right: right + by)
      end
    end

    # Rectangle of a node on the unit square (`#spatial`).
    record Slot, x : Float64, y : Float64, width : Float64, height : Float64 do
      def max_x : Float64
        x + width
      end

      def max_y : Float64
        y + height
      end
    end

    # Leaf rectangle of `#to_diagram`, in cells.
    private record Box, x : Int32, y : Int32, width : Int32, height : Int32, label : String

    # Results of the backtracking searches besides a handle.
    private DEADEND   = -2
    private BACKTRACK = -1

    # Tolerance for slot edges computed along different paths.
    private EPSILON = 1e-9

    getter zoomed : Int32?

    protected getter nodes : Array(V | Split)

    # Creates an empty tree.
    def initialize
      @nodes = [] of V | Split
      @zoomed = nil
    end

    # Creates a tree holding only *view*.
    def initialize(view : V)
      @nodes = [view] of V | Split
      @zoomed = nil
    end

    protected def initialize(@nodes : Array(V | Split), @zoomed : Int32?)
    end

    def empty? : Bool
      @nodes.empty?
    end

    # Returns whether the root is a split.
    def split? : Bool
      @nodes.first?.is_a?(Split)
    end

    def node_count : Int32
      @nodes.size
    end

    # Returns the node at *handle*. Raises `IndexError` for an invalid handle.
    def [](handle : Int32) : V | Split
      check(handle)
      @nodes.unsafe_fetch(handle)
    end

    # Whether *other* is this tree, not just an equal one: trees that
    # share their nodes and zoom.
    def same?(other : SplitTree(V)) : Bool
      @nodes.same?(other.nodes) && @zoomed == other.zoomed
    end

    # Returns the view at *handle*. Raises `ArgumentError` when it is a split.
    def view(handle : Int32) : V
      node = self[handle]
      raise ArgumentError.new("split tree node #{handle} is a split") if node.is_a?(Split)
      node
    end

    # Yields the handle and view of every leaf, in node order.
    def each(& : {Int32, V} ->) : Nil
      @nodes.each_with_index do |node, handle|
        yield({handle, node}) unless node.is_a?(Split)
      end
    end

    # Returns the handle of the first leaf equal to *view*.
    def locate(view : V) : Int32?
      each { |handle, leaf| return handle if leaf == view }
    end

    # Returns a copy that zooms *handle*, or nothing for `nil`.
    def zoom(handle : Int32?) : SplitTree(V)
      check(handle) if handle
      SplitTree(V).new(@nodes, handle)
    end

    # Returns the leaf before or after *from* in leaf order, or `nil` at the
    # end of the tree unless the move wraps.
    def goto(from : Int32, to : Goto) : Int32?
      check(from)
      case to
      in .previous?         then adjacent(from, :left)
      in .next?             then adjacent(from, :right)
      in .previous_wrapped? then adjacent(from, :left) || deepest(:right)
      in .next_wrapped?     then adjacent(from, :right) || deepest(:left)
      end
    end

    # Returns the nearest leaf in *direction* from *from*, wrapping around the
    # opposite edge, or `nil` when no other leaf lies that way.
    def goto(from : Int32, to : Direction) : Int32?
      check(from)
      slots = spatial
      target = slots[from]
      nearest(slots, from, to, target) || nearest(slots, from, to, wrapped(target, to))
    end

    # Returns the leaf reached by always descending to the *side* child,
    # starting at *from*.
    def deepest(side : Side, from : Int32 = ROOT) : Int32
      check(from)
      current = from
      while (node = @nodes.unsafe_fetch(current)).is_a?(Split)
        current = node.child(side)
      end
      current
    end

    # Returns a tree where the node at *at* shares its place with *insert*,
    # placed in *direction*; *ratio* is the share of the left or top child.
    # The zoom is reset. Raises `ArgumentError` for an empty *insert* or a
    # ratio outside `0..1`.
    def split(at : Int32, direction : Direction, insert : SplitTree(V) | V, ratio : Float64 = 0.5) : SplitTree(V)
      check(at)
      check_ratio(ratio)
      other = insert.is_a?(SplitTree(V)) ? insert : SplitTree(V).new(insert)
      raise ArgumentError.new("cannot insert an empty split tree") if other.empty?

      offset = @nodes.size
      nodes = Array(V | Split).new(offset + other.node_count + 1)
      nodes.concat(@nodes)
      other.nodes.each { |node| nodes << (node.is_a?(Split) ? node.offset(offset) : node) }
      moved = nodes.size
      nodes << @nodes.unsafe_fetch(at)

      layout = Layout.of(direction)
      nodes[at] =
        if direction.left? || direction.up?
          Split.new(layout, ratio, offset, moved)
        else
          Split.new(layout, ratio, moved, offset)
        end
      SplitTree(V).new(nodes, nil)
    end

    # Returns a tree without the node at *at*; its sibling takes the parent's
    # place. Removing the root empties the tree. The zoom follows its node and
    # is cleared when that node is removed.
    def remove(at : Int32) : SplitTree(V)
      check(at)
      return SplitTree(V).new if at == ROOT
      nodes = Array(V | Split).new(@nodes.size)
      zoomed = prune(nodes, ROOT, at)
      SplitTree(V).new(nodes, zoomed)
    end

    # Returns a tree where each split shares its space by the number of
    # leaves laid out along its axis.
    def equalize : SplitTree(V)
      nodes = @nodes.map do |node|
        next node unless node.is_a?(Split)
        left = weight(node.left, node.layout)
        node.copy_with(ratio: left / (left + weight(node.right, node.layout)))
      end
      SplitTree(V).new(nodes, @zoomed)
    end

    # Returns a tree where the nearest split with *layout* above *from* moves
    # its divider by *delta* of the whole tree's size (positive moves right
    # or down). The tree is unchanged without such a split. Raises
    # `ArgumentError` unless *delta* is within `-1..1`.
    def resize(from : Int32, layout : Layout, delta : Float64) : SplitTree(V)
      check(from)
      unless -1.0 <= delta <= 1.0
        raise ArgumentError.new("resize delta must be between -1 and 1, not #{delta}")
      end
      parent = parent_split(layout, from, ROOT)
      return self if parent < 0

      slot = spatial[parent]
      scale = layout.horizontal? ? slot.width : slot.height
      return self if scale == 0
      split = @nodes.unsafe_fetch(parent).as(Split)
      with_ratio(parent, (split.ratio + delta / scale).clamp(0.0, 1.0))
    end

    # Returns a tree where the split at *at* has *ratio*. Raises
    # `ArgumentError` for a leaf or a ratio outside `0..1`.
    def with_ratio(at : Int32, ratio : Float64) : SplitTree(V)
      split = self[at]
      raise ArgumentError.new("split tree node #{at} is a leaf") unless split.is_a?(Split)
      check_ratio(ratio)
      nodes = @nodes.dup
      nodes[at] = split.copy_with(ratio: ratio)
      SplitTree(V).new(nodes, @zoomed)
    end

    # Returns the rectangle of every node, indexed by handle, with the whole
    # tree on the unit square and each leaf weighing the same before ratios
    # apply.
    def spatial : Array(Slot)
      return [] of Slot if empty?
      width, height = dimensions(ROOT)
      slots = Array.new(@nodes.size, Slot.new(0.0, 0.0, 0.0, 0.0))
      slots[ROOT] = Slot.new(0.0, 0.0, width.to_f, height.to_f)
      fill(slots, ROOT)
      slots.map! do |slot|
        Slot.new(slot.x / width, slot.y / height, slot.width / width, slot.height / height)
      end
    end

    # Writes the tree as indented text, one node per line.
    def to_s(io : IO) : Nil
      if empty?
        io << "empty"
      else
        write_node(io, ROOT, 0)
      end
    end

    # Returns the leaves drawn as ASCII boxes, scaled so the smallest leaf is
    # one cell. Leaves without width or height are left out.
    def to_diagram : String
      return "empty" if empty?
      slots = spatial
      min_width = min_height = 1.0
      slots.each do |slot|
        min_width = Math.min(min_width, slot.width) if slot.width > 0
        min_height = Math.min(min_height, slot.height) if slot.height > 0
      end

      boxes = [] of Box
      each do |handle, view|
        slot = slots.unsafe_fetch(handle)
        next if slot.width == 0 || slot.height == 0
        x = cell(slot.x / min_width)
        y = cell(slot.y / min_height)
        width = Math.max(cell(slot.max_x / min_width) - x, 1)
        height = Math.max(cell(slot.max_y / min_height) - y, 1)
        boxes << Box.new(x, y, width, height, view.to_s)
      end

      cell_width = boxes.max_of(&.label.size) + 4
      cell_height = 3
      columns = boxes.max_of { |box| box.x + box.width } * cell_width
      rows = boxes.max_of { |box| box.y + box.height } * cell_height
      grid = Array.new(rows) { Array.new(columns, ' ') }
      boxes.each { |box| draw(grid, box, cell_width, cell_height) }

      String.build do |io|
        grid.each do |row|
          row.each { |char| io << char }
          io << '\n'
        end
      end
    end

    private def check(handle : Int32) : Nil
      return if 0 <= handle < @nodes.size
      raise IndexError.new("invalid split tree handle #{handle}")
    end

    private def check_ratio(ratio : Float64) : Nil
      return if 0.0 <= ratio <= 1.0
      raise ArgumentError.new("split ratio must be between 0 and 1, not #{ratio}")
    end

    # The leaf before (*side* `Left`) or after (`Right`) *from*.
    private def adjacent(from : Int32, side : Side) : Int32?
      result = adjacent(from, ROOT, side)
      result if result >= 0
    end

    # Searches the *side*-first child, then the other one. When *from* is the
    # first leaf of the other child, the answer is the last leaf of the first
    # one; when it is the first leaf of *current*, the search backtracks.
    private def adjacent(from : Int32, current : Int32, side : Side) : Int32
      return BACKTRACK if from == current
      node = @nodes.unsafe_fetch(current)
      return DEADEND unless node.is_a?(Split)
      near = node.child(side)
      result = adjacent(from, near, side)
      return result unless result == DEADEND
      result = adjacent(from, node.child(side.opposite), side)
      result == BACKTRACK ? deepest(side.opposite, near) : result
    end

    # The split with *layout* nearest above *from*, or `DEADEND`/`BACKTRACK`.
    private def parent_split(layout : Layout, from : Int32, current : Int32) : Int32
      return BACKTRACK if from == current
      node = @nodes.unsafe_fetch(current)
      return DEADEND unless node.is_a?(Split)
      {node.left, node.right}.each do |child|
        result = parent_split(layout, from, child)
        next if result == DEADEND
        return result unless result == BACKTRACK
        return node.layout == layout ? current : BACKTRACK
      end
      DEADEND
    end

    private def nearest(slots : Array(Slot), from : Int32, direction : Direction, target : Slot) : Int32?
      best = nil
      best_distance = Float64::INFINITY
      slots.each_with_index do |slot, handle|
        next if handle == from || @nodes.unsafe_fetch(handle).is_a?(Split)
        next unless beyond?(slot, target, direction)
        distance = Math.hypot(slot.x - target.x, slot.y - target.y)
        next unless distance < best_distance
        best = handle
        best_distance = distance
      end
      best
    end

    private def beyond?(slot : Slot, target : Slot, direction : Direction) : Bool
      case direction
      in .left?  then slot.max_x <= target.x + EPSILON
      in .right? then slot.x >= target.max_x - EPSILON
      in .up?    then slot.max_y <= target.y + EPSILON
      in .down?  then slot.y >= target.max_y - EPSILON
      end
    end

    # *target* moved past the opposite edge of the unit square.
    private def wrapped(target : Slot, direction : Direction) : Slot
      case direction
      in .left?  then target.copy_with(x: target.x + 1)
      in .right? then target.copy_with(x: target.x - 1)
      in .up?    then target.copy_with(y: target.y + 1)
      in .down?  then target.copy_with(y: target.y - 1)
      end
    end

    # Appends the subtree at *current* without *target* to *nodes* in depth
    # first order and returns the new handle of the zoomed node, if kept.
    private def prune(nodes : Array(V | Split), current : Int32, target : Int32) : Int32?
      zoomed = nodes.size if current == @zoomed
      node = @nodes.unsafe_fetch(current)
      unless node.is_a?(Split)
        nodes << node
        return zoomed
      end
      return prune(nodes, node.right, target) || zoomed if node.left == target
      return prune(nodes, node.left, target) || zoomed if node.right == target

      index = nodes.size
      nodes << node
      left = nodes.size
      left_zoomed = prune(nodes, node.left, target)
      right = nodes.size
      right_zoomed = prune(nodes, node.right, target)
      nodes[index] = node.copy_with(left: left, right: right)
      zoomed || left_zoomed || right_zoomed
    end

    # Leaves along *layout* below *handle*; a split across it counts as one.
    private def weight(handle : Int32, layout : Layout) : Int32
      node = @nodes.unsafe_fetch(handle)
      return 1 unless node.is_a?(Split) && node.layout == layout
      weight(node.left, layout) + weight(node.right, layout)
    end

    # Width and height of the subtree at *handle*, each leaf being 1x1.
    private def dimensions(handle : Int32) : {Int32, Int32}
      node = @nodes.unsafe_fetch(handle)
      return {1, 1} unless node.is_a?(Split)
      left_width, left_height = dimensions(node.left)
      right_width, right_height = dimensions(node.right)
      if node.layout.horizontal?
        {left_width + right_width, Math.max(left_height, right_height)}
      else
        {Math.max(left_width, right_width), left_height + right_height}
      end
    end

    private def fill(slots : Array(Slot), handle : Int32) : Nil
      node = @nodes.unsafe_fetch(handle)
      return unless node.is_a?(Split)
      slot = slots[handle]
      ratio = node.ratio
      if node.layout.horizontal?
        slots[node.left] = slot.copy_with(width: slot.width * ratio)
        slots[node.right] = slot.copy_with(x: slot.x + slot.width * ratio, width: slot.width * (1 - ratio))
      else
        slots[node.left] = slot.copy_with(height: slot.height * ratio)
        slots[node.right] = slot.copy_with(y: slot.y + slot.height * ratio, height: slot.height * (1 - ratio))
      end
      fill(slots, node.left)
      fill(slots, node.right)
    end

    private def write_node(io : IO, handle : Int32, depth : Int32) : Nil
      depth.times { io << "  " }
      io << "(zoomed) " if handle == @zoomed
      node = @nodes.unsafe_fetch(handle)
      if node.is_a?(Split)
        io << "split (layout: " << node.layout.to_s.downcase << ", ratio: "
        io.printf("%.2f", node.ratio)
        io << ")\n"
        write_node(io, node.left, depth + 1)
        write_node(io, node.right, depth + 1)
      else
        io << "leaf: " << node << '\n'
      end
    end

    # Rounds a diagram edge to the nearest cell. Edges are rounded rather
    # than sizes so neighbouring boxes always meet.
    private def cell(value : Float64) : Int32
      (value + 0.5 + EPSILON).floor.to_i
    end

    private def draw(grid : Array(Array(Char)), box : Box, cell_width : Int32, cell_height : Int32) : Nil
      left = box.x * cell_width
      top = box.y * cell_height
      width = box.width * cell_width
      height = box.height * cell_height
      right = left + width - 1
      bottom = top + height - 1

      {top, bottom}.each do |row|
        grid[row][left] = grid[row][right] = '+'
        (left + 1...right).each { |column| grid[row][column] = '-' }
      end
      (top + 1...bottom).each do |row|
        grid[row][left] = grid[row][right] = '|'
      end

      start = left + width // 2 - box.label.size // 2
      box.label.each_char_with_index { |char, index| grid[top + height // 2][start + index] = char }
    end
  end
end
