# src/desktop_kit/window/undo_stack.cr
module DesktopKit
  # :nodoc:
  # Closed surfaces, tabs and windows kept for `App#undo_timeout`, so
  # `Undo` can reopen them, and what undo reopened, so `Redo` can close it
  # again.
  class UndoStack
    # A surface closed out of a tab that stays open: *before* is the tab's
    # tree with it, *after* the tree without it.
    record ClosedSurface, surface : Surface, tab : Tab, before : SplitTree(Surface), after : SplitTree(Surface)

    # A tab's tree, its active surface and title override.
    record TabState, tree : SplitTree(Surface), active : Surface?, title_override : String?

    # A closed tab and its position in *window*.
    record ClosedTab, state : TabState, window : Window, position : Int32

    # A closed window's tabs, in order.
    record ClosedWindow, tabs : Array(TabState), panel : Panel?

    alias Closed = ClosedSurface | ClosedTab | ClosedWindow

    # One closed thing and the timer that releases it.
    private record Entry, id : UInt64, closed : Closed, timer : UInt32

    @entries = [] of Entry
    @reopened = [] of Surface | Tab | Window
    @redoing = false
    @next_id = 0_u64

    def initialize(@app : App)
    end

    # Keeps *closed* for `App#undo_timeout`, or releases it when undo is
    # off.
    def record(closed : Closed) : Nil
      timeout = @app.undo_timeout
      return release(closed) if timeout <= Time::Span.zero
      @reopened.clear unless @redoing
      id = @next_id += 1
      @entries << Entry.new(id, closed, Idle.after(timeout) { expire(id) })
    end

    # Reopens the latest closed thing; false when there is none.
    def undo : Bool
      entry = @entries.pop? || return false
      Idle.cancel(entry.timer)
      @reopened << reopen(entry.closed)
      true
    end

    # Closes the latest reopened thing again; false when there is none.
    def redo : Bool
      while target = @reopened.pop?
        next if target.closed?
        @redoing = true
        begin
          target.close
        ensure
          @redoing = false
        end
        return true
      end
      false
    end

    # Releases everything kept.
    def clear : Nil
      @entries.each do |entry|
        Idle.cancel(entry.timer)
        release(entry.closed)
      end
      @entries.clear
      @reopened.clear
    end

    private def expire(id : UInt64) : Nil
      index = @entries.index { |entry| entry.id == id } || return
      release(@entries.delete_at(index).closed)
    end

    private def release(closed : ClosedSurface) : Nil
      closed.surface.release
    end

    private def release(closed : ClosedTab) : Nil
      release(closed.state)
    end

    private def release(closed : ClosedWindow) : Nil
      closed.tabs.each { |state| release(state) }
    end

    private def release(state : TabState) : Nil
      state.tree.each { |_, surface| surface.release }
    end

    # Puts the surface back into its tab, or into a new tab when the tab is
    # gone.
    private def reopen(closed : ClosedSurface) : Surface
      surface = closed.surface
      return surface if closed.tab.restore(surface, closed.before, closed.after)
      reopen_tab(TabState.new(SplitTree(Surface).new(surface), surface, nil), window, nil)
      surface
    end

    private def reopen(closed : ClosedTab) : Tab
      target = closed.window.closed? ? window : closed.window
      reopen_tab(closed.state, target, closed.window.closed? ? nil : closed.position)
    end

    private def reopen(closed : ClosedWindow) : Window
      target = @app.open_window(closed.panel)
      closed.tabs.each { |state| reopen_tab(state, target, nil) }
      target.present
      target
    end

    private def reopen_tab(state : TabState, target : Window, position : Int32?) : Tab
      tab = Tab.new(@app, state.tree, state.active)
      tab.title_override = state.title_override
      target.add_tab(tab, position)
      target.present
      tab
    end

    # The latest open window, or a new one.
    private def window : Window
      @app.windows.reverse_each.find { |window| !window.closed? } || @app.open_window
    end
  end

  abstract class App
    @undo_timeout = 5.seconds
    @undo_stack : UndoStack?

    # Returns how long closed surfaces, tabs and windows can be reopened
    # with `Action::Undo`.
    getter undo_timeout : Time::Span

    # Sets how long closed surfaces, tabs and windows can be reopened with
    # `Action::Undo`; zero turns undo off.
    #
    # A surface waiting for undo is not `Surface#closed?` yet: its content
    # keeps running until the timeout passes.
    def undo_timeout=(timeout : Time::Span) : Time::Span
      @undo_timeout = timeout
      UIThread.dispatch { undo_stack.clear if timeout <= Time::Span.zero } if running?
      timeout
    end

    protected def undo_stack : UndoStack
      @undo_stack ||= UndoStack.new(self)
    end

    protected def perform(target : App, action : Action::Undo) : Bool
      undo_stack.undo
    end

    protected def perform(target : App, action : Action::Redo) : Bool
      undo_stack.redo
    end
  end
end
