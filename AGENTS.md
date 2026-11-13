# AGENTS.md

apprt is a native application runtime for Crystal programs on Linux, ported
from Ghostty's `src/apprt` (GTK 4 + libadwaita). It is generic: no terminal,
pty or renderer code. The implementation plan lives in
`.claude/golden-orbiting-key.md`.

## Commands

```sh
make spec     # crystal spec --threads 2
make gen      # regenerate src/apprt/c/*.cr from GIR + data/gir/ allowlists
make docs     # crystal docs src/apprt.cr -o docs
make format   # crystal tool format src spec tools
make clean
```

Run one Crystal compile at a time, with `--threads 2`. When sandboxed, set
`CRYSTAL_CACHE_DIR=.dev/cache`.

## Layout

- `src/apprt.cr` - entry; requires everything, defines `Apprt::Log`
  (`:nodoc:`, source `"apprt"`).
- `src/apprt/c/` - `Apprt::C` (`:nodoc:`), the C bindings.
  - `glib.cr gobject.cr gio.cr gdk.cr gtk.cr adw.cr` - generated, never edit.
  - `manual.cr` - what the generator cannot emit: `GValue` (holds a union)
    and the GLib macros `PRIORITY_DEFAULT_IDLE`, `SOURCE_REMOVE`.
- `src/apprt/glib/` - the GLib/GObject layer every component builds on.
  - `error.cr` - `GLibError` (public).
  - `native.cr` - `Native` (`:nodoc:`): C string, strv and GList helpers.
  - `handles.cr` - `Handles` (`:nodoc:`): keeps Crystal values passed to C
    as `gpointer` alive.
  - `wrapper.cr` - `Wrapper` (`:nodoc:`): owned references to GObjects and
    boxed types.
  - `variant.cr` - `Variant` (public).
  - `widget.cr` - `Widget` (public): borrowed widget handle.
  - `signals.cr` - `Signals` (`:nodoc:`): signal connections.
- `tools/gen_gir.cr` - generator CLI; `tools/gir/generator.cr` - the
  `GirGenerator` module (GIR → `lib C`).
- `data/gir/<Namespace-Version>.txt` - allowlists.
- `spec/pure/` - specs needing no display: generator (fixture
  `spec/data/Fixture-1.0.gir` + `.txt`), bindings (every generated `fun`
  resolves with `dlsym`, `GValue` size, a GType round trip), the glib layer
  (`glib_spec.cr`, signals on Gio objects) and `Variant`.

## GLib layer

Internal contracts of `src/apprt/glib/`:

- `Handles.retain(value) : Void*` stores any Crystal value (usually a proc)
  under a fresh pointer; `Handles.get(data, T)` reads it back,
  `Handles.release` drops it. `Handles::RELEASE` (`GDestroyNotify`) and
  `Handles::RELEASE_CLOSURE` (`GClosureNotify`) release from C. The table is
  a `Sync::Exclusive` hash: never touch it from a finalizer (Boehm runs
  finalizers inside allocations, on any thread, possibly with the lock
  held).
- `Wrapper` subclasses own one reference. `take(ptr)` adopts a full
  reference, `from_raw(ptr)` refs a borrowed one; the `?` variants map null
  to `nil`. Instances are built with `allocate` + `initialize`, so a
  subclass may define its own `self.new` overloads (as `Variant` does).
  Finalizers do not unref GObjects directly: `c_release` schedules
  `g_object_unref` on the default main context (`g_idle_add_full`), because
  dispose can emit signals into Crystal and GTK objects belong to the GTK
  thread. `boxed ref, unref` declares a thread-safe boxed type (GVariant)
  that unrefs in the finalizer.
- `Widget` is a struct without a reference: GTK's tree owns widgets.
  Components that own a widget keep a `Wrapper` reference instead. Methods
  for other runtime components are `protected` (callable from any type in
  `Apprt`).
- `Signals.connect(instance, "signal", ->(arg : Type, ...) : Result { })`
  takes a proc literal whose parameters are the signal's arguments after
  the instance. Each restriction picks a conversion of the C argument:

  | Restriction                     | C argument  | Conversion                 |
  |---------------------------------|-------------|----------------------------|
  | `Bool`                          | `gboolean`  | `!= 0`                     |
  | `String`, `String?`             | `gchar*`    | copy; null → `nil`         |
  | `Int32` ... `Float64`, `Void*`  | same        | none                       |
  | enum                            | `gint`      | `from_value`               |
  | `Widget`, `Widget?`             | `GtkWidget*`| borrowed handle            |
  | `Wrapper` subclass (or `?`)     | `GObject*`  | `from_raw` (new reference) |

  Results: `Nil`, `Bool` (→ `gboolean`), `Int32`. Exceptions are logged to
  `Apprt::Log` and the signal gets a zero result. The proc is retained in
  `Handles` and released when GObject drops the handler (disconnect or
  instance finalization). `Signals.notify(instance, "property", -> { })`
  watches a property.
- `Variant` maps Crystal types to GVariant types at compile time
  (`Variant.signature(T)`); enums travel as snake-case strings. Its `hash`
  hashes the type string and the printed form because `g_variant_hash`
  rejects containers.

## Bindings

Add a C symbol by listing it in its namespace's allowlist and running
`make gen`. Allowlist lines are symbols or type names (`gtk_widget_show`,
`GtkOrientation`, `GdkRGBA`); `#` starts a comment. Rules the generator
enforces:

- Listed enums and bitfields become Crystal enums (bitfields drop the
  zero/All members and are `@[Flags]`); listed callbacks become proc aliases.
- Listed records become structs and must have fields; opaque records,
  bit fields and unions fail generation. Bind those in `c/manual.cr`.
- Unlisted records and classes are `Void*`. A record passed by value must be
  listed.
- `throws` functions get a trailing `GError**` (`Void**` if `GError` is not
  listed).
- Symbols must resolve to a namespace with an allowlist; GIR includes such as
  Pango or Graphene are only types.
- Every listed class needs its `*_get_type` function.

Library links come from each GIR `<package>` (`@[Link(pkg_config: ...)]`).
GIR files are read from `GIR_DIR`, else the pkg-config `girdir`, else
`/usr/share/gir-1.0`.

## Code standards

- Compiler-friendly, performance-focused, idiomatic Crystal.
- Data-driven design: tables and records over branching logic.
- Ergonomic user-facing API.
- Avoid shotgun surgery: one change, one place.
- Every file starts with a comment holding its path (`# src/apprt.cr`).
- Visibility: `private` inside a type/namespace, `protected` for same
  namespace callers, `# :nodoc:` for what other shards or specs must reach but
  users should not use (`Apprt::C`, `GirGenerator`). Check with `make docs`.
- Doc comments: first sentence in third person present; no implementation
  details; italicize parameters, backtick references; never link `:nodoc:`
  features from public docs.
- No stubs or placeholders; no unrequested features.
- Don't change the version in shard.yml.
- Keep README.md (public API) and AGENTS.md (everything else) in sync.
