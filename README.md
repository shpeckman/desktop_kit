# desktop_kit

Native application runtime for Crystal programs on Linux: GTK 4 and
libadwaita windows, tabs, splits and surfaces driven by typed actions, with
desktop notifications, global shortcuts, DBus IPC and systemd integration.

Status: early. This release holds the application lifecycle with command
line and file arguments, windows with tabs and splits of surfaces, menus,
file, color, font and about dialogs, an OpenGL drawing canvas (optionally
on its own thread) with keyboard, input method and pointer input, the
clipboard, actions with local and global key bindings, desktop
notifications, opening URLs, IPC, configuration reload and the GLib layer
the runtime builds on.

`examples/` holds runnable programs; `make examples` builds them into
`bin/`:

| Example        | Shows                                                                 |
|----------------|-----------------------------------------------------------------------|
| `hello.cr`     | windows, tabs and splits of text entries, bindings, a global binding, notifications, reload |
| `canvas.cr`    | an OpenGL canvas following pointer, buttons, scrolling and typed text |
| `ipc.cr`       | opens a window in a running `hello.cr`                                |
| `workspace.cr` | the card window style, pane icons, header bar content, the command palette with custom commands, key sequences, a key table |
| `snake.cr`     | a game on OpenGL canvases in split cards, steered with physical keys |
| `dialogs.cr`   | header bar buttons for confirm and prompt dialogs, toasts, notifications, opening a URL, drops |
| `panel.cr`     | a hidden drop-down panel toggled by a global binding, Escape or `panel toggle` over IPC |

## Requirements

- Crystal ≥ 1.23
- GTK ≥ 4.18, libadwaita ≥ 1.7, gtk4-layer-shell ≥ 1.0 and wayland-client
  (development packages, found with `pkg-config`)

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  desktop_kit:
    github: shpeckman/desktop_kit
```

Run `shards install`, then:

```crystal
require "desktop_kit"
```

## API

### Applications

Subclass `DesktopKit::App`, return the content of new surfaces from
`#new_surface`, override the hooks it needs and call `#run`:

```crystal
class Hello < DesktopKit::App
  protected def new_surface(context : DesktopKit::SurfaceContext) : DesktopKit::Content
    # A widget from the application's own GTK bindings.
    DesktopKit::WidgetContent.new(DesktopKit::Widget.new(LibGtk.gtk_label_new("Hello")))
  end

  protected def on_startup
    self.css = "window { background: #202020; }"
  end

  protected def on_activate
    new_window
  end

  protected def on_color_scheme(scheme : DesktopKit::ColorScheme)
    puts "now #{scheme}"
  end
end

exit Hello.new("org.example.Hello").run(ARGV)
```

`#run` drives GTK on a thread of its own and blocks the calling fiber until
`#quit` is called or the last application window closes (see
`#quit_delay=`); it returns the exit status. One application runs at a time. The application id must be a
valid reverse-DNS name (`ArgumentError` otherwise). With
`single_instance: true`, the default, launching the program again
hands its arguments to the running instance and exits with the status
that instance returns.

With `App#restore_session = true` the application saves its windows, tabs,
splits, their ratios and title overrides when it quits or its last window
closes, to `$XDG_STATE_HOME/<app id>/session.json`, and reopens them on its
first activation instead of calling `#on_activate`. Each surface saves what
its content's `Content#session_state` returns, and `#new_surface` receives
it back as `SurfaceContext#session_state`. Panels are not saved; a missing
or unreadable session activates as usual.

Hooks, all called on the GTK thread:

| Hook                       | Called                                              |
|----------------------------|-----------------------------------------------------|
| `on_startup`               | once GTK is initialized                             |
| `on_command_line(command_line)` | on each launch, with the arguments given to `#run`; returns the exit status |
| `on_open(files)`           | with files to open, from `on_command_line` or the desktop |
| `on_activate`              | at a launch without files, and on each such relaunch of a single instance |
| `on_color_scheme(scheme)`  | after `on_startup`, then whenever light/dark changes |
| `on_reload`                | on `#reload` and SIGUSR2                            |
| `on_binding_failed(binding, message)` | when the desktop does not bind a global binding |
| `on_window(window)`        | with each new window, before it is shown            |
| `on_window_suspended(window, suspended)` | when the desktop stops or resumes showing a window (another workspace, minimized) |
| `on_user_idle(idle)`       | when the user turns idle after `#idle_timeout`, and when they return |
| `on_shutdown`              | when quitting, while the windows still exist        |

`on_command_line` receives an `DesktopKit::CommandLine`: `#arguments` (without
the program name), `#directory` (the launching process's working
directory) and `#remote?` (launched by another process). `#path(argument)`
resolves a file argument against `#directory`, or from a `file://` URI. By
default the hook calls `on_open` with the arguments as files, or
`on_activate` when there are none, and returns 0; `on_open` calls
`on_activate`. Override `on_command_line` to parse options:

```crystal
protected def on_command_line(command_line : DesktopKit::CommandLine) : Int32
  if command_line.arguments.first? == "--version"
    puts "1.0"
    return 0
  end
  super
end
```

These methods are callable from any thread:

- `#post { ... }` runs the block on the GTK thread at the next main loop
  iteration, in posting order. Blocks posted before `#run` run once the
  application is active; blocks still queued when it quits are dropped.
- `#quit` closes the application windows and quits at the next main loop
  iteration, so the windows outlive the hook or handler that calls it.
  `#reload` calls `on_reload`, then `Content#on_reload` of every surface's
  content. Both do nothing unless `#running?`.
- `#css=` sets the application style sheet, applied above the theme;
  parse errors are logged as warnings.
- `#window_style=` sets the look of all windows (see Window style).
- `#undo_timeout=` sets how long `Undo` can reopen closed surfaces, tabs
  and windows; 5 seconds by default, zero turns undo off.
- `#quit_delay=` sets how long the application keeps running after its
  last window closes: zero, the default, quits right away; a window that
  opens in time keeps it running; `nil` runs until `#quit`.
- `#config_errors=` shows a list of configuration errors in a dialog that
  offers to reload or to ignore them; an empty list closes it. Errors set
  before `#run` show once the application is active.
- `#bell=`, `#bell_sound=` and `#bell_volume=` set what a ringing bell
  does (see Bell).
- `#appearance=` requests `DesktopKit::Appearance::System` (follow the desktop,
  the default), `Light` or `Dark`.
- `#idle_timeout=` sets how long the user may leave the keyboard and
  pointer alone before `on_user_idle(true)`; `nil`, the default, reports
  nothing. The desktop decides (and may never tell); `#user_idle?` holds
  the last report.

On the GTK thread, two methods hook into its main loop and return an
`DesktopKit::Source`, which `#cancel` stops; quitting cancels every source:

- `#after(delay) { ... }` runs the block once *delay* passed.
- `#watch(fd, conditions = :read) { |condition| ... }` calls the block
  whenever the file descriptor (an `Int32` or an `IO::FileDescriptor`)
  meets one of `Source::Condition` `Read`, `Priority` or `Write`. `Error`,
  `HangUp` and `Invalid` are reported regardless; `Invalid` (a closed
  descriptor) ends the watch. Read and write the descriptor without
  blocking: the GTK thread runs the whole application.

```crystal
blink = app.after(500.milliseconds) { toggle_cursor }
reader = app.watch(pty) { |condition| drain(pty) if condition.read? }
# later
reader.cancel
```

