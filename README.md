# apprt

Native application runtime for Crystal programs on Linux, ported from
[Ghostty](https://github.com/ghostty-org/ghostty)'s `src/apprt`: GTK 4 and
libadwaita windows, tabs, splits and surfaces driven by typed actions, with
desktop notifications, global shortcuts, DBus IPC and systemd integration.

Status: early. This release holds the application lifecycle, windows with
tabs and splits of surfaces, actions and key bindings, and the GLib layer
the runtime builds on. Surfaces show any GTK widget; a drawing canvas,
desktop notifications and IPC follow. The built-in actions `RingBell`,
`MouseVisibility`, `PresentSurface`, `DesktopNotification` and `OpenUrl`
are not carried out yet, and global bindings are not registered with the
desktop yet.

## Requirements

- Crystal ≥ 1.23
- GTK ≥ 4.18 and libadwaita ≥ 1.7 (development packages, found with
  `pkg-config`)

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  apprt:
    github: shpeckman/apprt
```

Run `shards install`, then:

```crystal
require "apprt"
```

## API

### Applications

Subclass `Apprt::App`, return the content of new surfaces from
`#new_surface`, override the hooks it needs and call `#run`:

```crystal
class Hello < Apprt::App
  protected def new_surface(context : Apprt::SurfaceContext) : Apprt::Content
    # A widget from the application's own GTK bindings.
    Apprt::WidgetContent.new(Apprt::Widget.new(LibGtk.gtk_label_new("Hello")))
  end

  protected def on_startup
    self.css = "window { background: #202020; }"
  end

  protected def on_activate
    new_window
  end

  protected def on_color_scheme(scheme : Apprt::ColorScheme)
    puts "now #{scheme}"
  end
end

exit Hello.new("org.example.Hello").run
```

`#run` drives GTK on a thread of its own and blocks the calling fiber until
`#quit` is called or the last application window closes; it returns the
exit status. One application runs at a time. The application id must be a
valid reverse-DNS name (`ArgumentError` otherwise). With
`single_instance: true`, the default, launching the program again
activates the running instance.

Hooks, all called on the GTK thread:

| Hook                       | Called                                              |
|----------------------------|-----------------------------------------------------|
| `on_startup`               | once GTK is initialized                             |
| `on_activate`              | at launch, and on each relaunch of a single instance |
| `on_color_scheme(scheme)`  | after `on_startup`, then whenever light/dark changes |
| `on_reload`                | on `#reload` and SIGUSR2                            |
| `on_shutdown`              | when quitting, while the windows still exist        |

These methods are callable from any thread:

- `#post { ... }` runs the block on the GTK thread at the next main loop
  iteration, in posting order. Blocks posted before `#run` run once the
  application is active; blocks still queued when it quits are dropped.
- `#quit` closes the application windows and quits; `#reload` calls
  `on_reload`. Both do nothing unless `#running?`.
- `#css=` sets the application style sheet, applied above the theme;
  parse errors are logged as warnings.
- `#appearance=` requests `Apprt::Appearance::System` (follow the desktop,
  the default), `Light` or `Dark`.

While `#run` runs, SIGINT and SIGTERM quit the application and SIGUSR2
reloads it; the signals return to their default action afterwards.

### Windows, tabs and surfaces

A window holds tabs; a tab holds one or more surfaces laid out in splits.
A surface shows a `Apprt::Content`, which `#new_surface` creates: return
an `Apprt::WidgetContent` to show a widget, or a subclass of `Content`.
Each call must return a new content; `Content#surface` is the surface
showing it. The `Apprt::SurfaceContext` tells where the surface opens:
`kind` is `Window`, `Tab` or `Split`, and `parent` is the surface it opens
from, if any.

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
| `Surface#split(direction)`       | opens a surface beside it, in an `Apprt::Direction`, and focuses it |
| `Surface#focus`, `#close`        | focuses the surface and selects its tab, closes it                |
| `Surface#tab`, `#window`, `#id`  | where it is shown, its identifier, unique in the process          |

A window has a header bar with a new tab button, a tab overview button and
a menu with the window, tab, split and title actions; the tab bar shows
while there is more than one tab. Closing the last surface of a tab closes
the tab, and closing the last tab closes the window. Once closed,
`#closed?` is true, `Window#new_tab` and `Surface#split` raise
`RuntimeError`, and the objects leave the registries.

Closing asks the user first when a surface it closes has
`Surface#confirm_close = true`: a split, a tab, a window, all windows or
the application. `App#quit` never asks.

Titles: a surface has a `#title`, set by the application, and a
`#title_override`, set by the user through `PromptTitle`. A tab shows its
`#title_override`, else the title of its focused surface, else the
application name, marked with 🔍 while zoomed. A window shows its
`#title_override`, else the title of its selected tab. Assigning `nil` to
an override restores the default.

### Actions

Everything the runtime does on request is an action: a typed value that
menus, buttons, key bindings and other processes trigger through GTK's
action system. `Apprt::App#perform` carries actions out, with one overload
per action type. Its *target* is the `Apprt::App` for `app` actions, the
`Apprt::Window` for `window` actions, the `Apprt::Tab` for `tab` actions
and the `Apprt::Surface` for `split` actions; a window triggers its tab and
split actions on its selected tab and that tab's focused surface.

Declare an action with `Apprt.action`; the payload becomes the struct's
constructor arguments and getters:

```crystal
Apprt.action Refresh, "refresh", payload: {force: Bool}

Apprt.action Zoom, "zoom", scope: :split, payload: {step: Step} do
  enum Step
    In
    Out
  end
end

class Viewer < Apprt::App
  protected def perform(target : Apprt::App, action : Refresh) : Bool
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
| `payload:` | named fields of types `Apprt::Variant` carries; flags enums are not  |
| `ipc:`     | whether other processes may trigger it; `:app` actions only          |
| block      | definitions added to the struct, such as its payload enums           |

`perform` returns whether it handled the action; actions nobody handles are
logged as warnings. Redefine a built-in overload, such as
`perform(target : Apprt::App, action : Apprt::Action::Quit)`, to change
what it does, and call `super` to keep the default.

Each action has a detailed name, `#detailed_name`, in the GTK format
`<prefix>.<name>[::<string> or (<parameter>)]`. The prefix is `app`, `win`,
`tab` or `split` by scope, so `Apprt::Action::NewSplit.new(:right)` is
`split.new-split::right`. Buttons and menus trigger an action through its
detailed name.

Built-in actions, all nested in `Apprt::Action`:

| Scope    | Actions (payload)                                                                                                                                                                                                                                                                            |
|----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `app`    | `Quit`, `NewWindow` (ipc), `CloseAllWindows`, `ReloadConfig`, `PresentSurface(surface_id : UInt64)`, `DesktopNotification(title, body : String)`, `OpenUrl(url : String)`                                                                                                                     |
| `window` | `CloseWindow`, `ToggleMaximize`, `ToggleFullscreen`, `ToggleWindowDecorations`, `ToggleTabOverview`, `GotoWindow(direction : Previous/Next)`, `SetWindowTitle(title)`, `InitialSize(width, height)`, `SizeLimit(min_width, min_height, max_width, max_height)`, `ResizeWindow(width, height)`, `SetWindowTheme(appearance)`, `NewTab`, `GotoTab(index)` |
| `tab`    | `CloseTab(mode : This/Other/Right)`, `MoveTab(amount : Int32)`, `MoveTabToNewWindow`, `SetTabTitle(title)`                                                                                                                                                                                    |
| `split`  | `NewSplit(direction)`, `GotoSplit(direction : Previous/Next/Left/Right/Up/Down)`, `ResizeSplit(direction, amount : UInt32)`, `EqualizeSplits`, `ToggleSplitZoom`, `CloseSurface`, `SetTitle(title)`, `PromptTitle(kind : Surface/Tab/Window)`, `RingBell`, `MouseVisibility(visible : Bool)`                  |

Sizes are `UInt32` pixels. `SizeLimit` sets the smallest window size and
treats 0 as no limit; GTK 4 windows have no largest size, so its maximum is
ignored. `ResizeWindow` sizes the window so that its surface gets the size,
only while the window shows one surface and is neither maximized nor
fullscreen. `SetWindowTheme` sets the appearance of the whole application.
`GotoTab` counts from 0 and also takes `GotoTab::PREVIOUS`, `NEXT` and
`LAST`; previous and next wrap around, as `MoveTab` does.
`direction` is an `Apprt::Direction` (`Left`, `Right`, `Up`, `Down`) unless
the action lists its own values.

### Key bindings

`Apprt::App#bindings=` sets the key bindings, callable from any thread and
replacing the previous set:

```crystal
app.bindings = [
  Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new),
  Apprt::Binding.new("ctrl+shift+e", Apprt::Action::NewSplit.new(:right)),
  Apprt::Binding.new("super+grave", Apprt::Action::NewWindow.new, global: true),
]
```

Bindings become GTK accelerators: `app` actions work in every window, the
others act on the focused window, tab or split. A trigger bound twice keeps
its first binding. `global: true` marks a binding that works
while the application is not focused.

`Apprt::Trigger.parse` reads a trigger: modifiers and a key joined by `+`.

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

### systemd

Under systemd (`Type=notify` or `Type=notify-reload`), the application
reports `READY=1` after its first activation, `RELOADING=1` around each
reload and `STOPPING=1` when it quits. `Apprt::Systemd.notify(state)` sends
other states, such as `"STATUS=Indexing"`, and returns `false` outside
systemd.

### Variants

`Apprt::Variant` is an immutable GLib `GVariant`, the value type of action
parameters, DBus messages and portal options. Values convert by their
Crystal type:

| Crystal                         | GVariant  |
|---------------------------------|-----------|
| `Bool`                          | `b`       |
| `Int32`, `UInt32`               | `i`, `u`  |
| `Int64`, `UInt64`               | `x`, `t`  |
| `Float64`                       | `d`       |
| `String`                        | `s`       |
| `Apprt::Variant::ObjectPath`    | `o`       |
| enum (not `@[Flags]`)           | `s`, the member name in snake case |
| `Apprt::Variant`                | `v`       |
| `T?`                            | `mT`      |
| `Array(T)`                      | `aT`      |
| `Hash(K, V)`                    | `a{KV}`   |
| `Tuple(T, U, ...)`              | `(TU...)` |

```crystal
options = Apprt::Variant.new({"modal" => Apprt::Variant.new(true)})
options.type_string                       # => "a{sv}"
options["modal"]?.try(&.get(Bool))        # => true
Apprt::Variant.parse("(1, 'a')").get(Tuple(Int32, String)) # => {1, "a"}
Apprt::Variant.signature(Array(String))   # => "as"
```

`#get` raises `TypeCastError` when the variant holds another type;
`.parse` raises `Apprt::GLibError` on bad input.

### Widgets

`Apprt::Widget` is a borrowed handle to a GTK widget: size, scale,
visibility, focus, cursor, tooltip and CSS classes. It holds no reference;
GTK's widget tree owns the widget. Use it on the GTK thread only.

### Errors

`Apprt::GLibError` carries the GLib error domain (`#domain`, a string such
as `"g-io-error-quark"`) and `#code`.

Exceptions raised inside callbacks that GTK runs are logged to the
`"apprt"` `Log` source instead of crossing into C.

## License

MIT. Parts are ported from Ghostty (MIT, © Mitchell Hashimoto, Ghostty
contributors); see `LICENSE`.
