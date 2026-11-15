# AGENTS.md

apprt: native application runtime for Crystal on Linux, ported from Ghostty's
`src/apprt` (GTK 4 + libadwaita). Generic: no terminal, pty or renderer
code. Plan: `.claude/golden-orbiting-key.md`. Most components port a Ghostty
file of the same role (`src/apprt/gtk/class/*.zig`); read it for intent.

## Commands

```sh
make spec      # crystal spec --threads 2 (what `dev repo ship` runs)
make spec-pure # spec/pure only: no display, no bus
make spec-gtk  # spec/gtk only
make gen       # regenerate src/apprt/c/*.cr from GIR + data/gir/ allowlists
make examples  # build examples/*.cr into bin/
make docs      # crystal docs src/apprt.cr -o docs
make format    # crystal tool format src spec tools examples
make clean
```

- GTK specs need `sway`, `dbus-daemon`, a GPU driver with EGL (Mesa).
- One Crystal compile at a time, `--threads 2`. Sandboxed:
  `CRYSTAL_CACHE_DIR=.dev/cache`.

## Layout

- `src/apprt.cr` - entry; defines `Apprt::Log` (`:nodoc:`, source `"apprt"`).
- `src/apprt/c/` - `Apprt::C` (`:nodoc:`) bindings. `glib gobject gio gdk
  gdkwayland gtk adw gtk4layershell` `.cr` are generated: never edit. `manual.cr`: what the
  generator can't emit (`GValue` union, GIR constants, `TYPE_*`,
  `gdk_file_list_get_type`, introspectable="0"). `wayland.cr`: `Apprt::Wl`,
  hand-written libwayland-client funs.
- `src/apprt/glib/` - GLib/GObject layer (`Handles`, `Wrapper`, `Signals`,
  `Idle`, `Stream`, `Native`, `Variant`, `Widget`, `GLibError`).
- `src/apprt/core/` - `App`, `UIThread`, `Source`, `Systemd`, value types,
  `Icon`/`GIcon`.
- `src/apprt/actions/` - `Apprt.action`, built-in table (`actions.cr`),
  `Trigger`, `Binding`.
- `src/apprt/window/` - `Window`, `Tab`, `Surface`, `SplitTree`, `SplitView`,
  style, undo. Reopenings: `window_keys.cr` (sequence controller, key
  tables), `window_actions.cr` (toggles + window overloads),
  `surface_drop.cr`, `surface_overlays.cr`, `surface_actions.cr` (surface
  and split overloads). `panel.cr`: `Panel` + reopens `Window`/`App`.
- `src/apprt/ui/` - `Dialogs` (all alert dialogs), bell, config errors,
  command palette, preferences, progress (`LauncherEntry`), search overlay.
- `src/apprt/content/` - `Content`, `Canvas` (+ `canvas_input.cr`), `gl.cr`
  (`GLContext`, `GL`, `Dmabuf`, `CanvasBuffers`), input events, `Key`, drag,
  clipboard.
- `src/apprt/desktop/` - notifications, IPC, portal, global shortcuts,
  OpenURI, DBus.
- `src/apprt/wayland/` - protocol tables/globals, `Winproto`, `user_idle.cr`.
- `examples/` - declare own `lib LibGtk`/`lib LibGL` funs, not `:nodoc:`
  `Apprt::C`. Content naming its surface (`workspace.cr`, `snake.cr`) does it
  in a block posted from `new_surface`: `Content#surface` is set only after
  `new_surface` returns.
- `tools/gen_gir.cr` CLI, `tools/gir/generator.cr` (`GirGenerator`);
  `data/gir/<Namespace-Version>.txt` allowlists.

## Specs

- `spec/gtk/<group>/<name>_spec.cr` mirrors `src/apprt/<group>/<name>.cr`;
  same for `spec/pure/<group>/`. Glib layer, bindings, generator and
  `Variant` specs sit at top of `spec/pure/` (fixture
  `spec/data/Fixture-1.0.gir` + `.txt`; bindings check every `fun` resolves
  via `dlsym`). `with_notify_socket` in `spec/spec_helper.cr`.