While `#run` runs, SIGINT and SIGTERM quit the application and SIGUSR2
reloads it; the signals return to their default action afterwards.

### Windows, tabs and surfaces

A window holds tabs; a tab holds one or more surfaces laid out in splits.
A surface shows a `DesktopKit::Content`, which `#new_surface` creates: return
an `DesktopKit::WidgetContent` to show a widget, or a subclass of `Content`.
Each call must return a new content; `Content#surface` is the surface
showing it. The `DesktopKit::SurfaceContext` tells where the surface opens:
`kind` is `Window`, `Tab`, `Split` or `Restore` (a saved session reopens),
`parent` is the surface it opens from, if any, and `session_state` is what
the saved surface's content returned from `Content#session_state`.

The window, tab and surface methods run on the GTK thread only: in hooks,
in `perform`, or in `#post` blocks. `App#new_window` raises `RuntimeError`
elsewhere.

| Method                           | Does                                                              |
|----------------------------------|-------------------------------------------------------------------|
| `App#new_window(parent = nil)`   | opens and presents a window with one tab and returns it           |
| `App#windows`                    | the open windows, oldest first                                    |
| `App#active_window`              | the window focused last                                           |
| `App#active_surface`             | the focused surface of `#active_window`                           |
| `App#surface(id)`                | the open surface with `Surface#id`                                |
| `Window#new_tab`                 | opens a tab after the selected one and selects it                 |
| `Window#tabs`, `#active_tab`     | the tabs in tab bar order, the selected tab                       |
| `Window#active_surface`          | the focused surface of the selected tab                           |
| `Window#present`, `#close`       | brings the window to the front, closes it                         |
| `Tab#surfaces`                   | the surfaces from left or top to right or bottom                  |
| `Tab#active_surface`, `#zoomed?` | the focused surface, whether one surface fills the tab            |
| `Tab#window`, `#close`           | the window showing the tab, closes it                             |
| `Surface#split(direction)`       | opens a surface beside it, in an `DesktopKit::Direction`, and focuses it |
| `Surface#focus`, `#close`        | focuses the surface and selects its tab, closes it                |
| `Surface#present`                | focuses the surface and raises its window (`PresentSurface`)      |
| `Surface#tab`, `#window`, `#id`  | where it is shown, its identifier, unique in the process          |
| `Surface#focused?`               | whether it holds its window's keyboard focus                      |
| `Surface#cursor=`                | sets the pointer by CSS name (`"text"`, `"pointer"`); `nil` resets |
| `Surface#mouse_visible=`         | shows or hides the pointer over it (`MouseVisibility`)            |
| `Surface#ring_bell`              | rings its bell (`RingBell`, see Bell)                             |
| `Surface#show_banner(message, button) { }` | shows a bar with *message* over the bottom of its pane, and a button running the block; `#hide_banner` removes it |
| `Surface#confirm_clipboard(request, text) { \|allowed\| }` | asks the user to allow a clipboard `Paste`, `Read` or `Write` of *text* |
| `Surface#show_on_screen_keyboard` | asks the input method to show the on-screen keyboard of a `Canvas` (`ShowOnScreenKeyboard`); returns whether it did |
| `Window#toast(message, timeout)` | shows a message at the bottom of the window, 3 seconds by default |
| `Window#decoration=`             | `DesktopKit::Decoration`: `Auto`, `Client`, `Server` or `None`         |
| `Window#background_blur=`        | blurs what lies behind the window's transparent parts             |
| `Window#urgent=`, `#active?`     | asks for the user's attention while inactive, whether it is active |
| `Window#confirm(heading, body)`  | asks a yes/no question in a dialog and yields the answer          |
| `Window#prompt(heading, body)`   | asks for a line of text in a dialog and yields it                 |
| `Window#open_file`, `#open_files`, `#save_file`, `#choose_folder` | asks for files or a folder in a file dialog and yields the paths (see Dialogs) |
| `Window#choose_color`, `#choose_font` | asks for a color or a font and yields it                     |
| `Window#show_about(about)`       | shows the application's about dialog                              |
| `Window#subtitle=`               | sets a second line under the window title; `nil` removes it       |
| `Window#fullscreen=`, `#fullscreen?`, `#maximized=`, `#maximized?` | asks the desktop to (un)fullscreen or (un)maximize it, and its state |
| `Window#resizable=`              | whether the user can resize it; a fixed window keeps its content's size |
| `Window#app_id=`                 | the application id the desktop groups it under (icon, window rules); `nil` uses the application's |
| `Window#idle_inhibited=`, `#set_idle_inhibited(on, reason)` | keeps the desktop from blanking or locking while it is open |
| `Window#shortcuts_inhibited=`    | lets the desktop's own shortcuts reach it while focused; the desktop may ask or refuse |
| `Window#activate(token)`         | raises and focuses it with an activation token from another application |
| `Window#monitor_size`            | the logical size of its monitor, `nil` while not shown            |
| `Window#suspended?`              | whether the desktop stopped showing it (`on_window_suspended`)    |
| `Window#pack_start`, `#pack_end` | adds a widget, or a button with an `DesktopKit::Icon` performing an action, to the header bar |
| `Surface#icon=`                  | sets an `DesktopKit::Icon` for its pane header and, while active, its tab; `nil` removes it |
| `Surface#read_only=`             | marks it read-only with a lock badge (`ToggleReadOnly`); the content reads `#read_only?` and decides what to refuse |
| `Window#key_tables`              | the names of its active key tables, innermost last                |
| `Surface#progress=`              | shows an `DesktopKit::Progress` on its pane, tab and the taskbar; `nil` hides it |
| `Surface#hover_text=`            | shows text, such as a hovered link's target, at the bottom of its pane; `nil` hides it |
| `Surface#show_size(text)`        | shows *text*, such as the new size after a resize, in the middle of its pane for a moment |
| `Surface#start_search(needle)`, `#end_search`, `#search_active?` | opens and closes its search bar (`StartSearch`, `Search(needle)`, `EndSearch`) |
| `Surface#search_total=`, `#search_selected=` | the match count and the current match (from 0) the search bar shows |

A window has a header bar with a new tab button, a tab overview button and
a menu, `App#window_menu` (see Menus); the tab bar shows
while there is more than one tab. Closing the last surface of a tab closes
the tab, and closing the last tab closes the window. Once closed,
`#closed?` is true, `Window#new_tab` and `Surface#split` raise
`RuntimeError`, and the objects leave the registries.

`Undo` reopens the latest closed surface, tab or window within
`App#undo_timeout`: a surface returns to its place in the split tree when
the tab has not changed since, and next to the active surface otherwise;
a tab returns to its position, a window with all its tabs. The content is
the same object, so its state survives; it is released, and `#closed?`
becomes true, only once the timeout passes. `Redo` closes what `Undo`
reopened last.

`DesktopKit::Progress.new(value, state)` describes a long task: *value* from 0
to 1, or `nil` for an indeterminate bar, and `state` `Normal`, `Error` or
`Paused`. `Surface#progress=` shows it as a bar at the top of the pane and
a loading indicator on the tab, and sends the mean of all surfaces'
progress to the taskbar through `com.canonical.Unity.LauncherEntry`,
which KDE Plasma and Ubuntu's dock read for the desktop file named after
the application id.

#### Dialogs

The file, color and font dialogs show over the window; inside a sandbox
the desktop portal shows them. Each yields its result to the block on the
GTK thread, `nil` (or no paths) when the user cancels, and never when the
window closed first. Keyword arguments, all optional:

