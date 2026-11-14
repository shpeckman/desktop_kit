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

The GTK specs need `sway`, `dbus-daemon` and a GPU driver with EGL (Mesa)
on the host. Run one Crystal compile at a time, with `--threads 2`. When sandboxed, set
`CRYSTAL_CACHE_DIR=.dev/cache`.

## Layout

- `src/apprt.cr` - entry; requires everything, defines `Apprt::Log`
  (`:nodoc:`, source `"apprt"`).
- `src/apprt/c/` - `Apprt::C` (`:nodoc:`), the C bindings.
  - `glib.cr gobject.cr gio.cr gdk.cr gtk.cr adw.cr` - generated, never edit.
  - `manual.cr` - what the generator cannot emit: `GValue` (holds a union)
    and GIR constants (`PRIORITY_DEFAULT`, `PRIORITY_DEFAULT_IDLE`,
    `SOURCE_REMOVE`, `STYLE_PROVIDER_PRIORITY_APPLICATION`, `..._USER`,
    `TYPE_INT`).
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
  - `idle.cr` - `Idle` (`:nodoc:`): one-shot idle callbacks, cancellable.
- `src/apprt/types.cr` - value types: `ColorScheme`, `Appearance`,
  `Direction`, `Mods` (public).
- `src/apprt/split_tree.cr` - `SplitTree(V)` (`:nodoc:`): the immutable split
  model the split view renders.
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
- `src/apprt/dialogs.cr` - `Dialogs` (`:nodoc:`): the close confirmation and
  title prompt alert dialogs.
- `src/apprt/content.cr` - `Content`, `WidgetContent`, `SurfaceContext`
  (public).
- `src/apprt/input.cr` - `KeyEvent`, `MouseButton`, `MouseButtonEvent`,
  `MouseMotionEvent`, `ScrollEvent` (public; initializers `:nodoc:`).
- `src/apprt/canvas.cr` - `Canvas` (public): the `GtkGLArea` content, its
  event controllers and input method context.
- `src/apprt/clipboard.cr` - `Clipboard` (public): text clipboards.
- `src/apprt/surface.cr` - `Surface` (public); reopens `App` with the split
  action overloads.
- `src/apprt/split_view.cr` - `SplitView` (`:nodoc:`): renders a tab's
  `SplitTree(Surface)` as nested `GtkPaned`.
- `src/apprt/tab.cr` - `Tab` (public); reopens `App` with the tab action
  overloads.
- `src/apprt/window.cr` - `Window` (public): widget tree, menu, signals;
  reopens `App` with the window action overloads.
- `tools/gen_gir.cr` - generator CLI; `tools/gir/generator.cr` - the
  `GirGenerator` module (GIR → `lib C`).