- `spec/gtk/harness.cr` (`GtkHarness.start` in `before_all`):
  - Private headless `sway` (`WLR_BACKENDS=headless`, `WLR_RENDERER=pixman`,
    one 1280x800 output, scale 1, floating, no Xwayland) + `dbus-daemon` in
    a temp `XDG_RUNTIME_DIR`; sets `GDK_BACKEND=wayland`, `WAYLAND_DISPLAY`,
    `DBUS_SESSION_BUS_ADDRESS`, `XDG_CONFIG_HOME`,
    `GSETTINGS_BACKEND=memory`: never touches the user's session.
    `Spec.after_suite` stops both.
  - Real compositor, not broadway: `GtkGLArea`/canvas need GL, and one
    process gets one GDK backend.
  - `LC_ALL=C.UTF-8`, `LANGUAGE` dropped: `gtk_init` calls `setlocale`, and
    translated accelerator labels leaked into later pure trigger specs.
  - `GSK_RENDERER=ngl`, `GDK_DISABLE=vulkan`,
    `GNOTIFICATION_BACKEND=freedesktop` (to the fake server).
  - `GTK_MEDIA=none`: GStreamer's GL display outlives the stream and floods
    "Failed to flush Wayland connection" after sway stops; bell sounds
    therefore fail and only the warning is checked.
  - Bus from generated `bus.conf`, no service dirs: unowned names (portal,
    a11y bus) fail `ServiceUnknown` instead of starting host services.
  - Helpers: `TestApp` (`make_content`, `GtkEntry` default; `new_surface`
    records contexts), `AppIds`, `run_app`, `run_steps`, `settle`,
    `eventually`, `trigger`.
- Fakes: `spec/gtk/fake_notifications.cr` (`FakeNotifications`),
  `spec/gtk/fake_portal.cr` (`FakePortal`); `open_url_spec.cr` also puts a
  fake `xdg-open` first on `PATH`.
- Test apps hold the GApplication in `on_startup`, else it quits once idle.
- Specs drive controllers by emitting their signals
  (`g_signal_emit_by_name`, e.g. `canvas.@key_controller`,
  `@sequence_keys`): no input devices. Headless sway has no keyboard or
  pointer: windows never become active, no real drags (drop hooks
  unspecced), user idle fires at once.
- Layout/drawing wait for the frame clock: poll with `eventually`. A split
  view rebuild replaces every `GtkPaned`: look panes up again. Answer dialogs
  by setting the close response and calling `adw_dialog_force_close`.
- `spec/gtk/content/canvas_render_spec.cr` checks orientation from a `grim`
  shot (red top, blue bottom). Its fractional case adds a second output
  (`swaymsg create_output`, scale 1.5, focused) and unplugs it: GDK 4.18
  never lowers a monitor's scale, so rescaling `HEADLESS-1` broke every
  later spec.
- `spec/gtk/desktop/dbus_spec.cr` talks to the private bus daemon itself;
  `spec/gtk/ui/overlays_spec.cr`, `spec/gtk/ui/preferences_spec.cr` (rows
  found by GType name); `spec/pure/wayland/winproto_spec.cr` (blur slices).
- `Variant`-macro payload enums must not be file-private in specs: the
  expansion can't see them.

## GLib layer

- `Handles.retain(value) : Void*` / `get(data, T)` / `release`;
  `Handles::RELEASE` (`GDestroyNotify`), `RELEASE_CLOSURE`
  (`GClosureNotify`). `Sync::Exclusive` hash: never touch from a finalizer
  (Boehm runs them inside allocations, any thread, lock maybe held).
- `Wrapper`: owns one ref; `take` adopts, `from_raw` refs borrowed, `?`
  variants map null. Built via `allocate` + `initialize`, so subclasses may
  define `self.new` overloads. Finalizers never unref GObjects directly:
  `c_release` schedules `g_object_unref` via `g_idle_add_full` (dispose may
  emit into Crystal; GTK objects are GTK-thread). `boxed ref, unref` =
  thread-safe boxed type (GVariant), unreffed in finalizer.
- `Widget`: struct, no ref (GTK tree owns). Owners keep a `Wrapper`.
  Cross-component methods are `protected`.
- `Signals.connect(instance, "sig", ->(a : T, ...) : R { })`; params = signal
  args after instance; restriction picks conversion:

  | Restriction                     | C argument  | Conversion                 |
  |---------------------------------|-------------|----------------------------|
  | `Bool`                          | `gboolean`  | `!= 0`                     |
  | `String`, `String?`             | `gchar*`    | copy; null → `nil`         |
  | `Int32` ... `Float64`, `Void*`  | same        | none                       |
  | enum                            | `gint`      | `from_value`               |
  | `Widget`, `Widget?`             | `GtkWidget*`| borrowed handle            |
  | `Wrapper` subclass (or `?`)     | `GObject*`  | `from_raw` (new reference) |

  Results `Nil`, `Bool`, `Int32`. Exceptions logged, zero result. Proc
  released when GObject drops the handler. `Signals.notify` watches a
  property.
