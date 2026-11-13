# AGENTS.md

apprt is a native application runtime for Crystal programs on Linux, ported
from Ghostty's `src/apprt` (GTK 4 + libadwaita). It is generic: no terminal,
pty or renderer code. The implementation plan lives in
`.claude/golden-orbiting-key.md`.

## Commands

```sh
make spec     # crystal spec --threads 2
make gen      # regenerate src/apprt/c/*.cr from GIR + data/gir/ allowlists
make docs     # crystal docs src/apprt.cr -o docs
make format   # crystal tool format src spec tools
make clean
```

Run one Crystal compile at a time, with `--threads 2`. When sandboxed, set
`CRYSTAL_CACHE_DIR=.dev/cache`.

## Layout

- `src/apprt.cr` - entry; requires the bindings.
- `src/apprt/c/` - `Apprt::C` (`:nodoc:`), the C bindings.
  - `glib.cr gobject.cr gio.cr gdk.cr gtk.cr adw.cr` - generated, never edit.
  - `manual.cr` - what the generator cannot emit (`GValue`, which holds a
    union).
- `tools/gen_gir.cr` - generator CLI; `tools/gir/generator.cr` - the
  `GirGenerator` module (GIR → `lib C`).
- `data/gir/<Namespace-Version>.txt` - allowlists.
- `spec/pure/` - specs needing no display: generator (fixture
  `spec/data/Fixture-1.0.gir` + `.txt`) and bindings (every generated `fun`
  resolves with `dlsym`, `GValue` size, a GType round trip).

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
