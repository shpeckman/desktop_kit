# Plan: `apprt`, a Crystal port of Ghostty's application runtime

## Context

User wants Ghostty's apprt (`/home/spaceman/Downloads/ghostty-main/src/apprt`, Zig) ported to Crystal as a
**generic, reusable native Linux app runtime**: GTK4 + libadwaita, Wayland, systemd and DBus, for any app, not
only terminals. New standalone shard at `/home/spaceman/.lib/crystal/apprt`. It is on branch `dev` and has only an
empty README.md. No shard dependencies. crwin and wpe_webkit are reference only.

User decisions:
- Linux/GTK focus first.
- Milestone 1 covers app lifecycle, windows, surfaces, tabs, splits, global shortcuts, desktop notifications and
  IPC/DBus.
- Bindings: a GIR generator plus hand-written wrappers.
- Widgets: composition, built in code. Stock Adw/GTK widgets, no GType subclassing, no templates, no gresource.

What is dropped from Ghostty: the terminal-specific parts. That covers pty/termio, renderer health, scrollback,
inspector, OSC handling, search overlay, child-exited and cell size. The apprt contract stays the same (App,
Surface, typed actions with a `Target`, async clipboard, NewSurfaceContext, IPC).

## Architecture decisions (validated against Crystal 1.23 stdlib)

- **GTK thread.** Execution contexts are on by default (`src/kernel.cr:585`). The main fiber can move to another
  OS thread after a blocking syscall, so wpe_webkit's manual main loop and main-fiber check do not fit.
  - `App#run` starts `Fiber::ExecutionContext::Isolated.new("gtk") { g_application_run }` and waits. The stdlib
    docs give a GTK example (`fiber/execution_context/isolated.cr:29-37`).
  - Cross-thread work goes through `App#post(&)`: a `Sync::Mutex` guards a `Deque(->)`, with an atomic
    "scheduled" flag and `g_idle_add_full`, which is thread-safe and wakes the context.
  - `UIThread.assert!` guards the public mutators.
  - Callbacks never block. `spawn` from the GTK fiber goes to the default context.
- **Remote instances.** GApplication handles single-instance, `hold`/`release` and quit itself. A second instance
  returns after forwarding.
- **Signals.** `Signal::USR2.trap { post reload }`, plus TERM/INT → quit. Crystal owns the signal handlers, so
  there is no `g_unix_signal_add`.
- **Lifetimes.**
  - GTK owns the widget tree. Components hold a borrowed `struct Widget`: no ref, no finalizer. Boehm finalizers
    can run on any thread.
  - Signal closures live in a `Handles` registry and are released by `RELEASE_CLOSURE` when GObject drops the
    handler.
  - Each component connects `destroy` on its root, which marks it dead and unregisters it.
  - **Exception:** `Surface` holds a real ref on its host widget so it survives reparenting during split rebuilds,
    the same idea as Ghostty's `viewRef`. `Surface#close` is the only way a surface dies.
  - Cross-references use `surface_id : UInt64` through `App`'s registry, not weak refs.
  - Owned `Wrapper` classes are kept for objects that aren't widgets (GVariant, GDBusConnection, GNotification).
    Their `finalize` unrefs directly when the type is thread-safe, otherwise through an idle trampoline.
- **One action table, data-driven.**
  - `Apprt.action Name, "gname", scope:, payload: {...}, ipc:` generates a record, a GVariant signature and
    codec, and a `REGISTRY` entry.
  - That table drives GAction registration (`app.`/`win.`/`tab.`/`split.`), accelerators, the IPC client,
    global-shortcut ids and dispatch.
  - `App#perform(target : App | Surface, action) : Bool` has an overload per built-in. Apps add overloads for
    their own actions; this is the extension point.

## Layout

```
shard.yml  Makefile  README.md  AGENTS.md  LICENSE  .gitignore
data/gir/{GLib-2.0,GObject-2.0,Gio-2.0,Gdk-4.0,Gtk-4.0,Adw-1}.txt   symbol allowlists, one C id per line
tools/gen_gir.cr  tools/gir/generator.cr                          generator (pattern: crwin tools/gen_wayland.cr)
src/apprt.cr                                                      require order: c, glib, types, ui_thread, action, rest
src/apprt/c/{glib,gobject,gio,gdk,gtk,adw}.cr                     generated, checked in, "Do not edit" header
src/apprt/c/manual.cr                                             GValue, *_get_type gaps, typing exceptions
src/apprt/glib/{error,native,handles,wrapper,widget,signals,variant}.cr
src/apprt/{ui_thread,types,action,actions,trigger,keybinds,config}.cr
src/apprt/{app,window,tab,split_tree,split_view,surface,content,canvas,input,key,clipboard,dialogs}.cr
src/apprt/{notifications,dbus,ipc,portal,global_shortcuts,systemd,css}.cr  src/apprt/style.css
spec/{pure,gtk,dbus,wayland}/  spec/data/Fixture-1.0.gir  spec/support/{gtk_helper,fake_portal,fake_notifications}.cr
examples/{hello,canvas,ipc}.cr
```