- `Source`: destroy notify clears the id, so `active?` tracks GLib dropping
  it. `Source.cancel_all` at shutdown: default context outlives the run and
  a later run would dispatch leftovers.
- `Variant`: types fixed at compile time; enums as snake-case strings;
  `hash` uses type string + printed form (`g_variant_hash` rejects
  containers).

## Runtime core

- Threading: GTK runs on one `Fiber::ExecutionContext::Isolated` thread
  `"gtk"`, new per `App#run`; caller waits. All hooks/GTK calls there. GTK
  and default `GMainContext` survive across runs.
- `UIThread.post`: `Sync::Exclusive` deque + one pending
  `g_idle_add_full(PRIORITY_DEFAULT)` drain (atomic flag, cleared before
  draining). `dispatch` = inline on UI thread, else post. Queue dropped when
  the run ends.
- `App` mutators (`reload`, `css=`, `appearance=`) store + `dispatch`; act
  only while `running?` (set before CSS/appearance in startup, cleared first
  in shutdown).
- Startup order: CSS provider (`STYLE_PROVIDER_PRIORITY_USER`), appearance,
  `notify::dark` handler, `on_startup`, first `on_color_scheme`. Appearance
  before handler: no double report.
- `quit` always posts, even on UI thread: inline from `new_surface` it
  destroyed the window mid-`Window#open_tab` (`ADW_IS_TAB_VIEW` assertion).
  Destroys only `gtk_application_get_windows` (all toplevels double-frees
  fcitx windows).
- Quit delay: nonzero/`nil` `quit_delay` holds the GApplication; last window
  closing after activation starts an `Idle.after` timer (never for `nil`);
  zero releases the hold.
- `@ready` after first `on_activate`: `READY=1`, quit timer and config
  errors dialog wait for it (errors show over the first window).
- `run` passes GApplication only the program name (no `HANDLES_OPEN`: file
  args rejected). Signals via `Signal#trap`, handlers post; reset after run.
