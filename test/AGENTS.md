# AGENTS.md

Orientation for AI agents working on `apprt-test`, the live tests of the
apprt shard in the parent directory.

## Commands

```sh
make         # shards update + build bin/apprt-test and bin/apprt-under-test
make spec    # crystal spec: the subject and cases.yml, no desktop
make docs    # crystal docs src/main.cr
make setup   # interactive, once per desktop: see README.md
make test    # MODE=kde (default); CASES=name... runs some cases
make clean
```

Never run `make setup` or `make test` unasked: mode `kde` takes over the
user's keyboard and pointer, and setup waits for the user to confirm
KDE's shortcut dialog. Modes `sway` and `offscreen` cannot test global
shortcuts: a nested sway shares the user's session bus, so the KDE portal
would bind (and show its dialog) on the real desktop while kglobalaccel
never sees the nested compositor's keys. Run one Crystal compile at a
time, with `--threads 2` (`CRFLAGS`).

## Layout

- `src/main.cr` - the harness: `Livetest.run(ARGV, Apprt::Test::Subject.new)`.
- `src/apprt/test/subject.cr` - `Apprt::Test::Subject` (`:nodoc:`):
  starts `apprt-under-test --class <livetest app id>`.
- `src/under_test.cr` - the app under test (`Apprt::Test::UnderTest`).
- `cases.yml` - the cases; `spec/subject_spec.cr` checks that it parses.
- `shard.override.yml` - takes livetest from `../../livetest`; apprt is
  the parent directory (`path: ..`).
- `bin/`, `lib/`, `out/`, `shard.lock` - generated, ignored.

## Internals

- livetest names each case's app `livetest-<pid>-<n>` and finds its window
  by that class, but a GApplication id needs a dot, and GTK sets the
  Wayland app id from it at realize. The app keeps its fixed id
  `org.example.ApprtLive` (the portal and kglobalaccel need a stable one)
  and sets the toplevel's app id with
  `gdk_wayland_toplevel_set_application_id` after `App#new_window`.
- The portal accepts `Registry.Register` only for an id naming an
  installed desktop file. Without it, xdg-desktop-portal-kde names the
  kglobalaccel component after the session token (`token_apprt_<hex>` in
  `~/.config/kglobalshortcutsrc`), a new one per run, and asks again each
  time.
- Plasma 6.4 and later show a dialog for shortcuts an app did not bind
  before; `make setup` binds once with the user present. apprt calls
  `BindShortcuts` on every start, which xdg-desktop-portal-kde 6.7.4 and
  later need to activate stored shortcuts.
- apprt has no hook for a successful bind, so the case sleeps 1.5 s
  before pressing the shortcut.

## Code standards

The parent's `AGENTS.md` applies: compiler-friendly, performance-focused,
idiomatic Crystal; `private`/`protected`/`# :nodoc:` visibility; every
file starts with a `# path` comment; format touched files with
`dev crystal tool format <files>`.