## Components

1. **GIR generator** (`tools/gen_gir.cr` and `tools/gir/generator.cr`, about 350 lines, `require "xml"`)
   - Allowlist entries:
     - Functions, methods and constructors by `c:identifier`.
     - Enums, bitfields, callbacks and records by `c:type`.
     - A class name emits its `glib:get-type`.
   - Enums and callbacks that listed functions use are pulled in automatically. An unknown id is an error
     reporting file and line.
   - Type map is a constant Hash, with pointer depth taken from `c:type`.
     - Scalars: gboolean→Int32, utf8→UInt8*, GType→alias SizeT.
     - Objects and records become `Void` plus pointer depth.
     - out/inout parameters add a pointer level.
     - Enumerations become `enum : Int32`. Bitfields become `@[Flags] enum : UInt32` with 0-value members
       skipped.
     - Varargs become `...`. Callbacks become Proc aliases.
   - Output: `module Apprt; @[Link(pkg_config: <gir package>)] lib C`, in allowlist order, run through
     `crystal tool format`.
2. **glib layer.** Port the wpe_webkit pattern: `error.cr` (GLibError, `check!`), `native.cr` and `handles.cr`.
   On top of that:
   - `wrapper.cr`: owned objects with a thread-safe flag.
   - `widget.cr`: the borrowed struct.
   - `signals.cr`: a trampoline macro that converts arguments and rescues/logs exceptions.
   - `variant.cr`: Crystal ↔ GVariant for the payload types.
3. **types.cr.** The structs.zig equivalents:
   - geometry and colors: `ContentScale`, `SurfaceSize`, `CursorPos`, `IMEPos`, `ColorScheme`
   - clipboard: `Clipboard` (standard|primary), `ClipboardContent`
   - input: `Mods`, `KeyEvent`, `MouseButton`, `ScrollEvent`
   - splits: `SplitDirection`, `GotoSplit`
   - `NewSurfaceContext{kind: window|tab|split, parent: Surface?, arguments}`
4. **App** (`app.cr`)
   - Lifecycle:
     - Creates the AdwApplication: app id validated with `g_application_id_is_valid`, `NON_UNIQUE` when
       single-instance is off.
     - Handles startup, activate and shutdown, plus `run(argv) : Int32`, `post`, `quit` (with confirmation),
       and the surface registry.
   - Desktop integration:
     - CSS: the embedded `style.css` plus `App#css` through `gtk_css_provider_load_from_string`.
     - `AdwStyleManager` color scheme: `notify::dark` fires the color-scheme callback.
     - sd_notify: READY, RELOADING, STOPPING.
   - Subclass hooks:
     - `new_surface(ctx) : Content` is abstract.
     - `load_config(soft) : Config`.
     - `perform` overloads.
5. **Actions** (`action.cr` macro and registry, `actions.cr` built-ins). The generic set from `apprt/action.zig`:
   - app: quit, new-window, close-all-windows, reload-config, present-surface, desktop-notification, open-url
   - window: close-window, toggle-maximize, toggle-fullscreen, toggle-window-decorations, goto-window,
     set-window-title, initial-size/size-limit/resize-window, set-window-theme
   - tabs: new-tab, close-tab{this,other,right}, move-tab, goto-tab, toggle-tab-overview,
     move-tab-to-new-window
   - splits: new-split, goto-split, resize-split, equalize-splits, toggle-split-zoom
   - titles and surface: set-title, set-tab-title, prompt-title, ring-bell, mouse-visibility
6. **Trigger and keybinds** (`trigger.cr`, `keybinds.cr`, `key.cr`), ported from `gtk/key.zig`.
   - `Trigger.parse`, `#to_gtk_accel` (`<Control><Shift>t`), `#to_xdg` (`CTRL+SHIFT+t`).
   - `record Binding, trigger, action, global`. Accels are applied with
     `gtk_application_set_accels_for_action`; a reload clears the previous set first.
   - Keyval/mods translation and the unshifted codepoint use `gdk_display_map_keycode`.
