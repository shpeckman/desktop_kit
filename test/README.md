# desktop-kit-test

Live tests of desktop_kit through
[livetest](https://github.com/shpeckman/livetest), with real keyboard
input and a real pointer. On the KDE Plasma desktop they cover what a private test
compositor cannot: global key bindings bound by the desktop's global
shortcuts portal and fired by kglobalaccel, and the taskbar's progress.
Key sequences, key tables, the progress bar, tabs in the header bar,
dragging a surface by its handle or pane header and a canvas offloading
its frames as DMA-BUFs also run in a nested sway,
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
`org.example.DesktopKitLive.desktop` into `~/.local/share/applications` and
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
- `header-drag` - Ctrl+A M turns pane headers on and Ctrl+A S splits;
  the pointer drags the left pane header onto the right edge of the
  split, and Ctrl+A L reports the surfaces swapped. Shoots both headers.
- `offload` - Ctrl+A C opens a tab with a canvas that offloads its
  frames; its first frame must arrive as a DMA-BUF. Shoots the canvas,
  red on top and blue below.
- `search-overlay` - Ctrl+A F opens the search bar; typing, Return and
  Shift+Return report to the content, which has three matches. Shoots the
  bar, drags it by its match count to the bottom left, shoots it snapped
  there, and Escape closes it.
- `panel-quick` - Ctrl+A Q opens a top overlay panel that hides on focus
  loss. The harness focuses the window before each key, so Ctrl+A V then
  reports it hidden; Ctrl+A Q shows it again.
- `panel-dock` - Ctrl+A B opens a 160 px bottom dock and a left probe
  panel that keeps clear of reserved space; the probe must lose exactly
  the dock's height. Panels close with the window.
- `header-menu` - opens the header bar's main menu, shoots it and opens a
  tab from its New Tab item.
- `translation` - the same menu with Dutch texts from `DesktopKit.translator`
  (`dutch: true`).
- `context-menu` - right-clicks the label, shoots its context menu and
  picks its Report item.
- `shortcuts-dialog` - Ctrl+A K opens the keyboard shortcuts dialog;
  shoots it, searches for "progress" and closes it.
- `about` - Ctrl+A I opens the about dialog. Shoots it.
- `sequence-timeout` - Ctrl+A W sets a 300 ms sequence timeout; a quick
  Ctrl+A N still fires, but after a pause Ctrl+T reaches the window
  shortcut.
- `threaded-canvas` - Ctrl+A G opens a canvas rendering on its own thread.
  Shoots its first frame.
- `tray` - Ctrl+A Y shows a tray icon and checks the desktop's
  StatusNotifierWatcher registered it. `kde` only.

## The app under test

`bin/desktop-kit-under-test` is a desktop_kit app with the id
`org.example.DesktopKitLive`. Its window shows a label and has these bindings:

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
| Ctrl+A M                    | shows pane headers                        |
| Ctrl+A C                    | opens a tab with an offloading canvas     |
| Ctrl+A G                    | opens a tab with a threaded canvas        |
| Ctrl+A W                    | sets a 300 ms sequence timeout            |
| Ctrl+A K                    | opens the keyboard shortcuts dialog       |
| Ctrl+A I                    | opens the about dialog                    |
| Ctrl+A Y                    | shows a tray icon                         |
| Ctrl+A F                    | opens the search bar (three matches)      |
| Ctrl+A Q                    | opens the quick panel, or toggles it      |
| Ctrl+A V                    | reports whether the quick panel is shown  |
| Ctrl+A B                    | opens a bottom dock and a probe panel     |
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
| `pane headers`            | every surface shows its pane header          |
| `canvas dmabuf=BOOL`      | the canvas showed its first frame, as a      |
|                           | DMA-BUF when BOOL is `true`                  |
| `canvas threaded`         | the threaded canvas showed its first frame   |
| `timeout MS`              | the sequence timeout was set                 |
| `tray registered=BOOL`    | whether the watcher lists the tray icon      |
| `context tables=T,...`    | the context menu's Report item was picked    |
| `search TEXT` / `search end` | the search text changed / the bar closed  |
| `navigate next\|previous` | Return / Shift+Return in the search bar      |
| `panel shown=BOOL`        | the quick panel opened or toggled, or was    |
|                           | asked about                                  |
| `dock clear=BOOL`         | the probe panel lost exactly the dock's      |
|                           | height                                       |

`--class ID` sets the window class (Wayland app id) the harness finds the
window by; `--global` binds the global shortcut (cases with
`global: true`); `--setup` installs the desktop file and quits after the
first activation of the shortcut, with status 1 when the desktop refused
it.

## License

MIT
