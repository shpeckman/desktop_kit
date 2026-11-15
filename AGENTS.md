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
make examples # build examples/*.cr into bin/
make docs     # crystal docs src/apprt.cr -o docs
make format   # crystal tool format src spec tools examples
make clean
```

The GTK specs need `sway`, `dbus-daemon` and a GPU driver with EGL (Mesa)
on the host. Run one Crystal compile at a time, with `--threads 2`. When sandboxed, set
`CRYSTAL_CACHE_DIR=.dev/cache`.

## Layout

- `src/apprt.cr` - entry; requires everything, defines `Apprt::Log`
  (`:nodoc:`, source `"apprt"`).
- `src/apprt/c/` - `Apprt::C` (`:nodoc:`), the C bindings.
  - `glib.cr gobject.cr gio.cr gdk.cr gdkwayland.cr gtk.cr adw.cr` -
    generated, never edit.
  - `manual.cr` - what the generator cannot emit: `GValue` (holds a union)
    and GIR constants (`PRIORITY_DEFAULT`, `PRIORITY_DEFAULT_IDLE`,
    `SOURCE_REMOVE`, `STYLE_PROVIDER_PRIORITY_APPLICATION`, `..._USER`,
    `TYPE_INT`, `TYPE_UINT64`, `TYPE_STRING`) and `gdk_file_list_get_type`
    (introspectable="0" in the GIR).
  - `wayland.cr` - `Apprt::Wl` (`:nodoc:`), hand-written libwayland-client
    functions (proxies, queues, `wl_proxy_marshal_array_flags`,
    dispatchers).
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
  - `idle.cr` - `Idle` (`:nodoc:`): one-shot idle and timeout callbacks,
    cancellable.
  - `stream.cr` - `Stream` (`:nodoc:`): reads a `GInputStream` to its end
    (spliced into a `GMemoryOutputStream`) and converts `GBytes`.
- `src/apprt/source.cr` - `Source` (public): `App#after` timers and
  `App#watch` file descriptor watches.
- `src/apprt/types.cr` - value types: `ColorScheme`, `Appearance`,
  `Decoration`, `Direction`, `Mods` (public).
- `src/apprt/key.cr` - `Key` (public): physical keys by evdev code;
  `Key.from_keycode` (`:nodoc:`).
- `src/apprt/split_tree.cr` - `SplitTree(V)` (`:nodoc:`): the immutable split
  model the split view renders.
- `src/apprt/ui_thread.cr` - `UIThread` (`:nodoc:`): the GTK thread and the
  cross-thread queue.
- `src/apprt/systemd.cr` - `Systemd` (public `notify` and `start_scope`;
  `ready`, `reloading`, `stopping` and `cgroup` protected).
- `src/apprt/wayland.cr` - `Wayland` (`:nodoc:`): protocol tables,
  `Proxy` and the per-display `Globals`.
- `src/apprt/winproto.cr` - `Winproto` (`:nodoc:`): a window's server
  decoration, blur and activation objects.
- `src/apprt/action.cr` - the `Apprt.action` macro and `Action` (public);
  the registry and GAction installation (`:nodoc:`).
- `src/apprt/actions.cr` - the built-in action table, nested in `Action`.
- `src/apprt/trigger.cr` - `Trigger` (public): key combinations.
- `src/apprt/app.cr` - `App` (public): lifecycle, signals, CSS, appearance,
  `perform` and the built-in app action overloads.
- `src/apprt/binding.cr` - `Binding` (public): triggers and sequences;
  reopens `App` with `bindings`, the accelerator sync, the sequence table
  and `perform_in`.
- `src/apprt/dialogs.cr` - `Dialogs` (`:nodoc:`): the confirm and prompt
  alert dialogs behind `Window#confirm`/`#prompt`, the close confirmation,
  the title prompt, the clipboard confirmation and the configuration
  errors dialog.
- `src/apprt/bell.cr` - `Bell` (public); reopens `App` with `bell`,
  `bell_sound`, `bell_volume` and the sound playback.
- `src/apprt/config_errors.cr` - reopens `App` with `config_errors` and
  its dialog.
- `src/apprt/content.cr` - `Content` (with the `on_drop` hooks),
  `WidgetContent`, `SurfaceContext` (public).
- `src/apprt/input.cr` - `KeyEvent`, `MouseButton`, `MouseButtonEvent`,
  `MouseMotionEvent`, `ScrollEvent` (public; initializers `:nodoc:`).
- `src/apprt/canvas.cr` - `Canvas` and `FrameTiming` (public): the
  OpenGL content, its event controllers, input method context, drop
  target and drags.
- `src/apprt/gl.cr` - `GLContext` (public), `GL` and `CanvasBuffers`
  (`:nodoc:`): GL contexts, the epoxy calls and the canvas's buffers.
- `src/apprt/drag.cr` - `DragAction`, `Drop`, `Drag`, `Drag::Request`,
  `Drag::Icon` (public); `DragContent` (`:nodoc:`), the lazy
  `GdkContentProvider` subclass behind `Canvas#drag`.
- `src/apprt/clipboard.cr` - `Clipboard` and `Clipboard::Request`
  (public): text clipboards.
- `src/apprt/surface.cr` - `Surface` (public): host, drag handle, drop
  targets; reopens `App` with the split action overloads.
- `src/apprt/split_view.cr` - `SplitView` (`:nodoc:`): renders a tab's
  `SplitTree(Surface)` as nested `GtkPaned`.
- `src/apprt/tab.cr` - `Tab` (public); reopens `App` with the tab action
  overloads.
- `src/apprt/window.cr` - `Window` (public): widget tree, menu, signals,
  the key sequence controller; reopens `App` with the window action
  overloads.
- `src/apprt/command_palette.cr` - `Command` (public), `CommandPalette`
  (`:nodoc:`); reopens `App` with `commands` and the
  `ToggleCommandPalette` overload.
