# AGENTS.md

apprt is a native application runtime for Crystal programs on Linux, ported
from Ghostty's `src/apprt` (GTK 4 + libadwaita). It is generic: no terminal,
pty or renderer code. The implementation plan lives in
`.claude/golden-orbiting-key.md`.

## Commands

```sh
make spec     # crystal spec --threads 2 (what `dev repo ship` runs)
make spec-pure # spec/pure only: no display, no bus
make spec-gtk  # spec/gtk only
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
    and GIR constants (`PRIORITY_DEFAULT`, `PRIORITY_DEFAULT_IDLE`,
    `SOURCE_REMOVE`, `STYLE_PROVIDER_PRIORITY_APPLICATION`, `..._USER`).
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
- `src/apprt/types.cr` - value types: `ColorScheme`, `Appearance`,
  `Direction`, `Mods` (public).
- `src/apprt/ui_thread.cr` - `UIThread` (`:nodoc:`): the GTK thread and the
  cross-thread queue.
- `src/apprt/systemd.cr` - `Systemd` (public `notify`; `ready`, `reloading`,
  `stopping` protected for `App`).
- `src/apprt/action.cr` - the `Apprt.action` macro and `Action` (public);
  the registry and GAction installation (`:nodoc:`).
- `src/apprt/actions.cr` - the built-in action table, nested in `Action`.
- `src/apprt/trigger.cr` - `Trigger` (public): key combinations.
- `src/apprt/app.cr` - `App` (public): lifecycle, signals, CSS, appearance,
  `perform` and the built-in app action overloads.
- `src/apprt/binding.cr` - `Binding` (public); reopens `App` with
  `bindings` and the accelerator sync.
- `tools/gen_gir.cr` - generator CLI; `tools/gir/generator.cr` - the
  `GirGenerator` module (GIR → `lib C`).
- `data/gir/<Namespace-Version>.txt` - allowlists.
- `spec/pure/` - specs needing no display: generator (fixture
  `spec/data/Fixture-1.0.gir` + `.txt`), bindings (every generated `fun`
  resolves with `dlsym`, `GValue` size, a GType round trip), the glib layer
  (`glib_spec.cr`, signals on Gio objects), `Variant`, `Systemd`
  (`with_notify_socket` in `spec/spec_helper.cr`), actions (codecs, detailed
  names, registry) and triggers.
- `spec/gtk/` - specs needing a display. `harness.cr` (`GtkHarness.start` in
  `before_all`) runs a private `gtk4-broadwayd` (loopback port, socket in a
  temporary `XDG_RUNTIME_DIR`) and `dbus-daemon`, and points `GDK_BACKEND`,
  `BROADWAY_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`, `XDG_CONFIG_HOME` and
  `GSETTINGS_BACKEND=memory` at them, so the suite never touches the user's
  session. `Spec.after_suite` stops both. Test apps hold the GApplication in
  `on_startup`: without windows or a hold it quits as soon as it is idle.
  `harness.cr` also holds the shared `TestApp`, `AppIds` and `run_app`.
- Types the `Variant` macros expand over (action payload enums) must not be
  file-private in specs: the expansion cannot see them.

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

## Runtime core

- GTK runs on one `Fiber::ExecutionContext::Isolated` thread named `"gtk"`
  that `App#run` starts per run; the calling fiber waits on it. Hooks and
  every GTK call happen there. A later run starts a new thread; GTK and the
  default `GMainContext` survive across runs.
- `UIThread.enter` marks the thread; `current?` / `assert!` check it.
  `post` pushes onto a `Sync::Exclusive` deque and schedules one
  `g_idle_add_full(PRIORITY_DEFAULT)` drain while none is pending (atomic
  flag); the drain clears the flag first, so blocks posted while it runs
  schedule the next one. Exceptions in posted blocks are logged
  (`"posted block"`). `dispatch` runs inline on the UI thread and posts
  elsewhere. `enter` drops the queue when the run ends.
- `App` state mutators (`quit`, `reload`, `css=`, `appearance=`) store and
  `dispatch`, and act only while `running?` (set in startup before the CSS
  and appearance are applied, cleared first thing in shutdown). Stored CSS
  and appearance are applied at startup.
- Startup order: CSS provider (priority `STYLE_PROVIDER_PRIORITY_USER`,
  `parsing-error` → `Log.warn "css parsing failed at <section>: <message>"`),
  appearance, `notify::dark` handler, `on_startup`, first `on_color_scheme`.
  The appearance is applied before the handler connects, so no change is
  reported twice.
- `quit` destroys only `gtk_application_get_windows` (Ghostty: destroying
  every toplevel double-frees fcitx windows), then `g_application_quit`.
- `run` passes GApplication only the program name: without `HANDLES_OPEN`
  it rejects file arguments. Signals are trapped with `Signal#trap` (the
  handlers run on a default-context fiber and post) and reset after the run.
- `Systemd` speaks `sd_notify` over an `AF_UNIX` datagram socket; `@` in
  `NOTIFY_SOCKET` is an abstract address. `MONOTONIC_USEC` comes from
  `CLOCK_MONOTONIC` (Crystal's monotonic clock is `CLOCK_BOOTTIME`).
  `READY=1` follows the first activation; reloads send `RELOADING=1` then
  `READY=1`; shutdown sends `STOPPING=1`.
- Hooks are `protected` with `# :showdoc:` so the docs list them.

## Actions

- `Apprt.action` generates a struct below `Action` with `NAME`, `SCOPE`
  (`:nodoc:`), the payload getters and constructor, and the `:nodoc:` codec:
  `to_variant`, `.parameter_type`, `.from_variant` (nil when the variant does
  not match, including unknown enum names) and `ipc?`. One payload field is
  the GAction parameter itself; several make a tuple. Declaration errors
  (name, scope, ipc outside `:app`, fields shadowing `Action` methods,
  duplicates per scope) are compile errors.
- `Action.registry` is built at compile time from `Action.all_subclasses`,
  so it covers application actions too. `Action.install(map, scope, &perform)`
  adds one `GSimpleAction` per registry entry of *scope* to an action map;
  activation decodes the parameter and calls *perform*, warning when the
  parameter does not decode or *perform* returns false. Steps 7 and later
  install `win`, `tab` and `split` the same way on their widgets.
- Dispatch is overload resolution: `App#perform(target, action)` is called
  on `self`, so subclass overloads for their own action types win.
  Other `Apprt` types must route actions through an `App` method; calling
  `perform` on another object only sees the base overloads.
- The built-in overloads for app actions live in `app.cr`; later components
  reopen `App` with the overloads for their scope.
- `Binding` triggers become `gtk_application_set_accels_for_action` entries
  keyed by `Action#detailed_name`; GTK resolves non-`app` names from the
  focus widget upward. The previous set is cleared first. Global bindings
  are skipped here (portal, step 11).
- `Trigger` normalizes the keyval to lower case and validates it with
  `gtk_accelerator_valid` plus a name round trip (unnamed keyvals such as
  emoji have no accelerator). Accelerator names and labels come from GTK;
  `#to_s` writes the `.parse` grammar.

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
