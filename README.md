# apprt

Native application runtime for Crystal programs on Linux, ported from
[Ghostty](https://github.com/ghostty-org/ghostty)'s `src/apprt`: GTK 4 and
libadwaita windows, tabs, splits and surfaces driven by typed actions, with
desktop notifications, global shortcuts, DBus IPC and systemd integration.

Status: early. This release holds the application lifecycle, windows with
tabs and splits of surfaces, an OpenGL drawing canvas with keyboard, input
method and pointer input, the clipboard, actions with local and global key
bindings, desktop notifications, opening URLs, IPC, configuration reload
and the GLib layer the runtime builds on.

`examples/` holds runnable programs; `make examples` builds them into
`bin/`:

| Example     | Shows                                                                 |
|-------------|-----------------------------------------------------------------------|
| `hello.cr`  | windows, tabs and splits of text entries, bindings, a global binding, notifications, reload |
| `canvas.cr` | an OpenGL canvas following pointer, buttons, scrolling and typed text |
| `ipc.cr`    | opens a window in a running `hello.cr`                                |

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
| `on_binding_failed(binding, message)` | when the desktop does not bind a global binding |
| `on_shutdown`              | when quitting, while the windows still exist        |

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
| `Surface#present`                | focuses the surface and raises its window (`PresentSurface`)      |
| `Surface#tab`, `#window`, `#id`  | where it is shown, its identifier, unique in the process          |
| `Surface#focused?`               | whether it holds its window's keyboard focus                      |
| `Surface#cursor=`                | sets the pointer by CSS name (`"text"`, `"pointer"`); `nil` resets |
| `Surface#mouse_visible=`         | shows or hides the pointer over it (`MouseVisibility`)            |
| `Surface#ring_bell`              | beeps and marks it until focused (`RingBell`)                     |

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
application name, marked with 🔍 while zoomed and with 🔔 while one of its
surfaces rings. A ringing surface keeps `Surface#bell_ringing?` until it
gets the focus; its tab needs attention in the tab bar while not selected.
Ringing a focused surface only beeps. A window shows its
`#title_override`, else the title of its selected tab. Assigning `nil` to
an override restores the default.

### Canvas

`Apprt::Canvas` is a `Content` that draws with OpenGL. Subclass it,
implement `#on_render` and override the input hooks you need; each
`#new_surface` call returns a new canvas.

```crystal
class Scene < Apprt::Canvas
  def initialize
    super(api: :gl, version: {3, 3})
  end

  protected def on_render : Nil
    # draw into the bound framebuffer: width × height pixels
  end

  protected def on_key(event : Apprt::KeyEvent) : Bool
    return false unless event.pressed?
    puts event.text || event.keyval
    queue_render
    true
  end
end
```

`.new(*, api, version, depth_buffer, stencil_buffer)` sets what GTK asks
for: `api` is `Canvas::API::GL`, `GLES` or both (the default), `version`
the least `{major, minor}`. The GL context is current in `#on_realize`,
`#on_render`, `#on_resize` and `#on_unrealize`; `#api` is the flavour
GTK made, and `#error` the reason when it made none. Moving a canvas, such
as into a split, unrealizes and realizes it again, so `#on_realize` must
recreate GL objects. GTK draws on its own schedule: call `#queue_render`
after a change.

| Hook                               | Called                                                                 |
|------------------------------------|------------------------------------------------------------------------|
| `on_realize`, `on_unrealize`       | after the GL context is made, before it goes                           |
| `on_render`                        | to draw a frame                                                        |
| `on_resize(width, height)`         | when the framebuffer size changes                                      |
| `on_key(event) : Bool`             | for a key press or release; true when used, else GTK passes the key on |
| `on_preedit(text)`, `on_commit(text)` | input method composition text (`nil` ends it), finished text        |
| `on_focus(focused)`                | when the canvas gains or loses the keyboard focus                      |
| `on_mouse_button(event)`           | for a button press or release; a press focuses the canvas              |
| `on_mouse_motion(event)`, `on_mouse_leave` | while the pointer moves over the canvas, when it leaves        |
| `on_scroll(event)`                 | for a wheel step or a touchpad scroll                                  |

Sizes and positions are framebuffer pixels: `#width`, `#height`, event
coordinates and precise scroll deltas are logical units times `#scale`.
Call `#ime_cursor(x, y, width, height)` with the text cursor's rectangle
in framebuffer pixels so the input method places its popup there.

`Apprt::KeyEvent` holds `pressed?`, `keyval` (a GDK keysym), `keycode`,
`mods` (the modifiers held, counting a modifier key in its own press but
not in its release), `consumed_mods` (the modifiers the layout used to
make the key), `text` (what a press types, `nil` for a release or a
non-text key), `unshifted` (the character of the key without modifiers),
`modifier?` and `composing?` (the input method is composing). A key the
input method uses for a composition reaches `#on_key` with
`composing? = true`; text it finishes comes through `#on_commit`, or as
the event's `text` when one key finishes it. Using a key while composing
ends the composition. `Apprt::MouseButtonEvent` holds `pressed?`,
`button` (`Left`, `Middle`, `Right`, `Back`, `Forward`), `x`, `y` and
`mods`; `Apprt::MouseMotionEvent` holds `x`, `y` and `mods`;
`Apprt::ScrollEvent` holds `dx`, `dy`, `precise?` (pixel deltas from a
touchpad rather than wheel steps) and `mods`.

### Clipboard

`Apprt::Clipboard.write(text, kind = :standard)` puts text on a
clipboard; `.read(kind = :standard) { |text| }` yields its text later, or
`nil` when it holds none. `kind` is `Standard` (copy and paste) or
`Primary` (the selection, pasted by middle-click). Use them on the GTK
thread only.

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
| `ipc:`     | whether `Apprt::IPC.send` may send it; `:app` actions only           |
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
`PresentSurface` presents the surface with that `Surface#id` and ignores
an unknown one; `DesktopNotification` is `App#notify`. `OpenUrl` opens
the URL with the desktop's default handler through the OpenURI portal, and
with `xdg-open` when no portal answers or the request fails; file paths
and `file://` URLs always go to `xdg-open`. A request the user cancels
opens nothing.
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
its first binding.

`global: true` marks a binding that works while the application is not
focused. Global bindings go to the desktop's global shortcuts portal
(`org.freedesktop.portal.GlobalShortcuts`), which may ask the user to
confirm them; the action then acts on the active window, tab or split, like
a key binding. The portal identifies the application by its id, which must
match the basename of an installed `.desktop` file, or by the systemd scope
the desktop launched it in. The `on_binding_failed` hook receives each
global binding the desktop does not bind and the reason; by default it logs
a warning. Desktops without the portal fail every global binding.

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

### IPC

`Apprt::IPC.send(app_id, action)` triggers an `ipc: true` action in the
running single instance of the application *app_id*, such as
`Apprt::Action::NewWindow`; other actions fail to compile. It blocks until
the application answers and raises `Apprt::GLibError` when none runs, and
`ArgumentError` for an invalid id. Call it from another process, or from
a thread other than the target application's GTK thread:

```crystal
Apprt::IPC.send("org.example.Hello", Apprt::Action::NewWindow.new)
```

GApplication exports every `app` action on the session bus, so `ipc:`
selects what `IPC.send` sends, not what other DBus clients can call.

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
