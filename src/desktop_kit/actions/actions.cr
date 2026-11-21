# src/desktop_kit/actions/actions.cr
module DesktopKit
  abstract struct Action
    # Quits the application.
    DesktopKit.action Quit, "quit"

    # Opens a new window. Other processes may trigger it.
    DesktopKit.action NewWindow, "new-window", ipc: true

    # Closes every window.
    DesktopKit.action CloseAllWindows, "close-all-windows"

    # Reloads the configuration.
    DesktopKit.action ReloadConfig, "reload-config"

    # Brings the surface *surface_id* and its window to the front. Other
    # processes may trigger it: clicking a notification does.
    DesktopKit.action PresentSurface, "present-surface", ipc: true, payload: {surface_id: UInt64}

    # Shows a desktop notification.
    DesktopKit.action DesktopNotification, "desktop-notification", payload: {title: String, body: String}

    # Opens *url* with the default handler; *url* may also be a file path.
    DesktopKit.action OpenUrl, "open-url", payload: {url: String}

    # Hides every window, or shows them all again when none is visible.
    DesktopKit.action ToggleVisibility, "toggle-visibility"

    # Hides the panels whose `Panel#name` is *panel*, or shows them again
    # when none is visible.
    DesktopKit.action TogglePanel, "toggle-panel", ipc: true, payload: {panel: String}

    # Reopens the latest closed surface, tab or window while
    # `App#undo_timeout` has not passed.
    DesktopKit.action Undo, "undo"

    # Closes again what `Undo` reopened last.
    DesktopKit.action Redo, "redo"

    # Opens the GTK inspector.
    DesktopKit.action ShowGtkInspector, "show-gtk-inspector"

    # Closes the window.
    DesktopKit.action CloseWindow, "close-window", scope: :window

    DesktopKit.action ToggleMaximize, "toggle-maximize", scope: :window

    DesktopKit.action ToggleFullscreen, "toggle-fullscreen", scope: :window

    DesktopKit.action ToggleWindowDecorations, "toggle-window-decorations", scope: :window

    # Shows or hides the overview of the window's tabs.
    DesktopKit.action ToggleTabOverview, "toggle-tab-overview", scope: :window

    # Opens the command palette of the window, or closes it when open.
    DesktopKit.action ToggleCommandPalette, "toggle-command-palette", scope: :window

    # Shows the keyboard shortcuts of the application over the window.
    DesktopKit.action ShowShortcuts, "show-shortcuts", scope: :window

    # Lays the key table *table* of `App#key_tables` over the window's
    # bindings. Does nothing when it is already the innermost table.
    DesktopKit.action ActivateKeyTable, "activate-key-table", scope: :window, payload: {table: String}

    # Lays the key table *table* over the window's bindings until one of
    # its bindings is used.
    DesktopKit.action ActivateKeyTableOnce, "activate-key-table-once", scope: :window, payload: {table: String}

    # Removes the innermost active key table.
    DesktopKit.action DeactivateKeyTable, "deactivate-key-table", scope: :window

    # Removes every active key table.
    DesktopKit.action DeactivateAllKeyTables, "deactivate-all-key-tables", scope: :window

    # Switches the window background between the `WindowStyle#opacity`
    # and opaque.
    DesktopKit.action ToggleBackgroundOpacity, "toggle-background-opacity", scope: :window

    # Gives the window its initial size again.
    DesktopKit.action ResetWindowSize, "reset-window-size", scope: :window

    # Focuses the previous or next window.
    DesktopKit.action GotoWindow, "goto-window", scope: :window, payload: {direction: Direction} do
      enum Direction
        Previous
        Next
      end
    end

    DesktopKit.action SetWindowTitle, "set-window-title", scope: :window, payload: {title: String}

    # Sets the window size it opens with.
    DesktopKit.action InitialSize, "initial-size", scope: :window, payload: {width: UInt32, height: UInt32}

    # Sets the smallest window size; 0 leaves a dimension unlimited. GTK 4
    # windows have no largest size, so *max_width* and *max_height* are
    # ignored.
    DesktopKit.action SizeLimit, "size-limit", scope: :window, payload: {min_width: UInt32, min_height: UInt32, max_width: UInt32, max_height: UInt32}

    # Resizes the window so that its surface gets *width* by *height* pixels.
    # Does nothing while the window is maximized or fullscreen, or shows more
    # than one surface.
    DesktopKit.action ResizeWindow, "resize-window", scope: :window, payload: {width: UInt32, height: UInt32}

    # Sets the appearance of the application, which applies to every window.
    DesktopKit.action SetWindowTheme, "set-window-theme", scope: :window, payload: {appearance: Appearance}

    # Opens a new tab in the window.
    DesktopKit.action NewTab, "new-tab", scope: :window

    # Focuses the tab at *index*, counted from 0, or `PREVIOUS`, `NEXT` or
    # `LAST`.
    DesktopKit.action GotoTab, "goto-tab", scope: :window, payload: {index: Int32} do
      PREVIOUS = -1
      NEXT     = -2
      LAST     = -3
    end

    # Closes this tab, the other tabs or the tabs to its right.
    DesktopKit.action CloseTab, "close-tab", scope: :tab, payload: {mode: Mode} do
      enum Mode
        This
        Other
        Right
      end
    end

    # Moves the tab by *amount* positions; negative moves it left.
    DesktopKit.action MoveTab, "move-tab", scope: :tab, payload: {amount: Int32}

    DesktopKit.action MoveTabToNewWindow, "move-tab-to-new-window", scope: :tab

    DesktopKit.action SetTabTitle, "set-tab-title", scope: :tab, payload: {title: String}

    # Splits the focused surface, placing the new one in *direction*.
    DesktopKit.action NewSplit, "new-split", scope: :split, payload: {direction: ::DesktopKit::Direction}

    # Focuses another split.
    DesktopKit.action GotoSplit, "goto-split", scope: :split, payload: {direction: Direction} do
      enum Direction
        Previous
        Next
        Left
        Right
        Up
        Down
      end
    end

    # Swaps the focused surface with the split in *direction*: a neighbor,
    # the previous or next in order (wrapping), or the first. The surface
    # keeps the focus.
    DesktopKit.action SwapSplit, "swap-split", scope: :split, payload: {direction: Direction} do
      enum Direction
        Previous
        Next
        Left
        Right
        Up
        Down
        First
      end
    end

    # Moves the focused surface into a tab of a new window; a surface alone
    # in its tab moves with the tab.
    DesktopKit.action MoveSurfaceToNewWindow, "move-surface-to-new-window", scope: :split

    # Moves the focused surface into a new tab of the window focused before
    # this one; a surface alone in its tab moves with the tab. A window left
    # without tabs closes.
    DesktopKit.action MoveSurfaceToPreviousWindow, "move-surface-to-previous-window", scope: :split

    # Moves the divider of the focused split *amount* pixels in *direction*;
    # a floating surface grows to the right or down and shrinks to the left
    # or up instead.
    DesktopKit.action ResizeSplit, "resize-split", scope: :split, payload: {direction: ::DesktopKit::Direction, amount: UInt32}

    # Gives every split of the tab the same size.
    DesktopKit.action EqualizeSplits, "equalize-splits", scope: :split

    # Toggles the focused split filling the tab.
    DesktopKit.action ToggleSplitZoom, "toggle-split-zoom", scope: :split

    # Lifts the focused surface out of the splits to float over the tab, or
    # splits a floating surface back in beside the split under its centre.
    # A tab's only split does not float.
    DesktopKit.action ToggleFloat, "toggle-float", scope: :split

    # Moves the focused floating surface *amount* pixels in *direction*,
    # keeping it inside the tab.
    DesktopKit.action MoveFloat, "move-float", scope: :split, payload: {direction: ::DesktopKit::Direction, amount: UInt32}

    # Moves the focused surface into the stack of the split next to it in
    # *direction*, that split becoming a stack if it is none.
    DesktopKit.action StackInto, "stack-into", scope: :split, payload: {direction: ::DesktopKit::Direction}

    # Takes the focused surface out of its stack to split the stack's place
    # with it along *layout*; `Auto` takes the longer side.
    DesktopKit.action Unstack, "unstack", scope: :split, payload: {layout: Layout} do
      enum Layout
        Auto
        Horizontal
        Vertical
      end
    end

    # Shows and focuses the surface at *index* of the focused surface's
    # stack, counted from 0, or `PREVIOUS`, `NEXT` or `LAST`; previous and
    # next wrap.
    DesktopKit.action GotoStacked, "goto-stacked", scope: :split, payload: {index: Int32} do
      PREVIOUS = -1
      NEXT     = -2
      LAST     = -3
    end

    # Closes the focused surface, asking first when it has
    # `Surface#confirm_close?`.
    DesktopKit.action CloseSurface, "close-surface", scope: :split

    # Opens the focused surface's search bar.
    DesktopKit.action StartSearch, "start-search", scope: :split

    # Closes the focused surface's search bar.
    DesktopKit.action EndSearch, "end-search", scope: :split

    # Searches the focused surface for *needle*, opening its search bar.
    DesktopKit.action Search, "search", scope: :split, payload: {needle: String}

    # Selects the next or previous match of the focused surface's search.
    DesktopKit.action NavigateSearch, "navigate-search", scope: :split, payload: {direction: Direction} do
      enum Direction
        Previous
        Next
      end
    end

    # Sets the title of the focused surface.
    DesktopKit.action SetTitle, "set-title", scope: :split, payload: {title: String}

    # Asks the user for a new title of the surface, tab or window.
    DesktopKit.action PromptTitle, "prompt-title", scope: :split, payload: {kind: Kind} do
      enum Kind
        Surface
        Tab
        Window
      end
    end

    # Signals the surface's bell.
    DesktopKit.action RingBell, "ring-bell", scope: :split

    # Shows or hides the mouse pointer over the surface.
    DesktopKit.action MouseVisibility, "mouse-visibility", scope: :split, payload: {visible: Bool}

    # Copies the title of the focused surface to the clipboard.
    DesktopKit.action CopyTitleToClipboard, "copy-title-to-clipboard", scope: :split

    # Toggles `Surface#read_only?` of the focused surface.
    DesktopKit.action ToggleReadOnly, "toggle-read-only", scope: :split

    # Opens the on-screen keyboard for the focused surface.
    DesktopKit.action ShowOnScreenKeyboard, "show-on-screen-keyboard", scope: :split
  end
end
