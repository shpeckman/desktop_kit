# src/apprt/tab.cr
module Apprt
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
    @window : Window?
    @closing = false
    @destroyed = false

    protected def initialize(@app : App, surface : Surface)
      surface.tab = self
      self.active = surface
      @view.focus = surface
      @view.tree = SplitTree(Surface).new(surface)
      @app.register(self)
    end

    # Reopens the surfaces of *tree* in a new tab, *active* focused.
    protected def initialize(@app : App, tree : SplitTree(Surface), active : Surface?)
      tree.each { |_, surface| surface.tab = self }
      active ||= tree.first[1]
      self.active = active
      @view.focus = active
      @view.tree = tree
      @app.register(self)
    end

    # Returns the window showing the tab, or `nil` once it is closed.
    def window : Window?
      @window unless @destroyed
    end

    # Returns the surfaces from the left or top to the right or bottom.
    def surfaces : Array(Surface)
      tree = @view.tree
      surfaces = [] of Surface
      return surfaces if tree.empty?
      handle = tree.deepest(:left)
      loop do
        surfaces << tree.view(handle)
        handle = tree.goto(handle, :next) || break
      end
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
      title = BELL_MARK + title if @app.bell.title? && @view.tree.any? { |_, surface| surface.bell_ringing? }
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
      @closing || @view.tree.none? { |_, surface| surface.confirm_close? }
    end

    protected def split(from : Surface, direction : Direction) : Surface
      raise RuntimeError.new("the tab is closed") if @destroyed
      handle = @view.tree.locate(from) || raise ArgumentError.new("the surface is not in this tab")
      surface = @app.create_surface(:split, from)
      surface.tab = self
      @view.tree = @view.tree.split(handle, direction, surface)
      activate(surface)
      surface
    end

    # Drops *surface*, kept for undo; dropping the last one closes the tab
    # without asking.
    protected def remove(surface : Surface) : Nil
      return if @destroyed || !@view.tree.locate(surface)
      before = state
      window = @window
      position = window.try { |window| C.adw_tab_view_get_page_position(window.tab_view, page(window)) }
      detach(surface)
      if before.tree.split?
        @app.undo_stack.record(UndoStack::ClosedSurface.new(surface, self, before.tree, @view.tree))
      elsif window && position
        @app.undo_stack.record(UndoStack::ClosedTab.new(before, window, position))
      else
        surface.release
      end
    end

    # Puts *surface* back: the tree returns to *before* while it is still
    # *after*, otherwise *surface* splits off the active surface. False
    # once the tab is closed.
    protected def restore(surface : Surface, before : SplitTree(Surface), after : SplitTree(Surface)) : Bool
      return false if @destroyed
      tree = @view.tree
      if tree.same?(after)
        @view.tree = before
      else
        target = @active || tree.first?.try(&.[1]) || return false
        handle = tree.locate(target) || return false
        @view.tree = tree.split(handle, :right, SplitTree(Surface).new(surface))
      end
      surface.tab = self
      activate(surface)
      true
    end

    protected def state : UndoStack::TabState
      UndoStack::TabState.new(@view.tree, @active, @title_override)
    end

    # Moves *surface*, from this or another tab, next to *target* on its
    # *direction* side and focuses it.
    protected def insert(surface : Surface, target : Surface, direction : Direction) : Nil
      return if @destroyed || surface == target
      source = surface.tab || return
      at = @view.tree.locate(target) || return
      if source == self
        old = @view.tree.locate(surface) || return
        @view.tree = @view.tree.split(at, direction, surface).remove(old)
      else
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
      tree = @view.tree
      handle = tree.locate(surface) || return
      surface.tab = nil
      @view.release_widgets if release_widgets
      unless tree.split?
        @view.tree = SplitTree(Surface).new
        self.active = nil
        return close_now
      end
      successor = tree.goto(handle, :previous) || tree.goto(handle, :next) if @active == surface
      @view.tree = tree.remove(handle)
      if successor
        activate(tree.view(successor))
      else
        sync_title
      end
    end

    # Makes *surface* the active surface, ends a zoom on another surface,
    # selects the tab and focuses *surface*.
    protected def activate(surface : Surface) : Nil
      return if @destroyed
      tree = @view.tree
      handle = tree.locate(surface) || return
      if (zoomed = tree.zoomed) && zoomed != handle
        @view.tree = tree.zoom(nil)
      end
      self.active = surface
      @view.focus = surface
      @window.try(&.select(self))
      surface.grab_focus unless @view.pending?
      sync_title
    end

    # Records the focus moving into *surface*.
    protected def focused(surface : Surface) : Nil
      return if @destroyed || @active == surface
      self.active = surface
      @view.focus = surface
      sync_title
    end

    protected def goto(from : Surface, direction : Action::GotoSplit::Direction) : Bool
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
        end
      return false if target.nil? || target == handle
      activate(tree.view(target))
      true
    end

    # Moves the divider next to *from* by *amount* pixels in *direction*.
    protected def resize(from : Surface, direction : Direction, amount : UInt32) : Bool
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
        C.adw_tab_page_set_loading(page, @view.tree.any? { |_, surface| surface.progress } ? 1 : 0)
      end
      window.sync_title
    end

    # Shows a spinner on the tab while any of its surfaces has progress.
    protected def sync_progress : Nil
      return if @destroyed
      window = @window || return
      page = page(window)
      C.adw_tab_page_set_loading(page, @view.tree.any? { |_, surface| surface.progress } ? 1 : 0) unless page.null?
    end

    # Moves the active mark from the previous active surface to *surface*.
    private def active=(surface : Surface?) : Surface?
      @active.try(&.active = false)
      @active = surface
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
        state.tree.each { |_, surface| surface.release }
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