- `data/gir/<Namespace-Version>.txt` - allowlists.
- `spec/pure/` - specs needing no display: generator (fixture
  `spec/data/Fixture-1.0.gir` + `.txt`), bindings (every generated `fun`
  resolves with `dlsym`, `GValue` size, a GType round trip), the glib layer
  (`glib_spec.cr`, signals on Gio objects), `Variant`, `Systemd`
  (`with_notify_socket` in `spec/spec_helper.cr`), actions (codecs, detailed
  names, registry), triggers and `SplitTree` (Ghostty's diagram cases).
- `spec/gtk/` - specs needing a display. `harness.cr` (`GtkHarness.start` in
  `before_all`) runs a private headless `sway` (`WLR_BACKENDS=headless`,
  `WLR_RENDERER=pixman`, one 1280x800 output at scale 1, floating windows,
  no Xwayland) and `dbus-daemon` in a temporary `XDG_RUNTIME_DIR`, and
  points `GDK_BACKEND=wayland`, `WAYLAND_DISPLAY`,
  `DBUS_SESSION_BUS_ADDRESS`, `XDG_CONFIG_HOME` and
  `GSETTINGS_BACKEND=memory` at them, so the suite never touches the user's
  session. GTK renders with `GSK_RENDERER=ngl` and `GDK_DISABLE=vulkan`.
  A real compositor replaced broadway because `GtkGLArea` needs GL and a
  process can use only one GDK backend. `Spec.after_suite` stops both.
  Test apps hold the GApplication in `on_startup`: without windows or a
  hold it quits as soon as it is idle. `harness.cr` also holds the shared
  `TestApp` (`make_content` builds each surface's content, a `GtkEntry` by
  default; `new_surface` records the contexts), `AppIds`, `run_app` and
  the step helpers `run_steps`, `settle`, `eventually` and `trigger`.
  `window_spec.cr` covers windows, tabs, splits, titles and dialogs;
  `canvas_spec.cr` the canvas, pointer, bell and clipboard.
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

## Split tree

`SplitTree(V)` (`:nodoc:`) ports Ghostty's `src/datastruct/split_tree.zig`.
`SplitView` and the split actions build on it; users never see it.

- Nodes live in one `Array(V | Split)`, root at `ROOT` (0). `Split` holds
  `layout` (`Horizontal` side by side, `Vertical` stacked), `ratio` (share
  of the left/top child, `Float64` where Ghostty uses `f16`) and the child
  handles. A handle is an `Int32` index valid for one tree only.
- Immutable: every operation returns a new tree, and trees share node
  arrays, which are never mutated after construction. `with_ratio` replaces
  Ghostty's in-place `resizeInPlace` (for paned position write-back).
- `split(at, direction, insert, ratio)` appends *insert*'s nodes (offset)
  and moves the old node at *at* to the end; `at` becomes the split, with
  the inserted tree first for `left`/`up`. Handles of existing nodes stay
  valid, except that the view at *at* moves. Zoom resets.
- `remove(at)` rebuilds depth-first from the root: the sibling takes the
  parent's place, so handles change; re-`locate` views afterwards. The zoom
  follows its node, or clears when that node is removed.
- `goto(from, Goto)` walks leaf order with Ghostty's backtracking search
  (`adjacent`); `goto(from, Direction)` picks the nearest leaf whose slot
  lies fully on that side (Euclidean distance between slot origins, ties to
  the lowest handle), retrying with the target shifted past the opposite
  edge to wrap.
- `spatial` lays the tree out on the unit square, each leaf weighing 1x1
  before ratios. `resize(from, layout, delta)` moves the nearest
  *layout* split above *from* by *delta* of the whole tree
  (`ratio + delta / parent extent`, clamped to `0..1`). `equalize` sets
  each ratio by the leaf count along its axis.
- `to_s` matches Ghostty's text format. `to_diagram` draws ASCII boxes for
  specs; it rounds box edges (Ghostty floors sizes) so neighbours always
  meet, which only changes diagrams where `f16` ratios differ.

## Windows

Internals of `window.cr`, `tab.cr`, `surface.cr`, `split_view.cr` and
`dialogs.cr`, ported from Ghostty's `src/apprt/gtk/class/`:
- GTK owns the widgets; `Window`, `Tab` and `Surface` hold borrowed
  `Widget`s. `App` keeps the registries: `@windows` (open order),
  `@tabs` keyed by the tab's root `AdwBin` pointer (`tab_for` maps an
  `AdwTabPage` child back to its `Tab`) and `@surfaces` by id. Objects
  unregister when closed; shutdown clears all three.
- A window performs through `App#dispatch` (protected), not `perform`:
  `perform` overloads defined in a user subclass belong to the top-level
  namespace, so `@app.perform` from `Window` fails with "protected method
  'perform' called for Hello". `dispatch` calls `perform` with implicit
  `self`, which reaches every overload.
- Window actions live in the window's `win` action map; the `tab` and
  `split` action groups are inserted on the window and target its selected
  tab and that tab's focused surface, so accelerators and the menu resolve
  from any focused widget.
- Widget tree: `AdwApplicationWindow` > `AdwTabOverview` > `AdwToolbarView`
  (top: `AdwHeaderBar` with `AdwWindowTitle`, `AdwTabBar` with autohide;
  content: `AdwTabView`). The tab view's `notify::n-pages` closes the window
  on an idle once no page is left and the overview is closed;
  `close-page` asks for confirmation and finishes with
  `adw_tab_view_close_page_finish`; `create-window` returns the new
  window's tab view.
- Each surface wraps its content widget in a host `AdwBin` (css class
  `surface`) that it holds with `g_object_ref_sink`, so the host survives
  rebuilds while unparented; `release` drops the reference. A focus
  controller on the host reports focus to its tab, which tracks the active
  surface.