| Method           | Arguments                                   | Yields         |
|------------------|---------------------------------------------|----------------|
| `#open_file`     | `title`, `folder`, `filters`                | `Path?`        |
| `#open_files`    | `title`, `folder`, `filters`                | `Array(Path)`  |
| `#save_file`     | `title`, `folder`, `name`, `filters`        | `Path?`        |
| `#choose_folder` | `title`, `folder`                           | `Path?`        |
| `#choose_color`  | `title`, `color`, `alpha` (default `true`)  | `DesktopKit::Color?` |
| `#choose_font`   | `title`, `font`                             | `String?`      |

`DesktopKit::FileFilter.new(name, patterns, mime_types)` lists files matching
any glob or MIME type under *name*. `DesktopKit::Color` holds `red`, `green`,
`blue` and `alpha` from 0.0 to 1.0. Fonts are Pango descriptions such as
`"Monospace Bold 12"`. The save dialog asks before replacing a file.

```crystal
window.open_file(filters: [DesktopKit::FileFilter.new("Images", mime_types: ["image/*"])]) do |path|
  viewer.load(path) if path
end
window.show_about(DesktopKit::About.new("Viewer", version: "1.0",
  developers: ["Ann <ann@example.org>"], website: "https://example.org", license: :gpl30))
```

`DesktopKit::About` takes the application `name` and optionally `version`,
`icon` (an icon name), `developer`, `developers`, `comments`, `website`,
`issue_url`, `copyright` and `license` (`About::License`).

#### Menus

An `DesktopKit::Menu` holds sections of items; each item has a label and
either an action to perform or a submenu. `Menu.build` fills one;
`#section` starts a new section below a separator:

```crystal
app.window_menu = DesktopKit::Menu.build do |menu|
  menu.item "New Window", DesktopKit::Action::NewWindow.new
  menu.section
  menu.submenu "Split" do |split|
    split.item "Right", DesktopKit::Action::NewSplit.new(:right)
    split.item "Down", DesktopKit::Action::NewSplit.new(:down)
  end
  menu.item "Settings", OpenSettings.new
end
```

`App#window_menu=` replaces the header menu of every window, open ones
too; `Menu.window`, the default, holds the window, tab, split, title and
close actions and the keyboard shortcuts. A content's context menu comes from its
`Content#context_menu(x, y)` hook, called on a right click at *x*, *y*
(logical pixels from its top left): return a menu to show it there, or
`nil`, the default, to pass the click on. The surface is focused first,
so tab and split actions act on it.

#### Window style

`App#window_style=` takes an `DesktopKit::WindowStyle`; the defaults give GTK's
plain look, with the header bar on and the other options off:

| Option              | Effect                                                         |
|---------------------|----------------------------------------------------------------|
| `pane_headers`      | a header over each surface: its icon, its title and buttons to split right, split down, zoom and close it |
| `cards`             | surfaces as rounded cards with gaps between them               |
| `tabs_in_header`    | the tab bar in the header bar, beside the window title, always shown |
| `header_bar`        | the header bar with the title, the tabs and their buttons; `false` leaves windows without a title bar of their own and passes libadwaita's tab keys (Ctrl+Tab, Ctrl+Page Up, Alt+1 …) to the content |
| `opacity`           | opacity of the window background, 0 to 1; pair it with `Window#background_blur=` |
| `unfocused_opacity` | opacity of the surfaces of a split other than the tab's active one, 0 to 1 |

The style applies to open windows at once. `on_window` adds header bar
content to each new window:

```crystal
class Hello < DesktopKit::App
  protected def on_startup : Nil
    self.window_style = DesktopKit::WindowStyle.new(
      pane_headers: true, cards: true, tabs_in_header: true,
      opacity: 0.85, unfocused_opacity: 0.7)
  end

  protected def on_window(window : DesktopKit::Window) : Nil
    window.subtitle = System.hostname
    window.pack_end(DesktopKit::Action::ToggleCommandPalette.new, "system-search-symbolic", "Commands")
    window.background_blur = true
  end
end
```

The surface widget carries the CSS class `surface`, plus `active` on each
tab's active surface; the pane header is `.surface-header`. Windows carry
`desktop-kit-window`. `App#css=` can restyle them.

Closing asks the user first when a surface it closes has
`Surface#confirm_close = true`: a split, a tab, a window, all windows or
the application. `App#quit` never asks. While any surface asks, the
application also asks the desktop not to log out; `App#logout_inhibited?`
tells whether it does.

`Window#confirm` and `Window#prompt` ask the user something in a dialog
over the window. Their block runs once, after the answer; `#prompt` skips
it when the user cancels, and neither runs it when the window closes
first. Both take `confirm:` and `cancel:` button labels; `destructive: true`
shows the confirm button in red and makes cancel the default; `text:` is
the prompt's initial text.

```crystal
window.confirm("Discard Changes?", "The draft will be lost.", confirm: "Discard", destructive: true) do |discard|
  draft.clear if discard
end
window.prompt("Rename Session", text: session.name) { |name| session.name = name }
```

An `DesktopKit::Icon` is a themed icon name (`String`, such as
`"utilities-terminal"`) or the `Path` of an image file:

```crystal
surface.icon = Path["/usr/share/pixmaps/editor.png"]
window.pack_start(OpenSettings.new, "emblem-system-symbolic", "Settings")
```

#### Panels

`App#new_panel` opens a window that the desktop docks to a screen edge,
shows as the wallpaper or floats above other windows, like kitty's panel
kitten: a quick terminal, a status bar, a desktop widget. Panels have tabs
and splits like other windows, but no header bar or decorations. They need
a Wayland compositor with the wlr layer shell protocol, such as sway, KDE
Plasma, Hyprland or niri; GNOME has none, and `App#panels?` is then false.

```crystal
quick = DesktopKit::Panel.new(edge: :top, height: 400, layer: :overlay,
  focus: :on_demand, hide_on_focus_loss: true, name: "quick")
app.new_panel(quick, shown: false)
app.bindings = [DesktopKit::Binding.new("super+grave", DesktopKit::Action::TogglePanel.new("quick"), global: true)]
```

`DesktopKit::IPC.send(app_id, DesktopKit::Action::TogglePanel.new("quick"))` toggles it
from another process. `Window#panel=` moves and resizes an open panel;
`Window#panel` is `nil` for ordinary windows. `App#outputs` lists the
monitors' names for `output`.

| `Panel` field        | default         | meaning                                                                                       |
|----------------------|-----------------|-----------------------------------------------------------------------------------------------|
| `edge`               | `:top`          | where it sits; see below                                                                      |
| `layer`              | `:bottom`       | `:background`, `:bottom`, `:top` or `:overlay`, from the bottom up; `edge: :background` forces `:background` |
| `width`, `height`    | `0`             | logical pixels; 0 takes the content's natural size, which is also the minimum                   |
| `margin_top`, `margin_right`, `margin_bottom`, `margin_left` | `0` | logical pixels, on the edges the panel touches only                      |
| `output`             | `nil`           | monitor name, such as `"DP-1"`; `nil` lets the compositor choose                              |
| `focus`              | `:not_allowed`  | keyboard focus: `:not_allowed`, `:exclusive` (always, as the desktop permits) or `:on_demand` (on click) |
| `exclusive_zone`     | `nil`           | pixels other windows and panels keep clear of; see below                                      |
| `hide_on_focus_loss` | `false`         | hides the panel when it loses the focus; implies `focus: :on_demand`                         |
| `name`               | `"desktop-kit-panel"` | layer namespace, for `TogglePanel` and compositor rules                                       |

