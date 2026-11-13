# apprt

Native application runtime for Crystal programs on Linux, ported from
[Ghostty](https://github.com/ghostty-org/ghostty)'s `src/apprt`: GTK 4 and
libadwaita windows, tabs, splits and surfaces driven by typed actions, with
desktop notifications, global shortcuts, DBus IPC and systemd integration.

Status: early. This release holds the application lifecycle and the GLib
layer the runtime builds on; the window and surface API follows.

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

Subclass `Apprt::App`, override the hooks it needs and call `#run`:

```crystal
class Hello < Apprt::App
  protected def on_startup
    self.css = "window { background: #202020; }"
  end

  protected def on_activate
    # open the first window here
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

Everything else is callable from any thread:

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