- `Systemd`: `@` in `NOTIFY_SOCKET` = abstract address; `MONOTONIC_USEC` from
  `CLOCK_MONOTONIC` (Crystal's monotonic is `CLOCK_BOOTTIME`).
- Protected-call rule: `App` can't call a protected method on a user
  subclass outside `Apprt`, so it calls protected wrappers that invoke the
  hook with implicit receiver (`Content#reload`, `#drop`, `#search*`,
  `#show_on_screen_keyboard`, `App#window_suspended`). Likewise `Window`
  performs via protected `App#dispatch`: user `perform` overloads live in
  the top-level namespace ("protected method 'perform' called for Hello").
- Hooks: `protected` + `# :showdoc:`.

## Actions and bindings

- `Apprt.action` macro: declaration errors (name, scope, ipc outside `:app`,
  fields shadowing `Action` methods, per-scope duplicates) are compile
  errors. `.from_variant` → nil on mismatch incl. unknown enum names.
- `Action.registry` built at compile time from `Action.all_subclasses`;
  names types with leading `::` (else app modules named `Dialogs`/`Window`
  resolve to apprt's).
- Dispatch = overload resolution on `self`: other `Apprt` types must route
  through an `App` method; `perform` on another object sees only base
  overloads. Components reopen `App` with their scope's overloads.
- `win` map on the window; `tab`/`split` groups inserted on the window,
  targeting selected tab / its focused surface, so accels resolve anywhere.
- Accels: `gtk_application_set_accels_for_action` by `detailed_name`;
  previous set cleared. Global bindings → `GlobalShortcuts`, no accel.
- Sequences: no accel; private `Keymap` (first binding wins, every proper
  prefix kept; a single trigger equal to a prefix is skipped with warning).
  `@binding_keymap` typed explicitly: inferred from `Keymap::EMPTY` it
  widened to `App | Keymap` in subclasses. `Binding.parse` splits at a `>`
  after a key, not after `+`.
- Key tables: stack per `Window` (not per surface as Ghostty), max
  `KEY_TABLE_LIMIT` 8; innermost first, then `@binding_keymap`; a `once`
  table pops on match while innermost. `@key_state` osd shows tables +
  pending triggers joined by ` › `.
- `@sequence_keys`: capture-phase controller added first. GTK prepends
  controllers and runs in order, so it beats `gtk-application-shortcuts`
  (uncovered by specs). Fast path: false when nothing pending, no table, no
  sequences. Tries held mods, then without consumed mods (`shift+>` arrives
  as `>`+Shift). Non-matching key while pending: cleared and consumed. No
  timeout.
- `Trigger`: keyval lowercased; valid = `gtk_accelerator_valid` + name round
  trip (emoji have no accelerator). `Trigger.new?` protected.

## Split tree

`SplitTree(V)` ports `src/datastruct/split_tree.zig`.

- Immutable; trees share node arrays (never mutated). `ratio` `Float64`
  (Ghostty `f16`); `with_ratio` replaces in-place `resizeInPlace`.
- Handles (`Int32`) valid for one tree. `split` keeps existing handles
  except the view at `at` (moved to end); `remove` renumbers: re-`locate`.
  Zoom resets on split, follows its node on remove.
- `goto(Direction)`: nearest fully-on-side slot (Euclidean between origins,
  ties lowest handle), wrap by shifting past opposite edge.
- `resize` delta is a fraction of the whole tree.
- `to_diagram` rounds edges (Ghostty floors): differs only where `f16`
  ratios differ.

## Windows, tabs, surfaces

- GTK owns widgets; objects hold borrowed `Widget`s. `App` registries
  `@windows`, `@tabs` (by root `AdwBin` pointer; `tab_for`), `@surfaces`;
  cleared at shutdown.
- `notify::n-pages` closes an empty window on an idle, skipping if the
  window already closed (idle must not touch a destroyed tab view).
- Surface host `AdwBin` held with `g_object_ref_sink`: survives rebuilds
  unparented; `release` drops it.
- `SplitView` rebuild (one idle per `tree=`): `gtk_root_set_focus(nil)` first
  (`GtkPaned` losing focused child warns "Error finding last focus widget");
  detach divider children first (old panes outlive `adw_bin_set_child(nil)`,
  GTK rejects parented children); refocus once mapped.
- `Divider` settle: `max-position == Int32::MAX` = unallocated; limit change
  applies stored ratio (`size` = `max-position` + end child's minimum);
  user moves write back via `with_ratio` (no rebuild) if Δ ≥ 0.001.
- `ResizeSplit` px → fraction of root width/height, negative left/up.
- `CommandPalette` rebuilt per toggle (no `commands=` sync); closes
  (`adw_dialog_force_close`) before performing.
- Clipboard confirm parent = window, because a fresh surface's host is
  unparented until rebuild. Ghostty's blur toggle/"remember" omitted.
- Bell: sound plays even when focused; `GtkMediaFile` per path; its `error`
  checked once after creation too (backend may fail in the constructor).
- Tab drag-move (`Tab#insert`): other tab → `detach(release_widgets: true)`
  first so GTK accepts the host; detaching the last surface closes the
  source tab without releasing it.
- Canvas drop target accepts only with MIME types and `on_drop_accept`, so
  surface moves (`uint64` `GValue`) and refused drags bubble to the host's
  targets. Header buttons claim clicks: drags start from free header area.
- `Surface::STYLE` provider ivar is `@runtime_style`: `@style` collided with
  a spec subclass ivar.
- `header_bar: false` also clears the tab view's `shortcuts`: libadwaita's
  capture-phase keys would eat Ctrl+Tab/Alt+digits.
- `Window::STYLE` restores opaque backgrounds with one class more
  specificity than `WindowStyle#to_css`.
- Read-only is a flag + badge; apprt filters no input (as Ghostty).
- Preferences rows watch `notify::text`, not `changed` (fires twice on
  `set_text`).
- Toast timeout rounds up to whole seconds.
- Search: `search-changed` is GTK's debounced signal, used as is.

## Undo

- Closing records instead of releasing (`ClosedSurface`, `ClosedTab`,
  `ClosedWindow` with `keep: true`); each entry's `Idle.after(undo_timeout)`
  releases its surfaces; zero releases at once. Shutdown clears the stack
  before registries.
- Undo restores the old tree only if `SplitTree#same?` (shared array, same
  zoom), else splits right of active. Gone tab/window → newest window or new.
  Recording a close outside redo forgets the reopened list.

## Canvas and GL

- No `GtkGLArea`: integer scale (2x buffer at 1.5) and hides buffer reuse
  and frame timings. Frames shown as textures in a `GtkPicture`, flipped by
  CSS `scaleY(-1)` (GL rows start at bottom).
- GL context shared with GTK's. Ticks continue until every drawn frame's
  `GdkFrameTimings` completes. Times are `CLOCK_MONOTONIC` µs, 0 → `nil`.
- `CanvasBuffers`: buffer busy until GTK drops its texture (`GDestroyNotify`
  → `UIThread.dispatch`); one still held at `release` is orphaned and
  deleted with its own context current. Fence needs GL 3.2 / GLES 3.0.
- `GL` calls libepoxy `epoxy_gl*` pointers (`$` globals); `Proc#call`
  doesn't autocast literals: pass exact types (`0_u32`).
- DMA-BUF offload (`offload: true`, `GtkGraphicsOffload`): needs EGL via
  epoxy, `EGL_KHR_gl_texture_2D_image`, `EGL_MESA_image_dma_buf_export`
  (checked in realize). Export once per buffer; close each distinct fd once.
  `GdkDmabufTexture` has no fence (implicit sync). Failure logs
  `canvas DMA-BUF offload off: …` once and falls back to GL textures.
- Controller ivars use `@im_`/`_controller`/`_gesture` names: subclasses
  share the ivar namespace (a subclass `@keys` collided).
- Keys follow Ghostty's `keyEvent`: IM filter first; commit inside filter
  while not composing = `text`. `repeat?` from `@held_keycodes` (GTK has no
  repeat flag). Lock states from the device (GDK 4 state has no lock
  masks). Emitted events without a current GdkEvent: lowercased keyval as
  `unshifted`/`base`. `Key.from_keycode` = XKB keycode − 8 (evdev).
- `MODS_GDK` module-level: enum bodies can't hold constants.
- `input-purpose` set via `GValue` (no setter); GType via
  `g_type_from_name("GtkInputPurpose")` (no `get_type` in GIR).
- Pointer and precise scroll × `#scale`.
- `Clipboard.items` forgotten once `gdk_clipboard_is_local` is false.
- Drags (`DragContent`): `ApprtDragContent` GType via
  `g_type_register_static_simple`, sizes from `g_type_query`; vfuncs at
  class slots 3, 5, 6 after `GObjectClass`. Source data lives on the
  provider, not the `Drag` (else never collected). GIO's bare callback
  pointer rebuilt with a null closure. Local reads of a failed request yield
  empty data, not an error.

## Notifications

- GIO id `apprt-surface-<id>-<hash(title, body)>` (same text replaces);
  `App#notify` uses `apprt-<key>`, present action id 0. `LIMIT` 64 per
  surface; focused ones withdrawn after 3 s. Null app pointer skips GIO
  (pure specs).
- `FakeNotifications.serve` exports on the app's own connection
  (`RequestName` `DO_NOT_QUEUE` must return 1).
- GLib 2.84.4 bug (unfixed on main): freedesktop backend's
  `name_vanished_handler_cb` frees its list before clearing; final unref
  double-frees → stack overflow, and the vanish idle runs in a later run. So
  `serve` settles before closing windows, before and after stopping, while
  the app still holds its backend.

## IPC and D-Bus

- `IPC.send`: `org.gtk.Actions.Activate` `(sava{sv})` on `/` + id (`.`→`/`,
  `-`→`_`). Every `app` action is exported; refusing non-ipc ones would
  need a GDBus filter (worker thread). Synchronous: sending to your own GTK
  thread waits for the timeout (spec sends from an `Isolated` thread).
- `DBus` callbacks run on the caller's thread-default context: call and
  subscribe from the GTK thread. Non-tuple args raise before GIO's
  `g_return_if_fail`.

## Portals: global shortcuts, OpenURI

- `Portal::Request` subscribes to `Response` (predicted path
  `/org/freedesktop/portal/desktop/request/<sender, ':' dropped, '.'→'_'>/<token>`)
  before calling. 0 ok, 1 cancelled, 2 ended. Reply path ignored (always
  predicted since xdg-desktop-portal 0.9).
- `App#run` sends `Registry.Register(app id)` (`NO_AUTO_START`, errors
  ignored) before `g_application_run`: accepted only before any other portal
  call, and GTK calls the settings portal in startup. Needed outside
  Flatpak/systemd app scopes.
- `GlobalShortcuts#bind`: close old session, `CreateSession`, subscribe
  `Activated` (arg0 path match), `BindShortcuts`; missing ids/failures →
  `App#on_binding_failed`.
- `FakePortal` runs on its own `Isolated` thread, context and connection so
  it answers while the app starts/stops; `FakePortal.poll` waits without a
  main loop.
- OpenURI: paths/`file://` go straight to `xdg-open` (portal refuses them).
  Portal call passes the launch context's activation token. Cancel (1)
  opens nothing; any other failure falls back to `xdg-open`. Ghostty's 30 s
  fallback timer omitted (would open twice while the user picks an app).
- `xdg-open` spawn: Crystal's SIGCHLD handler reaps all children
  (`waitpid(-1)`), breaking `GSubprocess` waits ("waitid … No child
  processes"). So check `sigaction`: handler installed → Crystal `Process`
  on a fiber; `SIG_DFL`/`SIG_IGN` (asekii; `Process#wait` would hang) →
  `GSubprocess`.

## Wayland extras

- No generated protocol code: `Wayland::PROTOCOL` tables, requests via
  `wl_proxy_marshal_array_flags`, events via `wl_proxy_add_dispatcher`
  (first callback arg = dispatcher data). Globals bound once per display on
  a private queue (two roundtrips), then moved to GTK's default queue.
- Background effect only below GTK 4.23.3 (`GTK_BACKGROUND_EFFECT`; newer
  GTK binds it). `Server` decoration falls back to client without the KDE
  manager.
- Blur region excludes GTK's shadow (+1 px with CSD); `CORNER_RADIUS` 15
  unless fullscreen/maximized/tiled; sent only when slices change.
- Urgency ignored while active. `app_id=` via
  `gdk_wayland_toplevel_set_application_id` on realize. User idle:
  `ext_idle_notifier_v1` v1 (honours inhibitors).
- Panels (kitty's panel kitten) via gtk4-layer-shell: `Panel.init`
  (`gtk_layer_init_for_window`) before realize, in `Window#initialize`;
  `apply` rewrites namespace, layer, keyboard mode, anchors/margins
  (`ANCHORS`/`SIZED` tables per edge), exclusive zone (edges: auto, else
  -1, explicit value wins) and monitor by connector. Clears libadwaita's
  360x200 minimum size. Header hidden, `@decoration` `None`.
- Link order: gtk4-layer-shell must precede libwayland-client (it
  interposes `wl_*` symbols); `c/wayland.cr` carries a second `@[Link]`
  for it after wayland-client, as Crystal emits later annotations first.
  Wrong order: `gtk_layer_is_supported` false.
- `hide_on_focus_loss` hides on `notify::is-active` false. Undo keeps
  `ClosedWindow#panel`. Specs: sway honours exclusive zones (top 160 →
  left panel 640 tall); content minimum ~126 px high.

## Systemd scopes

`start_scope`: own `g_bus_get_sync` connection (works without a running
`App`), polls `/proc/<pid>/cgroup` every 25 ms. Ghostty's `pre_exec` wait
omitted: Crystal `Process` has no fork/exec hook.

## Live tests

`test/` is a separate shard (`apprt-test`, `livetest` via
`test/shard.override.yml`); see `test/README.md`, `test/AGENTS.md`.
`make -C test test MODE=sway` is safe. Never run `make -C test test` (mode
`kde`) or `make -C test setup` unasked: kde takes over keyboard and pointer;
setup waits for the user to confirm KDE's shortcut dialog.

## Bindings

Add a C symbol: list it in its namespace's allowlist, run `make gen`. Lines
are symbols or type names; `#` comments.

- Listed enums/bitfields → enums (bitfields `@[Flags]`, zero/All dropped);
  callbacks → proc aliases.
- Listed records → structs, must have fields; opaque records, bit fields,
  unions fail: bind in `c/manual.cr`.
- Unlisted records/classes are `Void*`; by-value records must be listed.
- `throws` → trailing `GError**` (`Void**` if `GError` unlisted).
- Symbols must resolve to an allowlisted namespace; GIR includes (Pango,
  Graphene) are types only.
- Listed classes need their `*_get_type`.
- Links from GIR `<package>`; GIR dir: `GIR_DIR`, else pkg-config `girdir`,
  else `/usr/share/gir-1.0`.

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