| `edge`          | placement                                   | size from         |
|-----------------|---------------------------------------------|-------------------|
| `:top`, `:bottom` | along the edge, full width                | `height`          |
| `:left`, `:right` | along the edge, full height               | `width`           |
| `:background`   | whole monitor, below every window           | —                 |
| `:center`       | whole monitor less the margins              | —                 |
| `:center_sized` | centered; margins have no effect            | `width`, `height` |
| `:none`         | top left corner, offset by the top and left margins | `width`, `height` |

An edge panel reserves its own thickness by default, so maximized windows
and other panels stay clear of it; other panels take `-1` by default and
cover what others reserve. An explicit `exclusive_zone` overrides both
(not for `:background`): `0` reserves nothing but stays clear of others'
zones, `-1` covers them. `Window#shortcuts_inhibited=` lets a focused
panel take the desktop's own shortcuts, like kitty's `--grab-keyboard`.

#### Preferences

`DesktopKit::Preferences` builds a preferences dialog from pages of groups of
rows. Each row edits one value and passes every change to its block:

| Row                                                        | Value   | Edits it with           |
|------------------------------------------------------------|---------|-------------------------|
| `switch(title, subtitle:, value:)`                         | `Bool`  | a switch                |
| `entry(title, value:)`                                     | `String`| a text entry            |
| `spin(title, subtitle:, value:, range:, step:, digits:)`   | `Float64` | a spin button, `step` 1 and `digits` 0 by default |
| `choice(title, options, subtitle:, selected:)`             | `Int32` | a drop-down of `options`, the index of the chosen one |

`Preferences#page(title, icon:)` and `Page#group(title, description:)`
yield the page or group to fill. `#present(window)` shows the dialog over
*window* (on the GTK thread), closing an earlier one; the rows keep their
values, so the dialog shows the latest ones when presented again.
`#close` closes it and `#open?` tells whether it is shown. `choice` raises
`ArgumentError` without options and `IndexError` when `selected` lies
outside them.

```crystal
prefs = DesktopKit::Preferences.new("Preferences")
prefs.page("General", icon: "preferences-system-symbolic") do |page|
  page.group("Appearance", description: "How windows look") do |group|
    group.switch("Pane headers", value: true) { |on| app.window_style = DesktopKit::WindowStyle.new(pane_headers: on) }
    group.spin("Opacity", value: 1.0, range: 0.2..1.0, step: 0.05, digits: 2) { |value| settings.opacity = value }
    group.choice("Colours", ["System", "Light", "Dark"]) { |index| settings.scheme = index }
  end
  page.group("Session") do |group|
    group.entry("Name", value: settings.name) { |name| settings.name = name }
  end
end
prefs.present(window)
```

`ToggleCommandPalette` opens a search over the application's commands,
`App#commands`, with the shortcut of each; Enter or a click performs the
selected one on the window, Up and Down move the selection and Escape
closes it. An `DesktopKit::Command` has a `title`, an `action` and an optional
`description` that the search also matches. `DesktopKit::Command.defaults`
lists the built-in actions that need no input, and is the set until
`App#commands=` replaces it:

```crystal
app.commands = DesktopKit::Command.defaults + [
  DesktopKit::Command.new("Open Settings", OpenSettings.new, "preferences"),
]
```

Titles: a surface has a `#title`, set by the application, and a
`#title_override`, set by the user through `PromptTitle`. A tab shows its
`#title_override`, else the title of its focused surface, else the
application name, marked with 🔍 while zoomed and with 🔔 while one of its
surfaces rings. A window shows its
`#title_override`, else the title of its selected tab. Assigning `nil` to
an override restores the default.

Window extras work on Wayland and do nothing elsewhere. `Decoration::Auto`
uses the compositor's preference where it tells one (KDE's server
decoration protocol), else client-side decorations; `Server` falls back to
`Client` without that protocol, and `None` hides them.
`ToggleWindowDecorations` switches between `None` and the previous choice.
Blur needs a compositor with `ext-background-effect-v1`; the region follows
the window's rounded corners. Urgency uses `xdg-activation-v1`: a ringing
bell in an inactive window makes it urgent, and activating the window
clears it.

Drag and drop: hovering a split shows a handle at its top; dragging it, or
the pane header, onto another surface, in any tab or window, moves it there, beside the edge
nearest to the pointer. Files and text dropped on a surface go to
`Content#on_drop`:

```crystal
class Editor < DesktopKit::WidgetContent
  protected def on_drop(files : Array(Path)) : Bool
    files.each { |file| open_file(file) }
    true
  end

  protected def on_drop(text : String) : Bool
    insert(text)
    true
  end
end
```

Search: the search bar sits in a corner of the pane (top right at first;
dragging it moves it to the nearest corner) with an entry, the match count,
previous and next buttons and a close button. Return selects the next
match, Shift+Return the previous one, Escape closes it. The content does
the searching:

```crystal
class Editor < DesktopKit::WidgetContent
  protected def on_search(needle : String) : Nil
    @matches = find_all(needle)
    surface.search_total = needle.empty? ? nil : @matches.size
    surface.search_selected = @matches.empty? ? nil : 0
  end

  protected def on_search_navigate(forward : Bool) : Nil
    select_match(forward ? 1 : -1)
  end

  protected def on_search_end : Nil
    clear_highlights
  end
end
```

#### Bell

`Surface#ring_bell` does what the `DesktopKit::Bell` flags in `App#bell` say;
the default is `System | Attention | Title`:

| Flag        | Effect                                                            |
|-------------|-------------------------------------------------------------------|
| `System`    | beeps through the display server                                  |
| `Audio`     | plays `App#bell_sound` at `App#bell_volume` (0 to 1, 0.5 by default) |
| `Attention` | the tab needs attention while not selected; an inactive window turns urgent |
| `Title`     | marks the tab title with 🔔                                       |
| `Border`    | draws a border around the surface                                 |

Ringing an unfocused surface sets `Surface#bell_ringing?` and its marks
until it gets the focus; a focused surface only beeps and plays the sound.
A sound file that cannot play is logged as a warning.

### Canvas

`DesktopKit::Canvas` is a `Content` that draws with OpenGL. Subclass it,
implement `#on_render` and override the input hooks you need; each
`#new_surface` call returns a new canvas.

```crystal
class Scene < DesktopKit::Canvas
  def initialize
    super(api: :gl, version: {3, 3})
  end

  protected def on_render : Nil
    # draw into the bound framebuffer: width × height pixels
  end

  protected def on_key(event : DesktopKit::KeyEvent) : Bool
    return false unless event.pressed?
    puts event.text || event.keyval
    queue_render
    true
  end
end
```

`.new(*, api, version, depth_buffer, stencil_buffer, input_purpose, offload, threaded)` sets
the GL context and framebuffer: `api` is `Canvas::API::GL`, `GLES` or both
(the default), `version` the least `{major, minor}`, and the framebuffer
gets a 24-bit depth and 8-bit stencil buffer when either is asked for. `input_purpose`
(`Canvas::InputPurpose`, `FreeForm` by default; `Terminal` for keys that
go to a program) tells input methods and on-screen keyboards what text
the canvas takes. The GL context is current in `#on_realize`,
`#on_render`, `#on_resize` and `#on_unrealize`; `#api` is the flavour
GTK made, and `#error` the reason when it made none. Moving a canvas, such
as into a split, unrealizes and realizes it again, so `#on_realize` must
recreate GL objects. The canvas draws a frame when it is shown, resized
or rescaled, and after `#queue_render`; call that after a change.

