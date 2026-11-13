# apprt

Native application runtime for Crystal programs on Linux, ported from
[Ghostty](https://github.com/ghostty-org/ghostty)'s `src/apprt`: GTK 4 and
libadwaita windows, tabs, splits and surfaces driven by typed actions, with
desktop notifications, global shortcuts, DBus IPC and systemd integration.

Status: early. This release holds the GLib layer the runtime builds on;
the application, window and surface API follows.

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
