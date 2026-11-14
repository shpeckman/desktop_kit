# apprt-test

Live tests of apprt on the KDE Plasma desktop, through
[livetest](https://github.com/shpeckman/livetest). They cover what a
private test compositor cannot: global key bindings bound by the desktop's
global shortcuts portal and fired by kglobalaccel.

## Requirements

A KDE Plasma 6 Wayland session with xdg-desktop-portal-kde, plus what
livetest needs (see its README).

## Usage

```sh
make setup  # once per desktop
make test   # runs every case of cases.yml
make test CASES=global-shortcut
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
log. Exit status 0 means every case passed.

## Cases

- `global-shortcut` - opens a window, presses Ctrl+Alt+Shift+F9 while it
  has the focus and expects the tab the global binding opens. Global
  bindings have no window shortcut, so only the portal can open it.

## The app under test

`bin/apprt-under-test` is an apprt app with the id `org.example.ApprtLive`
and the single global binding Ctrl+Alt+Shift+F9 → `NewTab`. It writes to
`LIVETEST_FIFO` and to standard error:

| Line                      | When                                   |
|---------------------------|----------------------------------------|
| `window`                  | its window is open                     |
| `tab`                     | the global binding opened a tab        |
| `unbound TRIGGER: REASON` | the desktop refused the global binding |

`--class ID` sets the window class (Wayland app id) the harness finds the
window by; `--setup` installs the desktop file and quits after the first
activation of the shortcut, with status 1 when the desktop refused it.

## License

MIT
