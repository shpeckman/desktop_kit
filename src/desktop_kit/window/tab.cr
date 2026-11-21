# src/desktop_kit/window/tab.cr
module DesktopKit
  # A tab of a window: one or more surfaces laid out in splits.
  #
  # Tab actions act on the selected tab of a window, split actions on its
  # active surface. Use it on the GTK thread only.
  class Tab
    # Prefix of the title while a surface is zoomed.
    private ZOOM_MARK = "🔍 "
    private BELL_MARK = "🔔 "

    # The title the user chose; shown instead of the surface titles while
    # set.
    getter title_override : String?

    @view = SplitView.new
    @active : Surface?
    # The split focused last; floats split in beside it.
    @last_tile : Surface?
    @window : Window?
    @closing = false
    @destroyed = false

    protected def initialize(@app : App, surface : Surface)
      surface.tab = self
      @view.tree = SplitTree(Surface).new(surface)
      self.active = surface
      @view.focus = surface
      @app.register(self)
    end

    # Reopens the surfaces of *tree* and *floats* in a new tab, *active*
    # shown and focused.
    protected def initialize(@app : App, tree : SplitTree(Surface), active : Surface? = nil, floats : Array(Floating) = [] of Floating)
      tree.each { |_, surface| surface.tab = self }
      floats.each(&.surface.tab = self)
      active ||= tree.view(tree.deepest(:left))
      handle = tree.locate(active)
      if handle && tree.stacked?(handle) && (index = tree.views(handle).index(active))
        tree = tree.show(handle, index)
      end
      @view.tree = tree
      @view.floats = floats unless floats.empty?
      self.active = active
      @view.focus = active
      @app.register(self)
    end

    protected def tree : SplitTree(Surface)
      @view.tree
    end

    # Returns the window showing the tab, or `nil` once it is closed.
    def window : Window?
      @window unless @destroyed
    end

    # Returns the splits from the left or top to the right or bottom, the
    # surfaces of a stack in its order, then the floating surfaces from the
    # bottom one to the top one.
    def surfaces : Array(Surface)
      surfaces = [] of Surface
      each_leaf { |handle| surfaces.concat(@view.tree.views(handle)) }
      @view.floats.each { |float| surfaces << float.surface }
      surfaces
    end

    # Returns the surface focused last, which split actions act on.
    def active_surface : Surface?
      @active
    end

    # Returns the title shown on the tab: `#title_override`, else the title
    # of the active surface, else the application name; marked while zoomed
    # or while a bell rings.
    def title : String
      title = @title_override || @active.try(&.shown_title) || Window.default_title
      title = ZOOM_MARK + title if zoomed?
      title = BELL_MARK + title if @app.bell.title? && any_surface?(&.bell_ringing?)
      title
    end

    # Sets the title the user chose; `nil` restores the surface titles.
    def title_override=(title : String?) : String?
      @title_override = title
      sync_title
      title
    end

    # Returns whether a surface fills the tab, hiding the others.
    def zoomed? : Bool
      !@view.tree.zoomed.nil?
    end

    def closed? : Bool
      @destroyed
    end

    # Closes the tab, asking the user first when one of its surfaces has
    # `Surface#confirm_close?`.
    def close : Nil
      @window.try(&.close_tabs(self, :this)) unless @destroyed
    end

    protected def window=(window : Window) : Window
      @window = window
    end

    protected def root : Widget
      @view.root
    end

    # The page of the tab in *window*'s tab view.
    protected def page(window : Window) : Void*
      C.adw_tab_view_get_page(window.tab_view, root)
    end

    # Whether closing the tab goes ahead without asking: it is closing its
    # last surface or nothing in it wants a confirmation.
    protected def close_unconfirmed? : Bool
      @closing || !any_surface?(&.confirm_close?)
    end

    # The number of surfaces in the tab.
    protected def surface_count : Int32
      @view.tree.size + @view.floats.size
    end

    # The surfaces on screen when nothing is zoomed, in focus cycle order:
    # the splits, the shown one of a stack, then the floats from the bottom
    # one up.
    protected def shown_surfaces : Array(Surface)
      surfaces = [] of Surface
      each_leaf { |handle| surfaces << @view.tree.view(handle) }
      @view.floats.each { |float| surfaces << float.surface }
      surfaces
    end

    # Yields the handle of every leaf from the left or top to the right or
    # bottom.
    private def each_leaf(& : Int32 ->) : Nil
      tree = @view.tree
      return if tree.empty?
      handle = tree.deepest(:left)
      loop do
        yield handle
        handle = tree.goto(handle, :next) || break
      end
    end

    protected def each_surface(& : Surface ->) : Nil
      @view.tree.each { |_, surface| yield surface }
      @view.floats.each { |float| yield float.surface }
    end

    # Splits a new surface off *from*, or off the split focused last when
    # *from* floats.
    protected def split(from : Surface, direction : Direction) : Surface
      raise RuntimeError.new("the tab is closed") if @destroyed
      raise ArgumentError.new("the surface is not in this tab") unless contains?(from)
      anchor = floating?(from) ? last_tile : from
      handle = anchor.try { |anchor| @view.tree.locate(anchor) } || raise ArgumentError.new("the tab has no split")
      surface = @app.create_surface(:split, from)
      surface.tab = self
      @view.tree = @view.tree.split(handle, direction, surface)
      activate(surface)
      surface
    end

    # Drops *surface*, kept for undo; dropping the last one closes the tab
    # without asking.
    protected def remove(surface : Surface) : Nil
      return if @destroyed || !contains?(surface)
      before = state
      count = surface_count
      float = floating(surface).try(&.bounds)
      # Closing the last split promotes the top float to it.
      promoted = @view.floats.last? if float.nil? && @view.tree.size == 1
      window = @window
      position = window.try { |window| C.adw_tab_view_get_page_position(window.tab_view, page(window)) }
      detach(surface)
      if count > 1
        @app.undo_stack.record(UndoStack::ClosedSurface.new(surface, self, before.tree, @view.tree, float, promoted))
      elsif window && position
        @app.undo_stack.record(UndoStack::ClosedTab.new(before, window, position))
      else
        surface.release
      end
    end

    # Puts *surface* back: a float at *float*, its bounds; else the tree
    # returns to *before* while it is still *after*, and *promoted*, the
    # float that took the last split's place, floats again; otherwise
    # *surface* splits off the active split. False once the tab is closed.
    protected def restore(surface : Surface, before : SplitTree(Surface), after : SplitTree(Surface), float : Bounds? = nil, promoted : Floating? = nil) : Bool
      return false if @destroyed
      tree = @view.tree
      if float
        @view.floats = @view.floats + [Floating.new(surface, float)]
      elsif tree.same?(after)
        # The promoted host leaves the tiles before it joins the overlay.
        @view.release_widgets if promoted
        @view.tree = before
        @view.floats = @view.floats + [promoted] if promoted
      else
        target = @active.try { |active| active if tree.locate(active) } || last_tile || return false
        handle = tree.locate(target) || return false
        @view.tree = tree.split(handle, :right, SplitTree(Surface).new(surface))
      end
      surface.tab = self
      activate(surface)
      true
    end

    protected def state : UndoStack::TabState
      UndoStack::TabState.new(@view.tree, @active, @title_override, @view.floats)
    end

    # Moves *surface*, from this or another tab, next to *target* on its
    # *direction* side and focuses it.
    protected def insert(surface : Surface, target : Surface, direction : Direction) : Nil
      return if @destroyed || surface == target
      source = surface.tab || return
      at = @view.tree.locate(target) || return
      if source == self && floating?(surface)
        @view.floats = without(surface)
        @view.tree = @view.tree.split(at, direction, surface)
      elsif source == self
        # Out first, so a stacked surface leaves its stack alone.
        tree = @view.tree.without(surface)
        at = tree.locate(target) || return
        @view.tree = tree.split(at, direction, surface)
      else
        # Release widgets first: GTK rejects a host that still has a parent.
        source.detach(surface, release_widgets: true)
        surface.tab = self
        # Detaching closes no surface of this tab, so *at* stays valid.
        @view.tree = @view.tree.split(at, direction, surface)
      end
      activate(surface)
    end

    # Takes *surface* out of the tree without releasing it; taking the last
    # one closes the tab without asking. *release_widgets* unparents the
    # widgets at once, for a surface that joins another tab.
    protected def detach(surface : Surface, release_widgets : Bool = false) : Nil
      return unless contains?(surface)
      surface.tab = nil
      # A float's host leaves the overlay in `#unlink` at once; the splits
      # stay put.
      @view.release_widgets if release_widgets && !floating?(surface)
      if surface_count == 1
        # Last surface: close the tab without releasing the surface.
        @view.tree = SplitTree(Surface).new
        self.active = nil
        return close_now
      end
      heir = unlink(surface)
      if heir && @active == surface
        activate(heir)
      else
        sync_title
      end
    end

    private def contains?(surface : Surface) : Bool
      !@view.tree.locate(surface).nil? || floating?(surface)
    end

    # Takes *surface* out of its place and returns the surface to focus in
    # its stead. Every surface leaves its place through here, which keeps a
    # split in the tree while floats remain.
    private def unlink(surface : Surface) : Surface?
      @last_tile = nil if @last_tile == surface
      floats = @view.floats
      if floating?(surface)
        rest = without(surface)
        @view.floats = rest
        return rest.last?.try(&.surface) || last_tile
      end
      tree = @view.tree
      handle = tree.locate(surface) || return
      if tree.stacked?(handle)
        # The stack shows another surface in the same place.
        tree = tree.without(surface)
        @view.tree = tree
        return tree.view(handle)
      end
      if tree.size == 1
        # The last split: the top float takes its place.
        top = floats.last? || return
        @view.tree = SplitTree(Surface).new(top.surface)
        @view.floats = floats[0, floats.size - 1]
        return top.surface
      end
      heir = tree.goto(handle, :previous) || tree.goto(handle, :next)
      @view.tree = tree.remove(handle)
      heir.try { |heir| tree.view(heir) }
    end

    # Makes *surface* the active surface, ends a zoom on another surface,
    # raises a float or shows a hidden stacked surface, selects the tab and
    # focuses *surface*.
    protected def activate(surface : Surface) : Nil
      return if @destroyed
      tree = @view.tree
      if floating?(surface)
        # Floats hide while a split is zoomed.
        @view.tree = tree.zoom(nil) if tree.zoomed
        raise_float(surface)
      else
        handle = tree.locate(surface) || return
        if (zoomed = tree.zoomed) && zoomed != handle
          tree = tree.zoom(nil)
          @view.tree = tree
        end
        # A hidden stacked surface shows in its stack's place.
        unless tree.view(handle) == surface
          index = tree.views(handle).index(surface) || return
          @view.show(tree.show(handle, index))
        end
      end
      self.active = surface
      @view.focus = surface
      @window.try(&.select(self))
      surface.grab_focus unless @view.pending?
      sync_title
    end

    # Records the focus moving into *surface*. While the splits wait to be
    # rebuilt the focus GTK hands around is transient: the rebuild focuses
    # the view's surface, so a float that GTK focuses as its page is selected
    # neither rises nor takes over.
    protected def focused(surface : Surface) : Nil
      return if @destroyed || @view.pending?
      raise_float(surface) if floating?(surface)
      return if @active == surface
      self.active = surface
      @view.focus = surface
      sync_title
    end

    # Focuses the surface before or after *from* in `#shown_surfaces`, or
    # the split next to *from* in *direction*; floats have no neighbours in
    # a direction.
    protected def goto(from : Surface, direction : Action::GotoSplit::Direction) : Bool
      if direction.previous? || direction.next?
        shown = shown_surfaces
        index = shown.index(from) || return false
        return false if shown.size < 2
        activate(shown[(index + (direction.next? ? 1 : -1)) % shown.size])
        return true
      end
      tree = @view.tree
      handle = tree.locate(from) || return false
      target =
        case direction
        in .previous?, .next? then nil
        in .left?             then tree.goto(handle, Direction::Left)
        in .right?            then tree.goto(handle, Direction::Right)
        in .up?               then tree.goto(handle, Direction::Up)
        in .down?             then tree.goto(handle, Direction::Down)
        end
      return false if target.nil? || target == handle
      activate(tree.view(target))
      true
    end

    # Swaps *from* with the split in *direction*; *from* keeps the focus.
    protected def swap(from : Surface, direction : Action::SwapSplit::Direction) : Bool
      tree = @view.tree
      handle = tree.locate(from) || return false
      target =
        case direction
        in .previous? then tree.goto(handle, :previous_wrapped)
        in .next?     then tree.goto(handle, :next_wrapped)
        in .left?     then tree.goto(handle, Direction::Left)
        in .right?    then tree.goto(handle, Direction::Right)
        in .up?       then tree.goto(handle, Direction::Up)
        in .down?     then tree.goto(handle, Direction::Down)
        in .first?    then tree.deepest(:left)
        end
      return false if target.nil? || target == handle
      @view.tree = tree.swap(handle, target)
      @view.focus = from
      true
    end

    # Swaps surfaces *a* and *b* of the tab; the focus stays on its surface.
    protected def swap(a : Surface, b : Surface) : Bool
      tree = @view.tree
      first = tree.locate(a) || return false
      second = tree.locate(b) || return false
      return false if first == second
      @view.tree = tree.swap(first, second)
      @active.try { |active| @view.focus = active }
      true
    end

    # Moves the divider next to *from* by *amount* pixels in *direction*.
    protected def resize(from : Surface, direction : Direction, amount : UInt32) : Bool
      return resize_float(from, direction, amount) if floating?(from)
      tree = @view.tree
      handle = tree.locate(from) || return false
      layout = SplitTree::Layout.of(direction)
      extent = layout.horizontal? ? root.width : root.height
      return false if extent <= 0
      delta = Math.min(amount.to_f / extent, 1.0)
      delta = -delta if direction.left? || direction.up?
      resized = tree.resize(handle, layout, delta)
      return false if resized == tree
      @view.tree = resized
      true
    end

    # Whether resizing *from* in *direction* makes it larger: a float grows
    # right and down, a split towards its divider.
    protected def grows?(from : Surface, direction : Direction) : Bool
      return direction.right? || direction.down? if floating?(from)
      tree = @view.tree
      handle = tree.locate(from) || return false
      side = tree.side(handle, SplitTree::Layout.of(direction)) || return false
      side.left? == (direction.right? || direction.down?)
    end

    protected def equalize : Bool
      tree = @view.tree
      return false unless tree.split?
      @view.tree = tree.equalize
      true
    end

    protected def toggle_zoom(from : Surface) : Bool
      tree = @view.tree
      return false unless tree.split?
      handle = tree.locate(from) || return false
      @view.tree = tree.zoom(tree.zoomed ? nil : handle)
      self.active = from
      @view.focus = from
      sync_title
      true
    end

    # Marks the tab's page for attention unless it is selected or
    # *attention* is false, and shows the bell in the title.
    protected def bell(attention : Bool) : Nil
      if attention && (window = @window)
        page = page(window)
        C.adw_tab_page_set_needs_attention(page, 1) unless page.null? || C.adw_tab_page_get_selected(page) != 0
      end
      sync_title
    end

    protected def sync_title : Nil
      return if @destroyed
      window = @window || return
      page = page(window)
      unless page.null?
        C.adw_tab_page_set_title(page, title)
        icon = @active.try(&.icon).try { |value| GIcon.new(value) } || Pointer(Void).null
        C.adw_tab_page_set_icon(page, icon)
        C.g_object_unref(icon) unless icon.null?
        C.adw_tab_page_set_loading(page, any_surface?(&.progress) ? 1 : 0)
      end
      window.sync_title
    end

    # Shows a spinner on the tab while any of its surfaces has progress.
    protected def sync_progress : Nil
      return if @destroyed
      window = @window || return
      page = page(window)
      C.adw_tab_page_set_loading(page, any_surface?(&.progress) ? 1 : 0) unless page.null?
    end

    private def any_surface?(& : Surface -> _) : Bool
      each_surface { |surface| return true if yield surface }
      false
    end

    # Moves the active mark from the previous active surface to *surface*.
    private def active=(surface : Surface?) : Surface?
      @active.try(&.active = false)
      @active = surface
      @last_tile = surface if surface && @view.tree.locate(surface)
      surface.try(&.active = true)
      surface
    end

    # Forgets the tab once its page is gone; GTK disposes the widgets. A
    # tab closed at *position* of its window is kept for undo, *keep* leaves
    # the surfaces to the caller, and otherwise they are released.
    protected def destroy(position : Int32? = nil, *, keep : Bool = false) : Nil
      return if @destroyed
      state = self.state
      window = @window
      @destroyed = true
      @view.destroy
      self.active = nil
      @app.unregister(self)
      return if keep || state.tree.empty?
      if position && window
        @app.undo_stack.record(UndoStack::ClosedTab.new(state, window, position))
      else
        each_surface(&.release)
      end
    end

    private def close_now : Nil
      @closing = true
      if window = @window
        C.adw_tab_view_close_page(window.tab_view, page(window))
      else
        destroy
      end
    end
  end

  abstract class App
    protected def perform(target : Tab, action : Action::CloseTab) : Bool
      target.window.try(&.close_tabs(target, action.mode)) || false
    end

    protected def perform(target : Tab, action : Action::MoveTab) : Bool
      target.window.try(&.move_tab(target, action.amount)) || false
    end

    protected def perform(target : Tab, action : Action::MoveTabToNewWindow) : Bool
      target.window.try(&.move_to_new_window(target)) || false
    end

    protected def perform(target : Tab, action : Action::SetTabTitle) : Bool
      target.title_override = action.title
      true
    end
  end
end