- `src/apprt/window_style.cr` - `WindowStyle` (public; `to_css`
  `:nodoc:`); reopens `App` with `window_style` and the runtime style
  sheet.
- `src/apprt/undo_stack.cr` - `UndoStack` (`:nodoc:`): closed surfaces,
  tabs and windows kept for undo; reopens `App` with `undo_timeout` and
  the `Undo`/`Redo` overloads.
- `src/apprt/progress.cr` - `Progress` (public), `LauncherEntry`
  (`:nodoc:`); reopens `App` with `sync_progress`.
- `src/apprt/notifications.cr` - `Notifications` (`:nodoc:`): a surface's
  sent notifications; reopens `App` with `notify` and the
  `DesktopNotification` and `PresentSurface` overloads.
- `src/apprt/ipc.cr` - `IPC` (public): `IPC.send` over `org.gtk.Actions`.
- `src/apprt/portal.cr` - `Portal` (`:nodoc:`): XDG desktop portal requests
  and the host registry.
- `src/apprt/global_shortcuts.cr` - `GlobalShortcuts` (`:nodoc:`): the
  global bindings' portal session.
- `src/apprt/open_uri.cr` - `OpenURI` (`:nodoc:`): `OpenUrl` through the
  OpenURI portal or `xdg-open`.
- `src/apprt/dbus.cr` - `DBus` (public): GDBus connections, calls,
  signals and subscriptions; reopens `App` with `dbus`.
- `src/apprt/user_idle.cr` - reopens `App` with `idle_timeout`,
  `user_idle?` and `on_user_idle` (ext-idle-notify-v1).
- `examples/` - `hello.cr`, `canvas.cr`, `ipc.cr`, `workspace.cr`,
  `snake.cr`, `dialogs.cr` (`make examples`). They declare their own
  `lib LibGtk` / `lib LibGL` funs rather than use the `:nodoc:` `Apprt::C`.
  Content that names its surface (`workspace.cr`, `snake.cr`) does so in
  a block posted from `new_surface`: `Content#surface` is set only once
  `new_surface` has returned.
- `tools/gen_gir.cr` - generator CLI; `tools/gir/generator.cr` - the
  `GirGenerator` module (GIR → `lib C`).
