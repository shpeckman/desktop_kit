# src/apprt/actions.cr
module Apprt
  abstract struct Action
    # Quits the application.
    Apprt.action Quit, "quit"

    # Opens a new window. Other processes may trigger it.
    Apprt.action NewWindow, "new-window", ipc: true

    # Closes every window.
    Apprt.action CloseAllWindows, "close-all-windows"

    # Reloads the configuration.
    Apprt.action ReloadConfig, "reload-config"

    # Brings the surface *surface_id* and its window to the front.
    Apprt.action PresentSurface, "present-surface", payload: {surface_id: UInt64}

    # Shows a desktop notification.
    Apprt.action DesktopNotification, "desktop-notification", payload: {title: String, body: String}

    # Opens *url* with the default handler; *url* may also be a file path.
    Apprt.action OpenUrl, "open-url", payload: {url: String}

    # Hides every window, or shows them all again when none is visible.
    Apprt.action ToggleVisibility, "toggle-visibility"

    # Reopens the latest closed surface, tab or window while
    # `App#undo_timeout` has not passed.
    Apprt.action Undo, "undo"

    # Closes again what `Undo` reopened last.
    Apprt.action Redo, "redo"

    # Opens the GTK inspector.
    Apprt.action ShowGtkInspector, "show-gtk-inspector"

    # Closes the window.
    Apprt.action CloseWindow, "close-window", scope: :window

    Apprt.action ToggleMaximize, "toggle-maximize", scope: :window

    Apprt.action ToggleFullscreen, "toggle-fullscreen", scope: :window

    Apprt.action ToggleWindowDecorations, "toggle-window-decorations", scope: :window

    # Shows or hides the overview of the window's tabs.
    Apprt.action ToggleTabOverview, "toggle-tab-overview", scope: :window

    # Opens the command palette of the window, or closes it when open.
    Apprt.action ToggleCommandPalette, "toggle-command-palette", scope: :window

    # Lays the key table *table* of `App#key_tables` over the window's
    # bindings. Does nothing when it is already the innermost table.
    Apprt.action ActivateKeyTable, "activate-key-table", scope: :window, payload: {table: String}

    # Lays the key table *table* over the window's bindings until one of
    # its bindings is used.
    Apprt.action ActivateKeyTableOnce, "activate-key-table-once", scope: :window, payload: {table: String}

    # Removes the innermost active key table.
    Apprt.action DeactivateKeyTable, "deactivate-key-table", scope: :window

    # Removes every active key table.
    Apprt.action DeactivateAllKeyTables, "deactivate-all-key-tables", scope: :window

    # Switches the window background between the `WindowStyle#opacity`
    # and opaque.
    Apprt.action ToggleBackgroundOpacity, "toggle-background-opacity", scope: :window

    # Gives the window its initial size again.
    Apprt.action ResetWindowSize, "reset-window-size", scope: :window

    # Focuses the previous or next window.
    Apprt.action GotoWindow, "goto-window", scope: :window, payload: {direction: Direction} do
      enum Direction
        Previous
        Next
      end
    end

    Apprt.action SetWindowTitle, "set-window-title", scope: :window, payload: {title: String}

    # Sets the window size it opens with.
    Apprt.action InitialSize, "initial-size", scope: :window, payload: {width: UInt32, height: UInt32}

    # Sets the smallest window size; 0 leaves a dimension unlimited. GTK 4
    # windows have no largest size, so *max_width* and *max_height* are
    # ignored.
    Apprt.action SizeLimit, "size-limit", scope: :window, payload: {min_width: UInt32, min_height: UInt32, max_width: UInt32, max_height: UInt32}

    # Resizes the window so that its surface gets *width* by *height* pixels.
    # Does nothing while the window is maximized or fullscreen, or shows more
    # than one surface.
    Apprt.action ResizeWindow, "resize-window", scope: :window, payload: {width: UInt32, height: UInt32}

    # Sets the appearance of the application, which applies to every window.
    Apprt.action SetWindowTheme, "set-window-theme", scope: :window, payload: {appearance: Appearance}

    # Opens a new tab in the window.
    Apprt.action NewTab, "new-tab", scope: :window

    # Focuses the tab at *index*, counted from 0, or `PREVIOUS`, `NEXT` or
    # `LAST`.
    Apprt.action GotoTab, "goto-tab", scope: :window, payload: {index: Int32} do
      PREVIOUS = -1
      NEXT     = -2
      LAST     = -3
    end

    # Closes this tab, the other tabs or the tabs to its right.
    Apprt.action CloseTab, "close-tab", scope: :tab, payload: {mode: Mode} do
      enum Mode
        This
        Other
        Right
      end
    end

    # Moves the tab by *amount* positions; negative moves it left.
    Apprt.action MoveTab, "move-tab", scope: :tab, payload: {amount: Int32}

    Apprt.action MoveTabToNewWindow, "move-tab-to-new-window", scope: :tab

    Apprt.action SetTabTitle, "set-tab-title", scope: :tab, payload: {title: String}

    # Splits the focused surface, placing the new one in *direction*.
    Apprt.action NewSplit, "new-split", scope: :split, payload: {direction: ::Apprt::Direction}

    # Focuses another split.
    Apprt.action GotoSplit, "goto-split", scope: :split, payload: {direction: Direction} do
      enum Direction
        Previous
        Next
        Left
        Right
        Up
        Down
      end
    end

    # Moves the divider of the focused split *amount* pixels in *direction*.
    Apprt.action ResizeSplit, "resize-split", scope: :split, payload: {direction: ::Apprt::Direction, amount: UInt32}

    # Gives every split of the tab the same size.
    Apprt.action EqualizeSplits, "equalize-splits", scope: :split

    # Toggles the focused split filling the tab.
    Apprt.action ToggleSplitZoom, "toggle-split-zoom", scope: :split

    # Closes the focused surface, asking first when it has
    # `Surface#confirm_close?`.
    Apprt.action CloseSurface, "close-surface", scope: :split

    # Sets the title of the focused surface.
    Apprt.action SetTitle, "set-title", scope: :split, payload: {title: String}

    # Asks the user for a new title of the surface, tab or window.
    Apprt.action PromptTitle, "prompt-title", scope: :split, payload: {kind: Kind} do
      enum Kind
        Surface
        Tab
        Window
      end
    end

    # Signals the surface's bell.
    Apprt.action RingBell, "ring-bell", scope: :split

    # Shows or hides the mouse pointer over the surface.
    Apprt.action MouseVisibility, "mouse-visibility", scope: :split, payload: {visible: Bool}

    # Copies the title of the focused surface to the clipboard.
    Apprt.action CopyTitleToClipboard, "copy-title-to-clipboard", scope: :split

    # Toggles `Surface#read_only?` of the focused surface.
    Apprt.action ToggleReadOnly, "toggle-read-only", scope: :split
  end
end