`offload: true` hands frames to GTK as DMA-BUFs where the GL driver can
export them (EGL with `EGL_MESA_image_dma_buf_export`, as on Mesa), and
puts the frame in a `GtkGraphicsOffload`, so the compositor may show it
on a subsurface without GTK copying it. Elsewhere, or when GTK refuses the
buffer's format, frames go as GL textures, as without the option.
`#dmabuf?` tells whether the last frame went as a DMA-BUF.

`threaded: true` draws on a thread of the canvas's own, so a slow frame
never stalls the GTK thread: `#on_realize`, `#on_resize`, `#on_render` and
`#on_unrealize` run there and must not call GTK; `#queue_render` may be
called from either thread, and `#threaded?` tells the mode. The thread
draws one frame at a time; GTK keeps showing the previous frame until it
finishes. Share state between the hooks and the input hooks (still on
the GTK thread) under a lock, or hand it over with `App#post` and a
`Channel`.

Each frame goes to a framebuffer of exactly the canvas's size at the
output's scale, fractional scales included (`#scale` is a `Float64` such
as `1.5`), with the GL origin at the bottom left. The canvas keeps several
framebuffers: `#buffer_age` tells, during `#on_render`, how many frames
ago the bound one was last drawn, or 0 when its contents are undefined, so
a canvas can redraw only what changed since then. `#frame` numbers the
frame drawn last, and `#on_presented(timing)` reports when the display
showed a frame: an `DesktopKit::FrameTiming` with `frame`, `presented` (a
`Time::Span` on `CLOCK_MONOTONIC`) and `refresh_interval`, both `nil` when
the compositor does not tell.

`DesktopKit::GLContext.new(api:, version:)` makes a context for drawing off
screen, for example into textures, with no canvas; it shares objects with
every canvas of the display. `#make_current`, `#current?`, `#api` and
`GLContext.clear_current` manage it; `Canvas#gl_context` is a canvas's
own, `nil` while it is unrealized. Make contexts on the GTK thread; a
context is current on one thread at a time.

| Hook                               | Called                                                                 |
|------------------------------------|------------------------------------------------------------------------|
| `on_realize`, `on_unrealize`       | after the GL context is made, before it goes                           |
| `on_render`                        | to draw a frame                                                        |
| `on_resize(width, height)`         | when the framebuffer size changes                                      |
| `on_presented(timing)`             | when the display showed a frame                                        |
| `on_key(event) : Bool`             | for a key press or release; true when used, else GTK passes the key on |
| `on_preedit(text)`, `on_commit(text)` | input method composition text (`nil` ends it), finished text        |
| `on_focus(focused)`                | when the canvas gains or loses the keyboard focus                      |
| `on_mouse_button(event)`           | for a button press or release; a press focuses the canvas              |
| `on_mouse_enter(event)`, `on_mouse_motion(event)`, `on_mouse_leave` | when the pointer enters the canvas, while it moves over it, when it leaves |
| `on_scroll(event)`                 | for a wheel step or a touchpad scroll                                  |

Sizes and positions are framebuffer pixels: `#width`, `#height`, event
coordinates and precise scroll deltas are logical units times `#scale`.
Call `#ime_cursor(x, y, width, height)` with the text cursor's rectangle
in framebuffer pixels so the input method places its popup there.

`DesktopKit::KeyEvent` holds `pressed?`, `repeat?` (a press of a key already
down, as keyboard repeat sends), `keyval` (a GDK keysym), `keycode`,
`key` (the physical key, an `DesktopKit::Key`), `layout` (the index of the
keyboard layout in use),
`mods` (the modifiers held, counting a modifier key in its own press but
not in its release), `consumed_mods` (the modifiers the layout used to
make the key), `text` (what a press types, `nil` for a release or a
non-text key), `unshifted` and `shifted` (the characters of the key
without modifiers and with Shift alone), `base` (its character without
modifiers in the first layout, for bindings across layouts),
`caps_lock?`, `num_lock?`, `modifier?` and `composing?` (the input method
is composing). A key the
input method uses for a composition reaches `#on_key` with
`composing? = true`; text it finishes comes through `#on_commit`, or as
the event's `text` when one key finishes it. Using a key while composing
ends the composition. `DesktopKit::MouseButtonEvent` holds `pressed?`,
`button` (`Left`, `Middle`, `Right`, `Back`, `Forward`; other buttons keep
their number), `x`, `y`, `mods` and `time` (milliseconds of the display's
clock, for double clicks); `DesktopKit::MouseMotionEvent` holds `x`, `y`, `mods`
and `time`;
`DesktopKit::ScrollEvent` holds `dx`, `dy`, `precise?` (pixel deltas from a
touchpad rather than wheel steps) and `mods`.

#### Canvas drag and drop

A canvas can take drags by MIME type and start its own. These hooks come
on top of `Content#on_drop`, which still gets the drags the canvas
refuses:

| Hook                                       | Called                                                          |
|--------------------------------------------|-----------------------------------------------------------------|
| `on_drop_accept(drop) : Bool`              | when a drag enters; true takes part in it (default false)       |
| `on_drop_motion(drop, x, y) : DragAction`  | as it enters and moves; the action a drop there would perform (default `Copy` when allowed) |
| `on_drop_leave(drop)`                      | when it leaves without dropping                                 |
| `on_drop(drop, x, y) : Bool`               | when it drops; true takes the drop (default false)              |
| `on_drag_end(drag, action)`                | when a drag from `#drag` ends; `None` when cancelled            |

An `DesktopKit::Drop` offers `mime_types`, `actions` (the `DesktopKit::DragAction`
flags `Copy`, `Move`, `Link` its source allows) and `local?` (a drag from
this application). Once `on_drop` returned true, `read(mime_type)
{ |bytes| }` fetches the data (`nil` when it is not offered) and
`finish(action)` ends the drop, `DragAction::None` reporting a failure.

`#drag(mime_types, actions = :copy, icon = nil) { |request| }` starts a
drag with the pointer; call it while a button is held. It returns the
`DesktopKit::Drag` (its `mime_types` and the `action` the target under the
pointer would perform), or `nil` while the canvas is not on screen. The
data is produced on demand: the block gets an `DesktopKit::Drag::Request` for
each MIME type a target asks for and answers it once with
`reply(bytes)` or `fail`, now or later. An `DesktopKit::Drag::Icon` holds
straight RGBA pixels and the pointer's spot on them.

```crystal
protected def on_drop_accept(drop : DesktopKit::Drop) : Bool
  drop.mime_types.includes?("text/uri-list")
end

protected def on_drop(drop : DesktopKit::Drop, x : Float64, y : Float64) : Bool
  drop.read("text/uri-list") do |bytes|
    open_uris(String.new(bytes)) if bytes
    drop.finish(bytes ? DesktopKit::DragAction::Copy : DesktopKit::DragAction::None)
  end
  true
end

protected def on_mouse_motion(event : DesktopKit::MouseMotionEvent) : Nil
  return unless @pressed_on_link
  drag(["text/uri-list", "text/plain;charset=utf-8"]) { |request| request.reply(@link.to_slice) }
  @pressed_on_link = false
end
```

