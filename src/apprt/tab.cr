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
      @active = surface
      @view.focus = surface
      @view.tree = SplitTree(Surface).new(surface)
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
      title = BELL_MARK + title if @view.tree.any? { |_, surface| surface.bell_ringing? }
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

    # Drops *surface*; dropping the last one closes the tab without asking.
    protected def remove(surface : Surface) : Nil
      return if @destroyed
      tree = @view.tree
      handle = tree.locate(surface) || return
      return close_now unless tree.split?
      successor = tree.goto(handle, :previous) || tree.goto(handle, :next) if @active == surface
      @view.tree = tree.remove(handle)
      surface.release
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
      @active = surface
      @view.focus = surface
      @window.try(&.select(self))
      surface.grab_focus unless @view.pending?
      sync_title
    end

    # Records the focus moving into *surface*.
    protected def focused(surface : Surface) : Nil
      return if @destroyed || @active == surface
      @active = surface
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
      @active = from
      @view.focus = from
      sync_title
      true
    end

    # Marks the tab's page for attention unless it is selected.
    protected def bell : Nil
      if window = @window
        page = page(window)
        C.adw_tab_page_set_needs_attention(page, 1) unless page.null? || C.adw_tab_page_get_selected(page) != 0
      end
      sync_title
    end

    protected def sync_title : Nil
      return if @destroyed
      window = @window || return
      page = page(window)
      C.adw_tab_page_set_title(page, title) unless page.null?
      window.sync_title
    end

    # Forgets the tab and its surfaces once its page is gone; GTK disposes
    # the widgets.
    protected def destroy : Nil
      return if @destroyed
      @destroyed = true
      @view.destroy
      @view.tree.each { |_, surface| surface.release }
      @active = nil
      @app.unregister(self)
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