- `SplitView`: assigning `tree` schedules one idle rebuild. The rebuild
  moves keyboard focus off its widgets (`gtk_root_set_focus(nil)`: a
  `GtkPaned` that loses its focused child warns "Error finding last focus
  widget"), detaches every divider's children (old panes outlive
  `adw_bin_set_child(nil)`, and GTK rejects a child that still has a
  parent), builds nested `GtkPaned` (resize on, shrink off) for the zoomed
  node or the root, and refocuses the tracked surface once mapped.
- Each `GtkPaned` has a private `Divider`. Changes of `min-position`,
  `max-position` and `position` schedule an idle settle: while
  `max-position` is `Int32::MAX` the paned is unallocated; when the limits
  change the stored ratio is applied (`size` = `max-position` + the end
  child's minimum, `gtk_widget_measure`); otherwise a moved position is
  written back with `SplitTree#with_ratio` (no rebuild) when it changes the
  ratio by at least 0.001. `ratio` is nil while a rebuild is pending.
- Tab resize turns `ResizeSplit`'s pixels into a tree fraction: amount
  divided by the root's width or height, negative toward left and up.
- `Dialogs` runs `AdwAlertDialog` with `adw_alert_dialog_choose`; the
  callback closure lives in `Handles`. Close confirmation responses are
  `cancel`/`close`; title prompts `cancel`/`ok`.
- Bell: `Surface#ring_bell` beeps through the native `GdkSurface`; when
  the surface lacks the focus it sets `bell_ringing?` and calls
  `Tab#bell`, which sets the page's `needs-attention` unless selected and
  retitles the tab (`🔔 ` before `🔍 `). The surface's focus controller
  clears the ring on `enter`; the window clears `needs-attention` when a
  page is selected. `MouseVisibility` sets the content widget's cursor to
  `"none"` and back to `Surface#cursor`.
- Specs: layout and drawing wait for the frame clock, so layout assertions
  poll with `eventually`. A rebuild replaces every `GtkPaned`, so specs
  look panes up again after each split. Dialogs are answered by setting
  the close response to the wanted id and calling
  `adw_dialog_force_close`.

## Canvas

Internals of `canvas.cr` and `input.cr`, ported from Ghostty's
`src/apprt/gtk/class/surface.zig`:
- The widget is a `GtkGLArea` (focusable, focus on click, expanding) with
  `allowed-apis`, `required-version`, `has-depth-buffer` and
  `has-stencil-buffer` from `.new`; `auto-render` stays on. Realize makes
  the context current and sets the input method's client widget; a GL
  error goes to `#error` and `Log.error "GL context: …"`. `#scale` is the
  integer `gtk_widget_get_scale_factor`: the GL area's framebuffer uses it
  even on fractional outputs (1.5 gives a scale of 2 and a framebuffer
  twice the logical size).
- Controllers: key (with the `GtkIMMulticontext`), focus, click gesture
  (button 0, all buttons), motion and scroll (both axes). Ivars carry
  `@im_`/`_controller`/`_gesture` names: subclasses share the instance
  variable namespace, and a subclass `@keys` collided with ours.
- Keys follow Ghostty's `keyEvent`: the key goes to
  `gtk_im_context_filter_keypress` first. A commit that arrives inside
  the filter while not composing becomes the key's `text`; a key the
  input method filtered while composing (or ending a composition, or
  without committed text) reaches `#on_key` with `composing?`. Otherwise
  the text is `gdk_keyval_to_unicode` for a press (control characters
  below 0x20 and DEL excluded). `unshifted` comes from
  `gdk_display_map_keycode` at the event's layout, level 0. Modifier keys
  adjust `mods` for themselves (`MODIFIER_KEYS`). When `#on_key` uses a key
  during a composition the context is reset and `#on_preedit(nil)` sent.
- `Mods.from_gdk`/`#to_gdk` (`:nodoc:`, `types.cr`) map GDK modifier
  masks; the table is module-level `MODS_GDK` because an enum body cannot
  hold a constant.
- Pointer positions and precise scroll deltas are multiplied by `#scale`.
  `precise?` is `gtk_event_controller_scroll_get_unit == SURFACE`.
- `Clipboard.read` keeps the block in `Handles` until
  `gdk_clipboard_read_text_finish`; a read error logs a warning and yields
  `nil`.
- Specs drive the controllers by emitting their signals
  (`g_signal_emit_by_name` on `canvas.@key_controller` and friends), so
  they need no input devices.

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