`DesktopKit::Key` names a key by its position on a US keyboard, whatever the
layout, with the W3C UI Events `code` names: `KeyA` is the key right of
Caps Lock even where it types `q`. Use it for bindings that follow the
keyboard's shape, such as WASD movement; `keyval` and `text` follow the
layout. Keys the table does not know are `Unidentified`.

```crystal
protected def on_key(event : DesktopKit::KeyEvent) : Bool
  case event.key
  when .key_w? then move(:up)
  when .key_s? then move(:down)
  else              return false
  end
  true
end
```

### Clipboard

`DesktopKit::Clipboard.write(text, kind = :standard)` puts text on a
clipboard; `.read(kind = :standard) { |text| }` yields its text later, or
`nil` when it holds none. `kind` is `Standard` (copy and paste) or
`Primary` (the selection, pasted by middle-click). Use them on the GTK
thread only.

Other data travels by MIME type:

- `.write(items, kind = :standard)` puts `{mime_type, bytes}` pairs on a
  clipboard; each reader picks the type it wants. Empty *items* clear it.
- `.offered(kind = :standard)` returns the MIME types a clipboard offers.
- `.read(mime_type, kind = :standard) { |bytes| }` yields the data of one
  type later, or `nil` when the clipboard does not offer it.
- `.items(kind = :standard)` returns the items this application last
  wrote, while it still owns the clipboard; `nil` otherwise.

```crystal
DesktopKit::Clipboard.write([{"text/html", html.to_slice}, {"text/plain;charset=utf-8", text.to_slice}])
if DesktopKit::Clipboard.offered.includes?("text/html")
  DesktopKit::Clipboard.read("text/html") { |bytes| paste(bytes) if bytes }
end
```

`Surface#confirm_clipboard(request, text) { |allowed| }` asks before a
clipboard access: `Clipboard::Request::Paste` warns about pasting *text*,
`Read` and `Write` ask to let the content read or write the clipboard, and
show *text*. The block gets `true` when the user allows it, and `false`
right away for a closed surface.

### Notifications

`Surface#notify(title, body)` shows a desktop notification; clicking it
presents the surface. `App#notify(title, body)` shows one from the
application, which clicking does not act on. An empty *title* shows the
application name. Sending the same title and body again replaces the
notification instead of adding one. A surface withdraws its notifications
once it gets the focus or closes, and one sent while it is focused after a
few seconds. Use them on the GTK thread only; GIO hands them to the
desktop's notification service.

### Actions

Everything the runtime does on request is an action: a typed value that
menus, buttons, key bindings and other processes trigger through GTK's
action system. `DesktopKit::App#perform` carries actions out, with one overload
per action type. Its *target* is the `DesktopKit::App` for `app` actions, the
`DesktopKit::Window` for `window` actions, the `DesktopKit::Tab` for `tab` actions
and the `DesktopKit::Surface` for `split` actions; a window triggers its tab and
split actions on its selected tab and that tab's focused surface.

Declare an action with `DesktopKit.action`; the payload becomes the struct's
constructor arguments and getters:

```crystal
DesktopKit.action Refresh, "refresh", payload: {force: Bool}

DesktopKit.action Zoom, "zoom", scope: :split, payload: {step: Step} do
  enum Step
    In
    Out
  end
end

class Viewer < DesktopKit::App
  protected def perform(target : DesktopKit::App, action : Refresh) : Bool
    puts "refreshing, force: #{action.force}"
    true
  end
end
```

| Option     | Meaning                                                              |
|------------|----------------------------------------------------------------------|
| *name*     | the struct, here `Refresh`                                           |
| *gname*    | the action name: letters, digits, `-` and `.`, unique per scope      |
| `scope:`   | `:app` (default), `:window`, `:tab` or `:split`                      |
| `payload:` | named fields of types `DesktopKit::Variant` carries; flags enums are not  |
| `ipc:`     | whether `DesktopKit::IPC.send` may send it; `:app` actions only           |
| block      | definitions added to the struct, such as its payload enums           |

`perform` returns whether it handled the action; actions nobody handles are
logged as warnings. Redefine a built-in overload, such as
`perform(target : DesktopKit::App, action : DesktopKit::Action::Quit)`, to change
what it does, and call `super` to keep the default.

Each action has a detailed name, `#detailed_name`, in the GTK format
`<prefix>.<name>[::<string> or (<parameter>)]`. The prefix is `app`, `win`,
`tab` or `split` by scope, so `DesktopKit::Action::NewSplit.new(:right)` is
`split.new-split::right`. Buttons and menus trigger an action through its
detailed name.

Built-in actions, all nested in `DesktopKit::Action`:

| Scope    | Actions (payload)                                                                                                                                                                                                                                                                            |
|----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `app`    | `Quit`, `NewWindow` (ipc), `CloseAllWindows`, `ReloadConfig`, `PresentSurface(surface_id : UInt64)` (ipc), `DesktopNotification(title, body : String)`, `OpenUrl(url : String)`, `ToggleVisibility`, `TogglePanel(panel : String)` (ipc), `ShowGtkInspector`, `Undo`, `Redo`                                                                            |
| `window` | `CloseWindow`, `ToggleMaximize`, `ToggleFullscreen`, `ToggleWindowDecorations`, `ToggleTabOverview`, `ToggleCommandPalette`, `ShowShortcuts`, `GotoWindow(direction : Previous/Next)`, `SetWindowTitle(title)`, `InitialSize(width, height)`, `SizeLimit(min_width, min_height, max_width, max_height)`, `ResizeWindow(width, height)`, `SetWindowTheme(appearance)`, `NewTab`, `GotoTab(index)`, `ResetWindowSize`, `ToggleBackgroundOpacity`, `ActivateKeyTable(table : String)`, `ActivateKeyTableOnce(table : String)`, `DeactivateKeyTable`, `DeactivateAllKeyTables` |
| `tab`    | `CloseTab(mode : This/Other/Right)`, `MoveTab(amount : Int32)`, `MoveTabToNewWindow`, `SetTabTitle(title)`                                                                                                                                                                                    |
| `split`  | `NewSplit(direction)`, `GotoSplit(direction : Previous/Next/Left/Right/Up/Down)`, `ResizeSplit(direction, amount : UInt32)`, `EqualizeSplits`, `ToggleSplitZoom`, `CloseSurface`, `SetTitle(title)`, `PromptTitle(kind : Surface/Tab/Window)`, `RingBell`, `MouseVisibility(visible : Bool)`, `CopyTitleToClipboard`, `ToggleReadOnly`, `ShowOnScreenKeyboard`, `StartSearch`, `EndSearch`, `Search(needle)`, `NavigateSearch(direction : Previous/Next)` |

