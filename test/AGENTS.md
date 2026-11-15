# AGENTS.md

Orientation for AI agents on `apprt-test`: live tests of the apprt shard in
the parent directory.

## Commands

```sh
make         # shards update + build bin/apprt-test and bin/apprt-under-test
make spec    # crystal spec: the subject and cases.yml, no desktop
make docs    # crystal docs src/main.cr
make setup   # interactive, once per desktop: see README.md
make test    # MODE=kde (default) or sway; CASES=name... runs some cases;
             # ARGS=-u writes the goldens
make clean
```

- Never run `make setup` or `make test` (mode `kde`) unasked: `kde` takes
  over the user's keyboard and pointer; setup waits for the user to confirm
  KDE's shortcut dialog.
- `make test MODE=sway` (headless nested sway, virtual input devices) is
  safe.
- Modes `sway` and `offscreen` can't test global shortcuts: nested sway
  shares the user's session bus, so the KDE portal would bind (and show its
  dialog) on the real desktop while kglobalaccel never sees the nested
  compositor's keys.
- One Crystal compile at a time, `--threads 2` (`CRFLAGS`).

## Layout

- `src/main.cr` - harness: `Livetest.run(ARGV, Apprt::Test::Subject.new)`.
- `src/apprt/test/subject.cr` - `Apprt::Test::Subject` (`:nodoc:`): starts
  `apprt-under-test --class <livetest app id>`, plus `--global` for cases
  with extra key `global: true`.
- `src/under_test.cr` - app under test (`Apprt::Test::UnderTest`).
- `cases.yml` - cases; `spec/subject_spec.cr` checks it parses.
- `goldens/<case>/<shot>.png` - screenshots compared against, written by
  mode `sway` (`ARGS=-u`), shared by all modes. Shots hold the window only,
  client-side decorated, opaque (livetest composites KWin's translucent
  captures over black). Tolerance 2 per channel (KDE corner antialiasing);
  `offload`'s 4 (bottom corners over saturated blue).
- `shard.override.yml` - livetest from `../../livetest`; apprt = parent dir
  (`path: ..`).
- `bin/`, `lib/`, `out/`, `shard.lock` - generated, ignored.

## Internals

- App id: livetest names each case's app `livetest-<pid>-<n>` and finds its
  window by that class, but a GApplication id needs a dot and GTK sets the
  Wayland app id from it at realize. So the app keeps fixed id
  `org.example.ApprtLive` (portal and kglobalaccel need a stable one) and
  sets the toplevel's app id with `gdk_wayland_toplevel_set_application_id`
  after `App#new_window`.
- Portal accepts `Registry.Register` only for an id naming an installed
  desktop file. Without it xdg-desktop-portal-kde names the kglobalaccel
  component after the session token (`token_apprt_<hex>` in
  `~/.config/kglobalshortcutsrc`), new per run, and asks again each time.
- Plasma 6.4+ shows a dialog for shortcuts an app hasn't bound before;
  `make setup` binds once with the user present. apprt calls
  `BindShortcuts` on every start, which xdg-desktop-portal-kde 6.7.4+ needs
  to activate stored shortcuts.
- No apprt hook for a successful bind, so the case sleeps 1.5 s before
  pressing the shortcut.
- Only `--global` (or `--setup`) binds the global shortcut: binding in a
  nested sway would reach the real desktop's portal via the shared session
  bus.
- App's own actions: `Report` (window), `ShowProgress` (split),
  `ReportSurfaces` (tab), `HeaderTabs` and `PaneHeaders` (app),
  `OpenCanvas` (window).
  - `OpenCanvas` makes the next surface a `Halves` canvas (`offload: true`,
    red over blue in GL coordinates, so a flipped frame shows in the shot)
    and opens a tab; canvas reports `canvas dmabuf=…` from its first
    `on_presented`.
  - `ReportSurfaces` names each surface by the `SurfaceContext::Kind` it
    opened as, so a drop's new order shows.
  - `Report` lines carry the active key tables, so `expect` proves which
    binding ran and in which table. Labels aren't focusable, so the
    window's first button holds focus (its ring shows in the shots).
- GTK starts a drag only if the pointer passes its threshold while still
  over the drag handle; a first move leaving the handle (livetest's `drag`
  step) starts nothing. So `drag-drop` presses with `down`, moves a few
  pixels along the handle, waits for the drag to start, then moves to the
  drop point. `header-drag` does the same on the left pane header's title
  (y 58, below the 44-pixel header bar).
- `expect` skips other lines until the expected one, so a case can't check
  that a binding did not fire; it checks the wanted one did (Ctrl+A Ctrl+T
  reports `capture` only if the sequence took the key).

## Code standards

Parent's `AGENTS.md` applies: compiler-friendly, performance-focused,
idiomatic Crystal; `private`/`protected`/`# :nodoc:` visibility; every file
starts with a `# path` comment; format touched files with
`dev crystal tool format <files>`.