- `data/gir/<Namespace-Version>.txt` - allowlists.
- `spec/pure/` - specs needing no display: generator (fixture
  `spec/data/Fixture-1.0.gir` + `.txt`), bindings (every generated `fun`
  resolves with `dlsym`, `GValue` size, a GType round trip), the glib layer
  (`glib_spec.cr`, signals on Gio objects), `Variant`, `Systemd`
  (`with_notify_socket` in `spec/spec_helper.cr`), actions (codecs, detailed
  names, registry), triggers and binding sequences, `Key`, `Command`,
  `SplitTree` (Ghostty's diagram cases) and the `Notifications`
  bookkeeping and portal request paths.
- `spec/gtk/` - specs needing a display. `harness.cr` (`GtkHarness.start` in
  `before_all`) runs a private headless `sway` (`WLR_BACKENDS=headless`,
  `WLR_RENDERER=pixman`, one 1280x800 output at scale 1, floating windows,
  no Xwayland) and `dbus-daemon` in a temporary `XDG_RUNTIME_DIR`, and
  points `GDK_BACKEND=wayland`, `WAYLAND_DISPLAY`,
  `DBUS_SESSION_BUS_ADDRESS`, `XDG_CONFIG_HOME` and
  `GSETTINGS_BACKEND=memory` at them, so the suite never touches the user's
  session. GTK renders with `GSK_RENDERER=ngl` and `GDK_DISABLE=vulkan`;
  `GNOTIFICATION_BACKEND=freedesktop` sends notifications to the fake
  server. `GTK_MEDIA=none` keeps GStreamer out: its GL display outlives
  the media stream and floods "Failed to flush Wayland connection" once
  `after_suite` stops sway, so bell sounds fail and only the warning is
  checked.
  A real compositor replaced broadway because `GtkGLArea` needs GL and a
  process can use only one GDK backend. `Spec.after_suite` stops both.
  Test apps hold the GApplication in `on_startup`: without windows or a
  hold it quits as soon as it is idle. `harness.cr` also holds the shared
  `TestApp` (`make_content` builds each surface's content, a `GtkEntry` by
  default; `new_surface` records the contexts), `AppIds`, `run_app` and
  the step helpers `run_steps`, `settle`, `eventually` and `trigger`.
  The bus runs from a generated config (`bus.conf`) with no service
  directories: names nobody owns, such as the desktop portal or the
  accessibility bus, fail with `ServiceUnknown` instead of starting the
  host's services.
  `window_spec.cr` covers windows, tabs, splits, titles and dialogs
  (`Window#confirm`/`#prompt` too); `command_palette_spec.cr` the palette;
  `sequence_spec.cr` key sequences, emitting `key-pressed` on the window's
  `@sequence_keys`; `key_table_spec.cr` key tables and the key state
  overlay; `window_actions_spec.cr` visibility, window size, background
  opacity, title copy and read-only; `undo_spec.cr` undo and redo of
  surfaces, tabs and windows and the timeout; `progress_spec.cr` the
  progress bar, tab loading and the launcher entry signal;
  `window_style_spec.cr` pane headers, the active mark, tab icons, tabs
  in the header bar, header bar content and `on_window`;
  `canvas_spec.cr` the canvas, pointer, bell and clipboard;
  `notifications_spec.cr` notifications against `FakeNotifications`
  (`fake_notifications.cr`); `ipc_spec.cr` IPC round trips;
  `global_shortcuts_spec.cr` global bindings against `FakePortal`
  (`fake_portal.cr`); `reload_spec.cr` content reload; `open_url_spec.cr`
  `OpenUrl` against `FakePortal` and a fake `xdg-open` first on `PATH`;
  `decoration_spec.cr` decorations, blur, urgency and toasts;
  `drop_spec.cr` data drops and surface moves (emitting the drop targets'
  signals); `scope_spec.cr` `Systemd.start_scope` against the private bus,
  which has no systemd; `quit_delay_spec.cr` the quit delay with an app
  that holds nothing; `bell_spec.cr` the bell flags, border and sound;
  `banner_spec.cr` banners; `surface_dialogs_spec.cr` the clipboard
  confirmation, the configuration errors dialog (steps run on an idle
  after activation, when the errors show) and the on-screen keyboard.
  `spec/pure/winproto_spec.cr` covers the blur region slices.
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
- `Source` wraps `g_timeout_add_full` and `g_unix_fd_add_full` on the
  default context. The source object itself sits in `Handles`; the destroy
  notify clears its id, so `active?` turns false when GLib drops it (a
  timer that fired, a watch that saw `G_IO_NVAL`) as well as on `cancel`.
  A class-level set (GTK thread only) holds the active sources;
  `Source.cancel_all` runs at shutdown, because the default context
  outlives the run and a later run would dispatch them.
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
- `App` state mutators (`reload`, `css=`, `appearance=`) store and
  `dispatch`, `quit` always posts, and all act only while `running?` (set in startup before the CSS
  and appearance are applied, cleared first thing in shutdown). Stored CSS
  and appearance are applied at startup.
- Startup order: CSS provider (priority `STYLE_PROVIDER_PRIORITY_USER`,
  `parsing-error` → `Log.warn "css parsing failed at <section>: <message>"`),
  appearance, `notify::dark` handler, `on_startup`, first `on_color_scheme`.
  The appearance is applied before the handler connects, so no change is
  reported twice.
- `quit` posts even on the UI thread: called inline from `new_surface`
  (inside `Window#open_tab`) it destroyed the window under the caller, and
  `adw_tab_view_insert` then failed its `ADW_IS_TAB_VIEW` assertion.
- `quit` destroys only `gtk_application_get_windows` (Ghostty: destroying
  every toplevel double-frees fcitx windows), then `g_application_quit`.
- Quit delay, after Ghostty's `quit-after-last-window-closed(-delay)`: a
  nonzero `quit_delay` (or `nil`) holds the GApplication (`@holding`), so
  it outlives its last window. Unregistering the last window after
  activation starts an `Idle.after` timer that quits; opening a window
  and shutdown cancel it. `nil` never starts one. Zero releases the hold
  and GApplication quits once idle without windows, as before.
- `@ready` turns true after the first `on_activate` returns: the systemd
  `READY=1`, the quit timer and the configuration errors dialog wait for
  it, so errors set during activation show over its window.
- `run` passes GApplication only the program name: without `HANDLES_OPEN`
  it rejects file arguments. Signals are trapped with `Signal#trap` (the
  handlers run on a default-context fiber and post) and reset after the run.
- `Systemd` speaks `sd_notify` over an `AF_UNIX` datagram socket; `@` in
  `NOTIFY_SOCKET` is an abstract address. `MONOTONIC_USEC` comes from
  `CLOCK_MONOTONIC` (Crystal's monotonic clock is `CLOCK_BOOTTIME`).
  `READY=1` follows the first activation; reloads send `RELOADING=1` then
  `READY=1`; shutdown sends `STOPPING=1`.
- `reload_now` runs `on_reload`, then `Content#reload` of each registered
  surface (`rescue` + `Log.error "content reload"` per content), inside
  `RELOADING=1` … `READY=1`. `Content#reload` is a protected wrapper that
  calls `on_reload` with an implicit receiver: `App` cannot call a
  protected method on a subclass defined outside `Apprt` (the same reason
  as `App#dispatch`).
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
  so it covers application actions too. It names each type with a leading
  `::`: the code expands inside `Action`, where an application module named
  like an `Apprt` type (`Dialogs`, `Window`) would resolve to the runtime's.
  `Action.install(map, scope, &perform)`
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
  get no accelerator; `apply_bindings` hands them to `GlobalShortcuts`
  (see Global shortcuts).
- Sequences get no accelerator either. A private `Keymap` maps full
  trigger lists to actions (first binding wins) and keeps every proper
  prefix; a single trigger that equals a prefix is skipped with a warning.
  `apply_bindings` builds `@binding_keymap` from the sequences only
  (singles stay accelerators); `apply_key_tables` builds one `Keymap` per
  key table with singles too. The ivar is typed explicitly: inferred from
  `Keymap::EMPTY` it widened to `App | Keymap` in subclasses.
  `Binding.parse` splits at a `>` that follows a key and not a `+`.
- Key tables port Ghostty's (`src/input/Binding.zig`, `Surface.zig`), but
  the stack lives per `Window`, next to the pending sequence, rather than
  per surface. `@key_tables` holds `{name, once}`, at most
  `KEY_TABLE_LIMIT` (8). `App#key_match(tables, keys)` tries the tables
  innermost first, then `@binding_keymap`, and returns `{action, table}`,
  `true` for a prefix or nil; a match from a `once` table that is still
  innermost pops it. Table keys pass the capture controller too, so they
  win over accelerators. `@key_state`, an `osd` label in a `GtkOverlay`
  around the tab view, shows the tables and the pending triggers joined
  by ` › ` and hides when both are empty; `Window::STYLE` styles it.
- Each `Window` adds a capture-phase `GtkEventControllerKey`
  (`@sequence_keys`) first, so it sees keys before the focus widget.
  `sequence_key` returns false at once while nothing is pending, no key
  table is active and the app has no sequences, skips modifier keys, and tries the trigger with
  the held mods, then without the consumed mods (`shift+>` arrives as
  `>` with Shift). A completed sequence clears `@sequence` and performs
  through `App#perform_in(window, action)`, which resolves the target by
  scope like global bindings do; a prefix extends `@sequence`; any other
  key while pending clears it and is consumed. There is no timeout.
  GTK prepends event controllers and runs them in list order, so the
  window's controller, added after GTK's capture-phase
  `gtk-application-shortcuts` controller, sees keys first; the specs
  emit `key-pressed` directly and do not cover this.
- `Trigger.new?` (protected) returns nil where `.new` raises.
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
  on an idle once no page is left and the overview is closed (unless it
  closed meanwhile: the idle must not touch a destroyed tab view);
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
  callback closure lives in `Handles`. `Dialogs.confirm` and
  `Dialogs.prompt` answer with `cancel`/`ok`; `confirm_close` and
  `prompt_title` build on them. The prompt's entry is the alert's extra
  child and activates the default response.
- `CommandPalette` (after Ghostty's `command_palette.zig`) is an
  `AdwDialog` with a `GtkSearchEntry` over a browse-mode `GtkListBox`, one
  row per command in `App#commands` order, so a row's index is its
  command. `search-changed` hides rows whose `Command#matches?` fails and
  selects the first shown; a key controller on the entry moves the
  selection with Up/Down; `activate`, `row-activated` and `stop-search`
  close it (`adw_dialog_force_close`) before performing through
  `perform_in`. Shortcut labels come from the first local binding with the
  same `detailed_name`. `Window#toggle_command_palette` builds a new
  palette each time, so `commands=` needs no sync; `closed` marks it done.
- Bell, after Ghostty's `bell-features`: `Surface#ring_bell` beeps through
  the native `GdkSurface` (`System`) and plays the app's sound (`Audio`)
  even while focused; when the surface lacks the focus it sets
  `bell_ringing?`, reveals the border (`Border`: a crossfading
  `GtkRevealer` overlay, `.surface-bell-border`, without Ghostty's tint)
  and calls `Tab#bell(attention)`, which sets the page's `needs-attention`
  unless selected (`Attention`) and retitles the tab (`🔔 ` before `🔍 `,
  `Title`). `App#play_bell_sound` keeps one `GtkMediaFile` per path,
  seeks to 0 and plays; its `error` is logged, checked once after
  creation too because a backend may fail inside the constructor. The surface's focus controller
  clears the ring on `enter`; the window clears `needs-attention` when a
  page is selected. `MouseVisibility` sets the content widget's cursor to
  `"none"` and back to `Surface#cursor`.
- Banner (Ghostty's child-exited banner, generic): an `AdwBanner`
  overlay at the pane's bottom; `button-clicked` runs the stored action.
  `show_banner(message)` sets no button label.
- `Dialogs.confirm_clipboard` uses Ghostty's headings and bodies
  (`CLIPBOARD` table per `Clipboard::Request`), Allow (destructive) and
  Deny, and the text in a read-only monospace `GtkTextView`; the parent
  is the surface's window, because a fresh surface's host is unparented
  until its split view rebuilds. Ghostty's blur toggle and "remember"
  choice are left out.
- `Dialogs.config_errors` follows Ghostty's `config_errors_dialog`:
  `ignore` (close response) and `reload`; the app keeps the dialog and
  its text buffer, rewrites the buffer when the errors change and closes
  the dialog when they clear. Without a window the dialog has no parent.
- Specs: layout and drawing wait for the frame clock, so layout assertions
  poll with `eventually`. A rebuild replaces every `GtkPaned`, so specs
  look panes up again after each split. Dialogs are answered by setting
  the close response to the wanted id and calling
  `adw_dialog_force_close`.

## Canvas

Internals of `canvas.cr` and `input.cr`, ported from Ghostty's
`src/apprt/gtk/class/surface.zig`:
- No `GtkGLArea`: its integer scale factor gives a framebuffer twice the
  logical size at 1.5 and it hides buffer reuse and frame timings. The
  widget is a `GtkOverlay` (focusable, focus on click, expanding, the
  controllers) around a `GtkDrawingArea` (`resize` stores the logical
  size and queues a render) with a `GtkPicture` overlay (`can-target`
  off, `can-shrink`, `ContentFit::Fill`, css `canvas-frame`, flipped by
  `Surface::STYLE`'s `transform: scaleY(-1)`: GL rows start at the
  bottom) that shows each frame as a `GdkGLTexture`.
- Realize creates a `GLContext` (`gdk_display_create_gl_context`, shared
  with GTK's own) and a `CanvasBuffers` pool (`gl.cr`), sets the input
  method's client widget and watches the native `GdkSurface`'s
  `notify::scale`; a GL error goes to `#error` and
  `Log.error "GL context: …"`. Unrealize stops ticking, clears the
  paintable and runs `#on_unrealize` and the pool's `release` with the
  context current.
- `#scale` is `gdk_surface_get_scale`; the frame is the logical size
  times it, rounded. `queue_render` sets a flag and adds one
  `gtk_widget_add_tick_callback`; `tick` renders (on_resize on a size
  change, `acquire`, `on_render`, `texture`, `gtk_picture_set_paintable`)
  and keeps ticking until every drawn frame's `GdkFrameTimings` is
  complete, reporting each through `on_presented`. Presentation times are
  GDK's `CLOCK_MONOTONIC` microseconds, 0 → `nil`.
- `CanvasBuffers` (`:nodoc:`): textures (RGBA8, nearest) with their own
  framebuffers and one shared `DEPTH24_STENCIL8` renderbuffer, all
  recreated when the size changes. `acquire` takes the free buffer drawn
  most recently (age = frames since then, 0 when new); a buffer is busy
  until GTK drops its texture (`GDestroyNotify` → `Handles` →
  `UIThread.dispatch`). `texture` adds a fence (GL 3.2 / GLES 3.0, via
  `epoxy_gl_version`) and builds the texture as
  `R8g8b8a8Premultiplied`. A buffer GTK still holds at `release` is
  orphaned and deleted with its own context current once dropped.
- `GL` (`:nodoc:`) calls GL through libepoxy's `epoxy_gl*` function
  pointers (`$` globals), the dispatch GTK uses; `Proc#call` does not
  autocast literals, so arguments carry their exact types (`0_u32`).
- `spec/gtk/canvas_render_spec.cr` checks the orientation from a `grim`
  shot of the headless output (red top, blue bottom), buffer ages,
  frame timings, a fractional output (`swaymsg output HEADLESS-1 scale
  1.5` on the harness's sway socket) and `GLContext`.
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
  below 0x20 and DEL excluded). `unshifted`, `shifted` and `base` come
  from one `gdk_display_map_keycode` call: levels 0 and 1 at the event's
  layout, level 0 of layout 0. `repeat?` is a press of a keycode in
  `@held_keycodes` (GTK has no repeat flag); releases remove it and a
  focus change clears the set. `caps_lock?`/`num_lock?` read the event's
  device (`gdk_device_get_*_lock_state`): GDK 4 has no lock masks in its
  state. Events emitted without a current GdkEvent (specs) take the
  lowercased keyval as `unshifted`/`base`. Modifier keys
  adjust `mods` for themselves (`MODIFIER_KEYS`). When `#on_key` uses a key
  during a composition the context is reset and `#on_preedit(nil)` sent.
- `KeyEvent#key` is `Key.from_keycode`: on Linux an X11/XKB keycode is the
  evdev code plus 8, and `Key`'s values are evdev codes, so the table needs
  no lookup.
- `Mods.from_gdk`/`#to_gdk` (`:nodoc:`, `types.cr`) map GDK modifier
  masks; the table is module-level `MODS_GDK` because an enum body cannot
  hold a constant.
- `ShowOnScreenKeyboard` calls `Surface#show_on_screen_keyboard`, which
  asks the protected `Content#show_on_screen_keyboard` (false by
  default); `Canvas` returns `gtk_im_context_activate_osk(@im_context, nil)`,
  true when GTK passed the request to the platform.
- Pointer positions and precise scroll deltas are multiplied by `#scale`.
  `precise?` is `gtk_event_controller_scroll_get_unit == SURFACE`.
- `Clipboard.read` keeps the block in `Handles` until
  `gdk_clipboard_read_text_finish`; a read error logs a warning and yields
  `nil`.
- `Clipboard.write(items)` sets a `gdk_content_provider_new_union` of one
  `new_for_bytes` provider per item and keeps a copy of the items for
  `.items`, which forgets them once `gdk_clipboard_is_local` turns false.
  `.read(mime_type)` takes the `GInputStream` of `gdk_clipboard_read_async`
  to `Stream.read_all`.
- `input_purpose` sets the `GtkIMMulticontext`'s `input-purpose`
  property through a `GValue` (no setter function); the enum's GType
  comes from `g_type_from_name("GtkInputPurpose")`, as GIR lists no
  `get_type` for it.
- Drops: a `GtkDropTargetAsync` on the GL area. `accept` takes part only
  with MIME types and `on_drop_accept`, so surface moves (a `uint64`
  `GValue`, no MIME types) and refused drags bubble to the surface host's
  targets. One `Drop` (`Wrapper` of the `GdkDrop`) per drag, made on its
  first signal; `drag-enter`/`drag-motion` call `on_drop_motion` and
  answer its first allowed action of Copy, Move, Link.
- Drags: `Canvas#drag` calls `gdk_drag_begin` with the default seat's
  pointer at the last pointer position (press or motion), translated to
  the native and its surface transform. `DragContent` registers
  `ApprtDragContent` (`GdkContentProvider` subclass, `g_type_register_static_simple`
  with the parent's sizes from `g_type_query`); its class init writes
  `ref_formats`, `write_mime_type_async` and `write_mime_type_finish`
  at slots 3, 5 and 6 after the `GObjectClass` fields. The `Source`
  (types and handler) sits in the provider's object data, not the `Drag`:
  the `GdkDrag` holds the provider, so a `Drag` there would never be
  collected. Each write makes a `GTask` and a `Drag::Request`; `reply`
  writes with `g_output_stream_write_all_async`, `fail` returns a
  `GError`. GIO's callback arrives as a bare pointer: rebuilt with a null
  closure, or Crystal refuses to pass it on. `dnd-finished` and `cancel`
  call `gdk_drag_drop_done` and `on_drag_end` once.
- A local read of a failed request yields empty data, not an error: GDK
  pipes local reads and only sees the closed stream. The drag content
  spec reads it through the clipboard, as headless sway has no pointer to
  drag with; the drop hooks have no spec (a `GdkDrop` comes only from a
  real drag).
- Specs drive the controllers by emitting their signals
  (`g_signal_emit_by_name` on `canvas.@key_controller` and friends), so
  they need no input devices.

## Notifications

Internals of `notifications.cr`, ported from Ghostty's
`src/apprt/gtk/desktop_notifications.zig` and
`Surface.sendDesktopNotification`:
- Each `Surface` owns a `Notifications`. A notification's GIO id is
  `apprt-surface-<surface id>-<key>` in hex, the key being
  `{title, body}.hash`, so the same text replaces the earlier one;
  `App#notify` uses `apprt-<key>`. The default action is
  `app.present-surface(uint64 id)`; `App#notify` sends id 0, which no
  surface has.
- At most `LIMIT` (64) are kept per surface; more withdraw the oldest. One
  sent while focused is withdrawn after `#timeout` (`FOCUSED_TIMEOUT`, 3 s)
  through `Idle.after`. `Surface#focus_changed(true)` and `#release` call
  `#clear`. A null application pointer skips GIO, which the pure specs use.
- The title falls back to `Window.default_title`; the icon is a themed icon
  named after the application id.
- `FakeNotifications.serve(app) { |fake| }` exports
  `org.freedesktop.Notifications` on the app's own bus connection
  (`RequestName` with `DO_NOT_QUEUE` must return 1), records `Notify` and
  `CloseNotification` calls, and `#click(id)` emits `ActionInvoked`.
- GIO's freedesktop backend (GLib 2.84.4, unfixed on main) watches
  `org.freedesktop.Notifications`; its `name_vanished_handler_cb` frees the
  notification list before clearing it. Once the GApplication is gone, only
  the remaining notifications keep the backend alive, so the last unref
  disposes it, dispose frees the same list again and the recursion
  overflows the stack. The vanish is an idle on the default main context,
  so a later run in the same process dispatches it. `serve` therefore
  settles before closing the windows, again before stopping and once more
  after stopping, while the app still holds its backend; that also keeps
  the withdrawals of one example's quit out of the next example's fake.

## IPC

- `IPC.send` validates the id with `g_application_id_is_valid`, opens the
  session bus with `g_bus_get_sync` and calls `org.gtk.Actions.Activate`
  `(sava{sv})` (action name, `[to_variant]` or `[]`, empty platform data)
  on GApplication's object path: `/` plus the id with `.` → `/` and `-` →
  `_`, as in Ghostty's `src/apprt/gtk/ipc/DBus.zig`. The `ipc: true` check
  is the macro's `:nodoc:` `IPC` constant, read at compile time.
- GApplication exports every `app` action; refusing non-ipc actions on the
  receiving side would need a GDBus filter, which runs on GDBus's worker
  thread. The call is synchronous, so a send to the application's own GTK
  thread waits for the timeout; `ipc_spec.cr` sends from an `Isolated`
  thread and polls a channel from the GTK thread.

## D-Bus

- `DBus` is a `Wrapper` of a `GDBusConnection`; `.session`/`.system` are
  `g_bus_get_sync` (GIO's shared singletons), `App#dbus` is
  `g_application_get_dbus_connection` via `from_raw?`.
- `#call` retains a `Reply` (bus + block) in `Handles`; GIO runs the
  callback on the thread-default main context of the caller, so calls and
  subscriptions belong on the GTK thread. Subscriptions release their
  block through `Handles::RELEASE` when GDBus drops the handler.
- Non-tuple arguments raise before GIO's own `g_return_if_fail`.
- `spec/gtk/dbus_spec.cr` calls the private bus daemon itself
  (`ListNames`, `GetNameOwner`, an unowned name with `auto_start: false`)
  and loops a signal back to its own subscription.

## Global shortcuts

Ported from Ghostty's `src/apprt/gtk/class/global_shortcuts.zig` and
`src/apprt/gtk/portal.zig`:
- `Portal.request_path(unique_name, token)` predicts the request object
  path (`/org/freedesktop/portal/desktop/request/<unique name without ':',
  '.' → '_'>/<token>`); `Portal::Request` subscribes to its `Response`
  before the async call, so no response is missed. Response 0 is success,
  1 cancelled, 2 ended; a call error or another code reaches the callback
  as a message. Tokens are `apprt_<16 hex>`.
- `App#run` sends `org.freedesktop.host.portal.Registry.Register(app id)`
  (`NO_AUTO_START`, errors ignored) on the shared session connection before
  `g_application_run`: the registry accepts it only before any other portal
  call on the connection, and GTK calls the settings portal during startup.
  Host apps outside Flatpak and systemd app scopes need it for the portal
  to know their id (Ghostty relies on its systemd scope instead).
- `GlobalShortcuts` lives from startup to shutdown on GApplication's bus
  connection. `#bind` closes the previous session (`Session.Close`, async,
  unsubscribe `Activated`), maps `Trigger#to_xdg` → first global binding,
  then `CreateSession` → subscribe `Activated` (arg0 = session handle,
  `MATCH_ARG0_PATH`) → `BindShortcuts` with `description` = the detailed
  action name and `preferred_trigger` = the id. Ids missing from the
  response's `shortcuts`, or any failed request, go to
  `App#on_binding_failed`. `Activated` performs the action on the target
  of its scope (`perform_global` in `binding.cr`).
- `FakePortal` serves on its own `Isolated` thread, `GMainContext` and bus
  connection, like the portal process, so it answers while the app under
  test starts and stops. It records `Register`, sessions, closes and
  shortcuts (mutex-guarded), emits `Response` to the caller after
  replying, and `#activate(id)` emits `Activated`. `FakePortal.poll` waits
  without iterating a main loop, for checks after the app stopped.

## Opening URLs

Ported from Ghostty's `src/apprt/gtk/portal/OpenURI.zig`, `openUrl` in
`src/apprt/gtk/class/application.zig` and `src/os/open.zig`:
- `App#perform(App, OpenUrl)` creates one `OpenURI` on GApplication's bus
  connection; `release_open_uri` at shutdown cancels its pending requests.
- Paths and `file://` URLs go straight to `xdg-open` (the portal's
  `OpenURI` refuses them). Others call `org.freedesktop.portal.OpenURI.OpenURI`
  `(ssa{sv})` with parent window `""` and options `handle_token`,
  `writable=false`, `ask=false` and `activation_token`, the startup notify
  id of GDK's app launch context (the XDG activation token on Wayland), so
  the opened app can take the focus.
- Response 1 (`Portal::CANCELLED`) opens nothing; any other failure, call
  errors included, runs `xdg-open`. `OpenURI.xdg_open` spawns it as a
  `GSubprocess` (stdout silenced, stderr piped) and logs the error output
  from `g_subprocess_communicate_utf8_async` on failure. GIO reaps the
  child itself, so the wait still ends when an application resets
  `SIGCHLD` to `SIG_DFL`, as asekii does; Crystal's `Process#wait` would
  hang there.
- Ghostty's 30-second cleanup timer, which also falls back to `xdg-open`,
  is left out: it would open the URL twice while the portal still waits
  on the user's choice of app.
- `Portal::Request#call` ignores the reply's request path: since
  xdg-desktop-portal 0.9 it is always the predicted one, which Ghostty
  re-subscribes to only for older portals.

## Toasts

`Window#toast` adds an `AdwToast` (timeout in whole seconds, rounded up)
to the `AdwToastOverlay` that wraps the tab view as the toolbar view's
content, as in Ghostty's `class/window.zig`.

## Drag and drop

Ported from Ghostty's `class/surface.zig` and `moveSplit` in
`class/split_tree.zig`:
- The surface host holds a `GtkOverlay`: the content, a drag handle
  (`GtkCenterBox`, css `surface-drag-handle`, cursor `grab`, top aligned,
  visible only while the tab is split) and a drop indicator box (css
  `surface-drop-indicator`, `can-target` off). `Surface::STYLE`
  (`:nodoc:`) is loaded by `App` into a provider at
  `STYLE_PROVIDER_PRIORITY_APPLICATION` (`@runtime_style`; `@style`
  collided with a spec subclass ivar).
- The handle's `GtkDragSource` (move) carries the surface id as a `uint64`
  `GValue`; the drag icon is a `GtkWidgetPaintable` of the host scaled to
  0.2.
- Two drop targets on the host: `uint64` (move) rejects the surface's own
  id on `notify::value`, marks the nearest side on `motion` (`drop-left`
  …, ties left, right, up, down; `Surface.drop_side`, 0.5 for an
  unallocated widget) and calls `Tab#insert`; the data target takes
  `GdkFileList`, `GFile` and `G_TYPE_STRING` and calls `Content#drop`
  (protected, implicit-receiver call of `on_drop`, like `reload`).
- `Tab#insert(surface, target, direction)` splits *target* with *surface*;
  within one tab it removes the old handle afterwards, from another tab it
  first `detach`es the surface there (`release_widgets: true` unparents
  the source view's widgets at once, so GTK accepts the host in the new
  parent). `detach` of the last surface closes the source tab without
  releasing the moved surface. `Tab#remove` is `detach` + `release`.

## Window protocol extras

Ported from Ghostty's `winproto/wayland.zig` and `winproto/wayland/`;
Wayland only (no X11):
- No generated protocol code: `Wayland::PROTOCOL` describes the used
  interfaces (`wl_registry`, `wl_compositor`, `wl_region`,
  `xdg_activation_v1`/`_token_v1`, `ext_background_effect_manager_v1`/
  `surface_v1`, `org_kde_kwin_server_decoration_manager`/`_decoration`,
  `ext_idle_notifier_v1`/`ext_idle_notification_v1`)
  and builds `Wl::Interface` tables once. Requests go through
  `wl_proxy_marshal_array_flags`; events through
  `wl_proxy_add_dispatcher`, whose first callback argument is the
  dispatcher data (the listener handle in `Handles`).
- `Wayland.globals(display)` binds the extension globals once per
  `GdkWaylandDisplay` on a private queue (two roundtrips: globals, then
  their initial events such as `capabilities` and `default_mode`), then
  moves the proxies to the default queue that GTK dispatches.
- `Winproto.attach` on `realize` creates the decoration object and, below
  GTK 4.23.3 (`GTK_BACKGROUND_EFFECT`; later GTK binds the effect itself),
  the background effect; `unrealize` releases them. Decoration modes
  follow Ghostty: `Auto` → `default_mode` or client; `Server` is
  client-side when the KDE manager is missing; `None` undecorated.
  `Window#decoration=` sets `gtk_window_set_decorated` and requests the
  mode. `ToggleWindowDecorations` toggles `None` and the previous choice.
- Blur: region = surface size minus GTK's shadow
  (`gtk_native_get_surface_transform`, +1 px with CSD), rounded corners
  of `CORNER_RADIUS` 15 unless fullscreen, maximized or tiled, as rows
  of one pixel (`Winproto.slices`). Resynced on the GdkSurface's `layout`
  and `notify::state`; only sent when the slices change.
- Urgency: `Window#urgent=` is ignored while active; it creates an
  activation token for the surface and activates it on `done`.
  `notify::is-active` clears it; `Surface#ring_bell` on an unfocused
  surface sets it. Headless sway has no keyboard, so windows never become
  active in the specs.

## Window state

- `Window#fullscreen=`/`#maximized=`/`#resizable=` wrap the
  `GtkWindow` calls; the toggle actions and `resize` reuse them.
- `app_id=` validates with `g_application_id_is_valid` and is applied on
  `realize` (and when set while realized) through
  `gdk_wayland_toplevel_set_application_id`; `nil` sends the
  GApplication's id. Non-Wayland surfaces are skipped.
- `idle_inhibited=` holds a `gtk_application_inhibit(Idle)` cookie,
  released on `destroy`. `shortcuts_inhibited=` calls
  `gdk_toplevel_inhibit_system_shortcuts(surface, nil)` /
  `restore_system_shortcuts`, reapplied on `realize`.
- `activate(token)` is `gtk_window_set_startup_id` + `present`, which GDK
  turns into `xdg_activation_v1.activate` on Wayland.
- `suspended?` follows `GDK_TOPLEVEL_STATE_SUSPENDED` on the surface's
  `notify::state`; changes reach `App#on_window_suspended` through the
  protected `App#window_suspended` (implicit-receiver call, as `reload`).
- User idle (`user_idle.cr`): `ext_idle_notifier_v1` version 1 (honours
  idle inhibitors) is bound with the other globals;
  `get_idle_notification(timeout ms, wl_seat)` on the default seat
  (`gdk_wayland_seat_get_wl_seat`), `idled`/`resumed` → `on_user_idle`.
  `idle_timeout=` recreates the notification (store + dispatch while
  running), startup creates it, shutdown destroys it and reports the user
  back. Headless sway has no input, so the spec turns idle at once.

## Window style

After Ghostty's split header bars (`surface.blp`) and
`unfocused-split-opacity`:
- `App#window_style=` stores and dispatches `apply_window_style`, which
  reloads the runtime provider (`@runtime_style`, application priority)
  with `Surface::STYLE + Window::STYLE + WindowStyle#to_css` and calls `apply_style` on
  each window and surface. New windows and surfaces apply it in their
  initializers. Startup loads the provider through `load_runtime_style`.
- `WindowStyle#to_css` writes rules only for options that differ from
  the default, scoped to `window.apprt-window` (the class every `Window`
  carries): `opacity` turns the window, header bar and tab bar
  backgrounds translucent; `cards` gives `.surface` margins, a radius and
  a border and clears the paned separator; `unfocused_opacity` dims
  `.surface:not(.active)`.
- Surface host: `AdwBin` (`.surface`, overflow hidden so the radius clips
  the content) > vertical box > header (`.surface-header`: icon, ellipsized
  title, four flat unfocusable buttons from `HEADER_BUTTONS`) and the
  content overlay. Header visibility follows `pane_headers`. A click on
  the header focuses the surface; buttons dispatch their action on the
  surface through `App#dispatch`. Surface titles update the header label.
- `Tab` sets its active surface through a private `active=` that moves
  the `active` CSS class; `sync_title` also sets the page icon
  (`g_themed_icon_new(Surface#icon)`, or none).
- `Window` keeps `@header`, `@title_box` (the header title widget: window
  title, then the tab bar when inside), `@tab_bar` and `@toolbar`.
  `apply_style` moves the tab bar between `@title_box` (expanding,
  autohide off) and the toolbar's top bars, holding a reference across
  the move. `pack_start`/`pack_end` add to `@header`.
- `on_window` runs from `App#open_window`, so it covers `NewWindow`,
  tab drag-out and `MoveTabToNewWindow` too.
- `header_bar: false` sets `reveal-top-bars` off on the toolbar view
  (header bar and tab row) and clears the tab view's `shortcuts`:
  libadwaita's capture-phase tab keys would otherwise take Ctrl+Tab and
  Alt+digits before the content sees them.
- `ToggleBackgroundOpacity` toggles the `opaque` class on the window;
  `Window::STYLE` (`:nodoc:`, loaded after `Surface::STYLE`) restores the
  window and `.surface` backgrounds with one class more specificity than
  `WindowStyle#to_css`. It returns false while the style's opacity is 1.
- `ResetWindowSize` sets the default size to `@initial_size`, which
  `InitialSize` records (800x600 until then). `ToggleVisibility` hides
  every registered window with `gtk_widget_set_visible` (they stay
  registered, tabs intact) and shows them with `present`.
- Read-only is a flag and a badge only (`@read_only_badge`,
  `changes-prevent-symbolic`, `.surface-read-only` in `Surface::STYLE`,
  overlaid top right, `.read-only` on the host): apprt filters no input,
  as Ghostty leaves selection working; content checks `read_only?`.

## Transient scopes

`Systemd.start_scope` ports Ghostty's `os/cgroup.zig` and
`apprt/gtk/cgroup.zig`: `StartTransientUnit(name, "fail", props, [])` on
`org.freedesktop.systemd1` over its own session bus connection
(`g_bus_get_sync`, so it works outside a running `App`) with `PIDs`,
optional `MemoryHigh`, `TasksMax` and `ManagedOOMMemoryPressure=kill`,
then polls `/proc/<pid>/cgroup` every 25 ms until the unified path ends
in the unit name. Ghostty's `pre_exec` wait in the child is left out:
Crystal's `Process` has no hook between fork and exec.

## Undo

- Closing records instead of releasing: `Tab#remove` records a
  `ClosedSurface` (the tab's tree before and after) while the tab keeps
  other surfaces, else a `ClosedTab` (`TabState`: tree, active surface,
  title override; plus window and page position); `Window#forget` records
  one `ClosedWindow` with its tabs in page order and destroys them with
  `keep: true`. Each entry has an `Idle.after(App#undo_timeout)` timer
  that releases its surfaces (`Surface#release`); a zero timeout releases
  at once. Shutdown clears the stack before the registries.
- `Undo` pops the newest entry. A surface goes back with the old tree when
  `SplitTree#same?` (shared node array, same zoom) says the tab's tree is
  still the one left after closing, else it splits right of the active
  surface; a tab whose tab or window is gone goes to the newest open
  window, or a new one. Reopened tabs are built with
  `Tab.new(app, tree, active)` and `Window#add_tab(tab, position)`.
- `Redo` closes the newest reopened object that is still open; recording
  a close outside redo forgets the reopened list.

## Progress

- `Surface#progress=` drives an osd `GtkProgressBar` overlaid at the top
  of the pane (`.surface-progress`, `error`/`paused` classes recolour it
  in `Surface::STYLE`); an indeterminate value pulses every 100 ms through
  `Idle.after` until it changes or the surface is released. The tab sets
  `adw_tab_page_set_loading` while any of its surfaces has progress.
- `App#sync_progress` averages the registered surfaces' values
  (indeterminate counts as 0) and, when the mean changes, emits
  `com.canonical.Unity.LauncherEntry.Update` `(sa{sv})` on GApplication's
  connection from `/com/canonical/unity/launcherentry/apprt`: the app URI
  `application://<id>.desktop`, `progress` and `progress-visible`.

## Live tests

`test/` is a separate shard, `apprt-test`, that runs apprt with real
keyboard input through `livetest` (`../../livetest` via
`test/shard.override.yml`): key sequences, key tables and progress in a
nested sway or on the user's KDE Plasma desktop, and what only a real
desktop can show (the global shortcuts portal, kglobalaccel, taskbar
progress) on KDE only. See `test/README.md` and `test/AGENTS.md`.
`make -C test test MODE=sway` is safe; never run `make -C test test`
(mode `kde`) or `make -C test setup` unasked: mode `kde` takes over the
keyboard and the pointer, and setup waits for the user to confirm KDE's
shortcut dialog.

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