Sizes are `UInt32` pixels. `SizeLimit` sets the smallest window size and
treats 0 as no limit; GTK 4 windows have no largest size, so its maximum is
ignored. `ResizeWindow` sizes the window so that its surface gets the size,
only while the window shows one surface and is neither maximized nor
fullscreen. `SetWindowTheme` sets the appearance of the whole application.
`GotoTab` counts from 0 and also takes `GotoTab::PREVIOUS`, `NEXT` and
`LAST`; previous and next wrap around, as `MoveTab` does.
`ResetWindowSize` returns a window that is neither maximized nor
fullscreen to its `InitialSize`, 800x600 by default.
`ToggleBackgroundOpacity` makes a window opaque and back while the
`WindowStyle` opacity is below 1. `ToggleVisibility` hides every window
when any is shown and shows them all otherwise; `TogglePanel` does the
same for the panels whose `Panel#name` it names. `ShowGtkInspector` opens
GTK's interactive debugger. `CopyTitleToClipboard` copies the surface's
shown title.
`PresentSurface` presents the surface with that `Surface#id` and ignores
an unknown one; `DesktopNotification` is `App#notify`. `OpenUrl` opens
the URL with the desktop's default handler through the OpenURI portal, and
with `xdg-open` when no portal answers or the request fails; file paths
and `file://` URLs always go to `xdg-open`. A request the user cancels
opens nothing.
`direction` is an `DesktopKit::Direction` (`Left`, `Right`, `Up`, `Down`) unless
the action lists its own values.

### Key bindings

`DesktopKit::App#bindings=` sets the key bindings, callable from any thread and
replacing the previous set:

```crystal
app.bindings = [
  DesktopKit::Binding.new("ctrl+q", DesktopKit::Action::Quit.new),
  DesktopKit::Binding.new("ctrl+shift+e", DesktopKit::Action::NewSplit.new(:right)),
  DesktopKit::Binding.new("ctrl+a>n", DesktopKit::Action::NewTab.new),
  DesktopKit::Binding.new("super+grave", DesktopKit::Action::NewWindow.new, global: true),
]
```

Bindings become GTK accelerators: `app` actions work in every window, the
others act on the focused window, tab or split. A trigger bound twice keeps
its first binding.

A sequence joins triggers with `>`: `"ctrl+a>n"` performs its action when
`n` follows `ctrl+a`. After each trigger of a sequence the window takes the
next key; modifier keys alone do not count, and a key that continues no
sequence ends it and is dropped. A single trigger that starts a sequence
is ignored with a warning. `>` stays a key at the start of a trigger or
after `+`, as in `"ctrl+>"` or `"a>>"`. `Binding#triggers` lists the
triggers, `#sequence?` tells whether there are several, `#label` joins
their labels with spaces (`"Ctrl+A N"`) and `#to_s` gives back the text.
Sequences cannot be global. A pending sequence waits for its next key until
`App#sequence_timeout` passes; `nil`, the default, waits indefinitely.

`App#key_tables=` sets named key tables, modes that lay their own bindings
over the window's while active:

```crystal
app.key_tables = {
  "resize" => [
    DesktopKit::Binding.new("h", DesktopKit::Action::ResizeSplit.new(:left, 20)),
    DesktopKit::Binding.new("l", DesktopKit::Action::ResizeSplit.new(:right, 20)),
    DesktopKit::Binding.new("esc", DesktopKit::Action::DeactivateKeyTable.new),
  ],
}
app.bindings = [DesktopKit::Binding.new("ctrl+r", DesktopKit::Action::ActivateKeyTable.new("resize"))]
```

`ActivateKeyTable` pushes a table onto the window's stack, up to eight
deep; an unknown table or the one already innermost is ignored.
`ActivateKeyTableOnce` pops it again after its first binding performs.
`DeactivateKeyTable` pops the innermost table and `DeactivateAllKeyTables`
all of them. A pending sequence comes first, then the tables from the
innermost out, then the bindings; keys no table binds pass through to the
content. Tables take single keys and sequences but no global bindings,
which raise `ArgumentError`. While a table or a sequence is active the
window shows them in its bottom corner (`resize › Ctrl+A`).

`global: true` marks a binding that works while the application is not
focused. Global bindings go to the desktop's global shortcuts portal
(`org.freedesktop.portal.GlobalShortcuts`), which may ask the user to
confirm them; the action then acts on the active window, tab or split, like
a key binding. The portal identifies the application by its id, which must
match the basename of an installed `.desktop` file, or by the systemd scope
the desktop launched it in. The `on_binding_failed` hook receives each
global binding the desktop does not bind and the reason; by default it logs
a warning. Desktops without the portal fail every global binding.

`DesktopKit::Trigger.parse` reads a trigger: modifiers and a key joined by `+`.

| Part      | Accepted                                                                                           |
|-----------|----------------------------------------------------------------------------------------------------|
| modifiers | `shift`, `ctrl` (`control`), `alt` (`opt`, `option`), `super` (`cmd`, `command`), any case, once each |
| key       | a single character (`t`, `€`, `+` as in `ctrl++`)                                                   |
|           | `enter` (`return`), `esc`, `tab`, `space`, `backspace`, `delete` (`del`), `insert`, `home`, `end`, `page_up` (`pageup`), `page_down` (`pagedown`), `up`, `down`, `left`, `right` (`arrow_*`), `f1` to `f24`, any case |
|           | a GDK key name, exact case, such as `KP_Enter` or `grave`                                           |

Triggers that cannot be shortcuts, such as a modifier key alone or a
character without a key symbol, raise `ArgumentError`. A trigger converts
to its GTK accelerator (`#to_gtk_accel`, `"<Shift><Control>t"`), its XDG
shortcut (`#to_xdg`, `"SHIFT+CTRL+t"`, as global shortcut portals expect),
a label for the user (`#label`, `"Shift+Ctrl+T"`) and back to text
(`#to_s`, `"shift+ctrl+t"`).

`ShowShortcuts` opens a dialog over the window listing every binding,
grouped by the scope of its action, then each key table. A binding's title
is that of the command in `App#commands` with the same action, else the
action name in words; the dialog's search matches the titles.

### Translation

`DesktopKit.translator=` sets the function that translates desktop_kit's own
texts: labels, tooltips, dialog texts and the titles of `Command.defaults` and
`Menu.window`. It receives the English text and returns the one to show;
the default returns it unchanged, and a translator that raises keeps the
English text. Set it before creating the application, as the default
commands and window menu are built then:

```crystal
GERMAN = {"Quit" => "Beenden", "New Tab" => "Neuer Tab"}
DesktopKit.translator = ->(text : String) { GERMAN[text]? || text }
```

Texts the application passes, such as its own command titles or the
`title:` of `Window#open_file`, are shown as given. The texts desktop_kit
translates:

| Text |
|------|
| Allow |
| An application is attempting to read from the clipboard. The current clipboard contents are shown below. |
| An application is attempting to write to the clipboard. The text it would copy is shown below. |
| Application |
| Authorize Clipboard Access |
| Cancel |
| Change Surface Title |
| Change Tab Title |
| Change Tab Title… |
| Change Title |
| Change Title… |
| Change Window Title |
| Change Window Title… |
| Close |
| Close All Windows |
| Close All Windows? |
| Close Other Tabs |
| Close Split |
| Close Split? |
| Close Tab |
| Close Tab? |
| Close Tabs to the Right |
| Close Window |
| Close Window? |
| Command Palette |
| Configuration Errors |
| Copy Title |
| Deny |
| End Search |
| Equalize Splits |
| Find… |
| Focus Next Split |
| Focus Previous Split |
| GTK Inspector |
| Global shortcut |
| Hide All Windows |
| Ignore |
| Key table |
| Keyboard Shortcuts |
| Leave blank to restore the default title. |
| Main Menu |
| Move Tab to New Window |
| New Tab |
| New Window |
| Next Match |
| Next Tab |
| OK |
| One or more configuration errors were found. Please review the errors below, and either reload your configuration or ignore these errors. |
| Open File |
| Open Files |
| Pasting this text may be dangerous as it looks like some commands may be executed. |
| Preferences |
| Previous Match |
| Previous Tab |
| Quit |
| Quit? |
| Read-only |
| Redo Close |
| Reload Configuration |
| Reset Window Size |
| Save File |
| Select Color |
| Select Folder |
| Select Font |
| Show On-Screen Keyboard |
| Some windows ask before closing |
| Split |
| Split Down |
| Split Left |
| Split Right |
| Split Up |
| Tab |
| Tab Overview |
| Toggle Background Opacity |
| Toggle Fullscreen |
| Toggle Maximize |
| Toggle Read-Only |
| Toggle Split Zoom |
| Toggle Window Decorations |
| Undo Close |
| Unsaved work in this split will be lost. |
| Unsaved work in this tab will be lost. |
| Unsaved work in this window will be lost. |
| Unsaved work will be lost. |
| View Open Tabs |
| Warning: Potentially Unsafe Paste |
| Window |
| Zoom Split |