7. **SplitTree** (`split_tree.cr`): port of `src/datastruct/split_tree.zig`.
   - `struct SplitTree(V)` keeps nodes in an array, root at index 0, as
     `record Node(V), view : V?, layout, ratio : Float32, left, right`. The tree is immutable.
   - Operations: `locate`, `each`, `zoom`, `goto` (previous/next/wrapped/spatial), `deepest`, `split`, `remove`,
     `equalize`, `resize`, `with_ratio`, `spatial`, and `to_diagram` for specs.
8. **SplitView** (`split_view.cr`)
   - A tree change schedules one idle rebuild.
   - The rebuild unparents the leaf hosts and builds nested `GtkPaned` widgets (shrink off).
   - Zoom shows only the zoomed leaf.
   - Paned positions: the ratio is applied on `notify::max-position`, and `notify::position` writes back with
     `with_ratio`.
   - Focus is restored on idle.
9. **Window and Tab** (`window.cr`, `tab.cr`), following `gtk/class/window.zig` and `gtk/ui/1.4/window.blp`
   - Widget tree: AdwApplicationWindow > AdwTabOverview > AdwToolbarView > AdwHeaderBar (AdwWindowTitle, new-tab
     button, menu) + AdwTabBar + AdwToastOverlay > AdwTabView.
   - Behavior:
     - `create-window` lets a tab be dragged out.
     - `close-page` asks for confirmation; the window closes when no pages are left.
     - Each window has its own `win.*` GActions.
     - Each Tab wraps a SplitView. Its title follows the focused surface or a title override, and it has
       `tab.*`/`split.*` action groups.
10. **Surface and Content** (`surface.cr`, `content.cr`, `canvas.cr`, `input.cr`, `clipboard.cr`)
    - The Surface host is an AdwBin. It provides:
      - `title=`, `bell`, `close`, `notify`
      - `content_scale` from `gdk_surface_get_scale`, `size`, `cursor_pos`
      - `cursor=`, `mouse_visible=`, `ime_position=`, `queue_render`
      - `clipboard_read(kind) { |text| }`, `clipboard_write`
    - `WidgetContent.new(widget)`: any app widget.
    - `abstract class Canvas < Content`: a GtkGLArea with runtime-installed input controllers. It follows
      Ghostty's `gtk/class/surface.zig` for IME ordering:
      - EventControllerKey + GtkIMMulticontext
      - Focus, GestureClick, Motion, Scroll
    - Canvas overridable hooks: `key`, `preedit`, `commit`, `mouse_*`, `scroll`, `focus`, `resize`, `realize`,
      `unrealize`, `render`.
11. **Dialogs** (`dialogs.cr`): AdwAlertDialog for close confirmation and AdwAlertDialog + entry for the title
    prompt.
12. **Notifications** (`notifications.cr`), ported from `gtk/desktop_notifications.zig`.
    - GNotification with the default action `app.present-surface(t)`.
    - Each surface has its own id, with a limit and eviction.
    - Notifications are withdrawn after a timeout.
13. **DBus, IPC and portals** (`dbus.cr`, `ipc.cr`, `portal.cr`, `global_shortcuts.cr`)
    - `dbus.cr`: thin GDBus wrappers.
    - IPC client, `IPC.send(app_id, action)`: allowed only for `ipc: true` actions. It calls
      `org.gtk.Actions.Activate (sava{sv})` on the app's object path (`.`→`/`, `-`→`_`).
    - Portal helper: token, predicted request path, and a subscription to `Request.Response` made **before** the
      call.
    - GlobalShortcuts:
      - Session setup: `CreateSession`, then `BindShortcuts a(sa{sv})`.
      - `Activated` triggers the action by detailed name.
      - A `bind-failed` callback reports failures, and `Session.Close` runs on shutdown.
14. **systemd** (`systemd.cr`): sd_notify written to `NOTIFY_SOCKET` with a DGRAM socket, including abstract `@`
    addresses, as in Ghostty's `src/os/systemd.zig`. Transient scopes come later.
15. **Config reload**: RELOADING=1 → `load_config` → apply (accels, color scheme, global shortcuts, CSS) →
    `config_changed` on every content → READY=1.

