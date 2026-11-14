# apprt-test

Live tests of apprt through
[livetest](https://github.com/shpeckman/livetest), with real keyboard
input and a real pointer. On the KDE Plasma desktop they cover what a private test
compositor cannot: global key bindings bound by the desktop's global
shortcuts portal and fired by kglobalaccel, and the taskbar's progress.
Key sequences, key tables, the progress bar, tabs in the header bar and
dragging a surface also run in a nested sway,
which leaves your keyboard and pointer alone.

## Requirements

For mode `kde`, a KDE Plasma 6 Wayland session with
xdg-desktop-portal-kde; for mode `sway`, sway and `grim`. Plus what
livetest needs (see its README).

## Usage

```sh
make setup  # once per desktop
make test   # runs every case of cases.yml
make test CASES=global-shortcut
make test MODE=sway  # the cases that run in sway, in a headless sway
```

`make setup` lets the harness take window screenshots, installs
`org.example.ApprtLive.desktop` into `~/.local/share/applications` and
starts the app under test once. The desktop asks to confirm its global
shortcut, Ctrl+Alt+Shift+F9: confirm it, then press the shortcut, and the
app quits. The portal knows the app only through that desktop file, and
KDE asks only for shortcuts the app did not bind before, so later runs
bind without a dialog.

`make test` takes over the keyboard and the pointer while it runs; press
Escape three times to abort. Results go to `out/<case>/`, with the app's
log and the screenshots. The shots are compared with `goldens/<case>/`;
`make test MODE=sway CASES=... ARGS=-u` writes them anew. Exit status 0
means every case passed.

## Cases

- `global-shortcut` - opens a window, presses Ctrl+Alt+Shift+F9 while it
  has the focus and expects the tab the global binding opens. Global
  bindings have no window shortcut, so only the portal can open it.
  `kde` only.
- `sequences` - Ctrl+T, then Ctrl+A N, then Ctrl+A Ctrl+T. Ctrl+T alone is
  a window shortcut; after Ctrl+A the sequence must take it. Shoots the
  pending Ctrl+A in the key state overlay.
- `key-tables` - Ctrl+A E enters the key table `mode`, where X reports
  until Escape; Ctrl+A O enters it for one binding. Shoots the overlay
  naming the table.
- `progress` - Ctrl+A P sets the surface's progress to 40 % and Ctrl+A
  Shift+P clears it. Shoots the bar. In mode `kde` the taskbar entry
  shows the progress too, once `make setup` installed the desktop file;
  look at it while the case runs, the shot covers the window only.
- `header-tabs` - Ctrl+A T opens a second tab and Ctrl+A H moves the tab
  bar into the header bar. Shoots the header bar with both tabs.
- `drag-drop` - Ctrl+A S splits the window's surface; the pointer drags
  that surface's drag handle onto the right edge of the split, and
  Ctrl+A L reports the surfaces swapped.

## The app under test

`bin/apprt-under-test` is an apprt app with the id `org.example.ApprtLive`.
Its window shows a label and has these bindings:

| Keys                        | Action                                    |
|-----------------------------|-------------------------------------------|
| Ctrl+T                      | reports `accel`                           |
| Ctrl+A N                    | reports `sequence`                        |
| Ctrl+A Ctrl+T               | reports `capture`                         |
| Ctrl+A E / Ctrl+A O         | key table `mode`, until Escape / for once |
| X (in `mode`)               | reports `table`                           |
| Ctrl+A P / Ctrl+A Shift+P   | progress 40 % / no progress               |
| Ctrl+A T                    | `NewTab`                                  |
| Ctrl+A S                    | `NewSplit` to the right                   |
| Ctrl+A L                    | reports the tab's surfaces                |
| Ctrl+A H                    | moves the tab bar into the header bar     |
| Ctrl+Alt+Shift+F9 (global)  | `NewTab`, with `--global` or `--setup`    |

It writes to `LIVETEST_FIFO` and to standard error:

| Line                      | When                                         |
|---------------------------|----------------------------------------------|
| `window`                  | its window is open                           |
| `tab`                     | a tab opened                                 |
| `unbound TRIGGER: REASON` | the desktop refused the global binding       |
| `NAME tables=T,...`       | a binding reported NAME; T the active tables |
| `progress PERCENT`        | the progress changed; -1 is none             |
| `surfaces K,...`          | the tab's surfaces, left to right, by the    |
|                           | kind they opened as (`window`, `tab`, `split`) |
| `header tabs`             | the tab bar moved into the header bar        |

`--class ID` sets the window class (Wayland app id) the harness finds the
window by; `--global` binds the global shortcut (cases with
`global: true`); `--setup` installs the desktop file and quits after the
first activation of the shortcut, with status 1 when the desktop refused
it.

## License

MIT