### IPC

`DesktopKit::IPC.send(app_id, action)` triggers an `ipc: true` action in the
running single instance of the application *app_id*, such as
`DesktopKit::Action::NewWindow`; other actions fail to compile. It blocks until
the application answers and raises `DesktopKit::GLibError` when none runs, and
`ArgumentError` for an invalid id. Call it from another process, or from
a thread other than the target application's GTK thread:

```crystal
DesktopKit::IPC.send("org.example.Hello", DesktopKit::Action::NewWindow.new)
```

Only `ipc: true` actions are exported on the session bus; other processes
calling any other action get an error. Inside the application every
action works as usual.

### Tray icon

`App#tray=` shows an `DesktopKit::Tray` in the desktop's system tray while the
application runs; `nil` removes it. Assigning a new one updates the shown
icon, title, tooltip and menu. Callable from any thread.

| Field | Type | Meaning |
|-------|------|---------|
| `icon` | `String` | icon name from the icon theme |
| `title` | `String` | name of the item, shown in its tooltip |
| `tooltip` | `String?` | tooltip text below the title |
| `menu` | `Menu?` | menu shown on click; a `Menu` like the header menu's |
| `activate` | `Action?` | performed on a primary click; without it a primary click shows the menu |

Actions run as if performed in the active window. The tray shows through a
StatusNotifierItem host, such as KDE Plasma's or GNOME's AppIndicator
extension; without a host nothing shows. With `quit_delay = nil` the
application keeps running with only its tray icon.

```crystal
app.tray = DesktopKit::Tray.new(icon: "mail-unread-symbolic", title: "Mail", tooltip: "3 new",
  menu: DesktopKit::Menu.build { |menu|
    menu.item "New Window", DesktopKit::Action::NewWindow.new
    menu.section
    menu.item "Quit", DesktopKit::Action::Quit.new
  },
  activate: DesktopKit::Action::NewWindow.new)
```

### D-Bus

`DesktopKit::DBus` is a message bus connection: `DBus.session`, `DBus.system`
or `App#dbus` (the running application's own, `nil` before it registers).
Arguments and replies are tuple `Variant`s.

| Method | Does |
|--------|------|
| `#call(destination, path, interface, method, args = nil, reply_type:, timeout:, auto_start:) { \|reply, error\| }` | calls a method; the block gets the reply tuple or a `GLibError`, on the calling thread's main loop |
| `#call_sync(...)` | the same, waiting; returns the reply, raises `GLibError` |
| `#emit(path, interface, member, args = nil, destination:)` | emits a signal |
| `#subscribe(sender:, interface:, member:, path:, arg0:) { \|signal\| }` | yields each matching `DBus::Signal` (`sender`, `path`, `interface`, `member`, `args`) until `Subscription#cancel` |
| `#unique_name` | the connection's unique name (`":1.42"`) |

Use `#call` and `#subscribe` on the GTK thread; `#call_sync` and `#emit`
work anywhere. Arguments that are not a tuple raise `ArgumentError`.

```crystal
bus = app.dbus.not_nil!
bus.subscribe(interface: "org.freedesktop.Notifications", member: "ActionInvoked") do |signal|
  puts "#{signal.args[0].get(UInt32)}: #{signal.args[1].get(String)}"
end
```

### Configuration reload

`App#reload`, SIGUSR2 and the `ReloadConfig` action call `on_reload`, where
the application rereads its configuration and applies what lives on the
app, such as `#css=`, `#appearance=` and `#bindings=`. Then each surface's
content gets `Content#on_reload`; an exception there is logged and the
other contents still reload. Under systemd the reload runs between
`RELOADING=1` and `READY=1`.

### systemd

Under systemd (`Type=notify` or `Type=notify-reload`), the application
reports `READY=1` after its first activation, `RELOADING=1` around each
reload and `STOPPING=1` when it quits. `DesktopKit::Systemd.notify(state)` sends
other states, such as `"STATUS=Indexing"`, and returns `false` outside
systemd.

`DesktopKit::Systemd.start_scope` moves a child process into its own transient
scope of the user's service manager, so that systemd accounts, limits and
kills it apart from the application:

```crystal
process = Process.new("make")
unit = "app-#{app.id}-transient-#{process.pid}.scope"
DesktopKit::Systemd.start_scope(process.pid, unit, memory_high: 4_u64 << 30, tasks_max: 512_u64, oom_kill: true)
```

It returns once the process is in the scope, or `false` after *timeout*
(250 ms), and raises `DesktopKit::GLibError` when the session bus or the service
manager refuses.

### Variants

`DesktopKit::Variant` is an immutable GLib `GVariant`, the value type of action
parameters, DBus messages and portal options. Values convert by their
Crystal type:

| Crystal                         | GVariant  |
|---------------------------------|-----------|
| `Bool`                          | `b`       |
| `Int32`, `UInt32`               | `i`, `u`  |
| `Int64`, `UInt64`               | `x`, `t`  |
| `Float64`                       | `d`       |
| `String`                        | `s`       |
| `DesktopKit::Variant::ObjectPath`    | `o`       |
| enum (not `@[Flags]`)           | `s`, the member name in snake case |
| `DesktopKit::Variant`                | `v`       |
| `T?`                            | `mT`      |
| `Array(T)`                      | `aT`      |
| `Hash(K, V)`                    | `a{KV}`   |
| `Tuple(T, U, ...)`              | `(TU...)` |

```crystal
options = DesktopKit::Variant.new({"modal" => DesktopKit::Variant.new(true)})
options.type_string                       # => "a{sv}"
options["modal"]?.try(&.get(Bool))        # => true
DesktopKit::Variant.parse("(1, 'a')").get(Tuple(Int32, String)) # => {1, "a"}
DesktopKit::Variant.signature(Array(String))   # => "as"
```

`#get` raises `TypeCastError` when the variant holds another type;
`.parse` raises `DesktopKit::GLibError` on bad input.

### Widgets

`DesktopKit::Widget` is a borrowed handle to a GTK widget: size, scale,
visibility, focus, cursor, tooltip and CSS classes. It holds no reference;
GTK's widget tree owns the widget. Use it on the GTK thread only.

### Errors

`DesktopKit::GLibError` carries the GLib error domain (`#domain`, a string such
as `"g-io-error-quark"`) and `#code`.

Exceptions raised inside callbacks that GTK runs are logged to the
`"desktop_kit"` `Log` source instead of crossing into C.

## License

MIT; see `LICENSE`, which also holds the notices of third-party code
included here.
