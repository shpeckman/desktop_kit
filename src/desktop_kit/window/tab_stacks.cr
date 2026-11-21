# src/desktop_kit/window/tab_stacks.cr
module DesktopKit
  class Tab
    protected def stacked?(surface : Surface) : Bool
      tree = @view.tree
      handle = tree.locate(surface) || return false
      tree.stacked?(handle)
    end

    protected def stack(surface : Surface) : Array(Surface)
      tree = @view.tree
      handle = tree.locate(surface) || return [surface]
      tree.views(handle)
    end

    # Moves the split *surface* into the stack of the split next to it in
    # *direction*, wrapping around the tab, and focuses it.
    protected def stack_into(surface : Surface, direction : Direction) : Bool
      return false if @destroyed || floating?(surface)
      tree = @view.tree
      handle = tree.locate(surface) || return false
      target = tree.goto(handle, direction) || return false
      return false if target == handle
      stack_with(surface, tree.view(target))
    end

    # Moves *surface*, a split or a float, into the stack of the split
    # *other* and focuses it.
    protected def stack_with(surface : Surface, other : Surface) : Bool
      return false if @destroyed || surface == other || !contains?(surface)
      tree = @view.tree
      return false unless tree.locate(other)
      if floating?(surface)
        @view.floats = without(surface)
      else
        tree = tree.without(surface)
      end
      at = tree.locate(other) || return false
      @view.tree = tree.join(at, surface)
      activate(surface)
      true
    end

    # Splits the stacked *surface* out beside its stack along *layout*, the
    # longer side of the stack's place for `Auto`, and focuses it.
    protected def unstack(surface : Surface, layout : Action::Unstack::Layout) : Bool
      return false if @destroyed
      tree = @view.tree
      handle = tree.locate(surface) || return false
      return false unless tree.stacked?(handle)
      axis = case layout
             in .horizontal? then SplitTree::Layout::Horizontal
             in .vertical?   then SplitTree::Layout::Vertical
             in .auto?
               host = tree.view(handle).host
               host.width >= host.height ? SplitTree::Layout::Horizontal : SplitTree::Layout::Vertical
             end
      @view.tree = tree.unstack(surface, axis)
      activate(surface)
      true
    end

    # Shows and focuses the surface at *index* of the stack *surface* is in,
    # or the one before, after or last of the shown one for the
    # `Action::GotoStacked` constants.
    protected def goto_stacked(surface : Surface, index : Int32) : Bool
      return false if @destroyed
      tree = @view.tree
      handle = tree.locate(surface) || return false
      stack = tree[handle]
      return false unless stack.is_a?(SplitTree::Stack(Surface))
      size = stack.views.size
      target = case index
               when Action::GotoStacked::PREVIOUS then (stack.index - 1) % size
               when Action::GotoStacked::NEXT     then (stack.index + 1) % size
               when Action::GotoStacked::LAST     then size - 1
               else                                    index
               end
      return false unless 0 <= target < size
      activate(stack.views.unsafe_fetch(target))
      true
    end
  end
end