## Conventions

- `# path` header on every file. Follow the user's rules: visibility (`private`/`protected`/`:nodoc:` for the
  generated `C` lib, Handles, trampolines and controller handlers), doc-comment style, README.md for the public
  API, AGENTS.md for layout, commands, standards and `:nodoc:` extension points.
- `shard.yml`: version 0.1.0, author shpeckman, `crystal: ">= 1.23.0"`, MIT,
  `libraries: gtk4 '>= 4.18', libadwaita-1 '>= 1.7', gio-2.0 '*'`, no dependencies.
- Makefile in crwin style (`.POSIX`). Targets: `gen`, `spec`, `spec-gtk`, `spec-dbus`, `spec-wayland`, `docs`,
  `format`, `clean`.
- One compile at a time, `--threads 2`. Prefix commands that change files with `dev`.
- Work on `dev`. Ship only when asked.

## Milestone 1 steps (each compiles and adds specs)

1. Scaffold: shard.yml, Makefile, .gitignore, LICENSE, AGENTS.md, README.md, spec_helper.
2. GIR generator, allowlists, generated `c/*.cr` and `manual.cr`. Specs: fixture GIR, plus
   `crystal build --no-codegen` on the generated files.
3. glib layer (error, native, handles, wrapper, widget, signals, variant). Pure specs.
4. ui_thread and the minimal App (lifecycle, post, quit, CSS, style manager, sd_notify, signal traps). GTK spec:
   start, post, quit.
5. Action macro and registry, built-in action table, Trigger, keybinds and accels. Pure and GTK specs.
6. SplitTree model, using Ghostty's diagram test cases.
7. Surface with WidgetContent, Window, Tab, SplitView, window/tab/split actions and the dialogs. GTK specs:
   n-pages, paned nesting, focus, zoom, close confirmation.
8. Canvas: GLArea, controllers, IME, keys, scroll, scale, cursor, clipboard, bell. Wayland spec.
9. Notifications and present-surface. DBus spec against a fake `org.freedesktop.Notifications`.
10. IPC client and `examples/ipc.cr`. DBus round-trip spec.
11. Portal helper and GlobalShortcuts. Spec against a fake `org.freedesktop.portal.Desktop`.
12. End-to-end config reload, `examples/hello.cr` and `examples/canvas.cr`, docs pass (`crystal docs` shows only
    the public API), README/AGENTS sync.

Later milestones: layer-shell quick window, blur, xdg-activation urgency and KDE decorations; X11 extras; systemd
transient scopes (`StartTransientUnit`, post_fork/pre_exec); command palette, toasts and more dialogs; drag and
drop; physical-key table; DMABUF texture offload rendering.

## Verification

- `make spec`: pure specs (split tree, action codec and registry, Trigger strings, object and portal paths,
  sd_notify over a temporary DGRAM socket, generator fixture). No display needed.
- `make spec-gtk`: `gtk4-broadwayd :5`, then
  `GDK_BACKEND=broadway BROADWAY_DISPLAY=:5 dbus-run-session -- crystal spec spec/gtk --threads 2`. Drives the
  app via `post` and `g_action_group_activate_action` and checks the widget tree.
- `make spec-dbus`: under `dbus-run-session`, covers the IPC round trip, the fake portal (GlobalShortcuts
  Activated, Request.Response) and the fake notifications server.
- `make spec-wayland`: headless sway (`WLR_BACKENDS=headless WLR_RENDERER=pixman`) for the GLArea canvas.
- Manual check in the real session:
  - `crystal run examples/hello.cr`: tabs, splits, drag-out, accels, a notification click presenting the surface.
  - `examples/ipc.cr`: opens a window in the running instance.
  - SIGUSR2 reloads the config.
- `crystal docs`: the API shows only the intended public surface.

## Risks

- GTK running on an Isolated (non-main) thread is unverified for GTK 4 on Linux. Step 4's spec checks it first.
  The fallback is GTK on the main thread with app fibers in a Parallel context.
- Crystal's SIGCHLD handler reaps every child, including GLib-spawned ones, so children should be started with
  Crystal `Process`.
- GLArea is unrealized and realized again on split rebuilds, so the canvas must rebuild its GL state in `realize`.
- The GlobalShortcuts portal outside Flatpak needs a desktop file or host registry. Desktop support varies
  (GNOME 48+, KDE).
- Broadway has no GL and no real key injection, hence the headless-sway target.
