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
  alert dialogs behind `Window#confirm`/`#prompt`, the close confirmation
  and the title prompt.
- `src/apprt/content.cr` - `Content` (with the `on_drop` hooks),
  `WidgetContent`, `SurfaceContext` (public).
- `src/apprt/input.cr` - `KeyEvent`, `MouseButton`, `MouseButtonEvent`,
  `MouseMotionEvent`, `ScrollEvent` (public; initializers `:nodoc:`).
- `src/apprt/canvas.cr` - `Canvas` (public): the `GtkGLArea` content, its
  event controllers and input method context.
- `src/apprt/clipboard.cr` - `Clipboard` (public): text clipboards.
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
  server.
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
  `@sequence_keys`;
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
  which has no systemd. `spec/pure/winproto_spec.cr` covers the blur
  region slices.
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
- Sequences get no accelerator either. `apply_bindings` fills
  `@sequences` (full trigger list → action, first binding wins) and
  `@sequence_prefixes` (every proper prefix); a single trigger that equals
  a prefix is skipped with a warning. `Binding.parse` splits at a `>` that
  follows a key and not a `+`.
- Each `Window` adds a capture-phase `GtkEventControllerKey`
  (`@sequence_keys`) first, so it sees keys before the focus widget.
  `sequence_key` returns false at once while nothing is pending and the
  app has no sequences, skips modifier keys, and tries the trigger with
  the held mods, then without the consumed mods (`shift+>` arrives as
  `>` with Shift). A completed sequence clears `@sequence` and performs
  through `App#perform_in(window, action)`, which resolves the target by
  scope like global bindings do; a prefix extends `@sequence`; any other
  key while pending clears it and is consumed. There is no timeout.
  Whether GTK's application accelerators run before the capture phase,
  for a key that is both a sequence's second trigger and an accelerator,
  is not covered: the specs emit `key-pressed` directly.
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
- `KeyEvent#key` is `Key.from_keycode`: on Linux an X11/XKB keycode is the
  evdev code plus 8, and `Key`'s values are evdev codes, so the table needs
  no lookup.
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
  errors included, runs `xdg-open`. `OpenURI.xdg_open` closes its output,
  and a fiber in the default execution context (off the GTK thread) waits
  for it and logs its error output on failure.
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
  `surface_v1`, `org_kde_kwin_server_decoration_manager`/`_decoration`)
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

## Window style

After Ghostty's split header bars (`surface.blp`) and
`unfocused-split-opacity`:
- `App#window_style=` stores and dispatches `apply_window_style`, which
  reloads the runtime provider (`@runtime_style`, application priority)
  with `Surface::STYLE + WindowStyle#to_css` and calls `apply_style` on
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

## Transient scopes

`Systemd.start_scope` ports Ghostty's `os/cgroup.zig` and
`apprt/gtk/cgroup.zig`: `StartTransientUnit(name, "fail", props, [])` on
`org.freedesktop.systemd1` over its own session bus connection
(`g_bus_get_sync`, so it works outside a running `App`) with `PIDs`,
optional `MemoryHigh`, `TasksMax` and `ManagedOOMMemoryPressure=kill`,
then polls `/proc/<pid>/cgroup` every 25 ms until the unified path ends
in the unit name. Ghostty's `pre_exec` wait in the child is left out:
Crystal's `Process` has no hook between fork and exec.

## Live tests

`test/` is a separate shard, `apprt-test`, that runs apprt on the user's
real KDE Plasma desktop through `livetest` (`../../livetest` via
`test/shard.override.yml`), for what only a real desktop can show: the
global shortcuts portal and kglobalaccel. See `test/README.md` and
`test/AGENTS.md`. Never run `make -C test test` or `make -C test setup`
unasked: mode `kde` takes over the keyboard and the pointer, and setup
waits for the user to confirm KDE's shortcut dialog.

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
