# Limitations

## Scope

- **Selected classes only.**  C functions are emitted for `toplevel`,
  `frame`, `ttk::frame`, `ttk::label`, `ttk::button`, `ttk::entry` and
  `ttk::treeview`.  The other 15 discovered ttk classes are analysed (see
  COVERAGE_TABLES.md); emitting them is a one-line change in the
  generator's selection list, but they are untested and would need
  overlays for their callbacks (`-command` of checkbutton, scale, …).
- **No `place`, menus, canvas, text, images, dialogs, fonts, clipboard or
  selection.**  `-image` options accept the name of an image created by
  other means; tkx itself cannot create images.
- **Geometry managers:** `grid` and `pack` per-window options, row/column
  options, and the subcommands `forget`, `remove`, `propagate`, `anchor`,
  `size`, `bbox`.  Not exposed: `grid location`, `grid content`/`pack
  content` (which return window lists), the `bbox` cell-range form, the
  `x`/`^` shorthands, and configuring several windows in one call.
- **Event bindings:** one tkx binding per widget and sequence.  Class and
  tag bindings (`bind TButton …`, `bindtags`) are not exposed, and
  bindings created by tkx replace other bindings on the same widget and
  sequence.
- **Single application per process** at a time, on one thread, with one
  interpreter (Tk's model).  Re-initialisation after shutdown works.

## Extraction

- **Semantic string types.**  `TK_OPTION_STRING` does not say whether a
  value is plain text, a Tcl script, a variable name or a list.  This is
  supplied by 16 overlay entries (12 option and 4 sub-object option
  entries); options without an entry are exposed as plain strings.  For
  the selected classes all such options were reviewed.  For the other
  classes, a string option that is really a script would be exposed as a
  string if those classes were selected without review.  The generic
  property interface refuses only options that are *flagged*.
- **`TK_OPTION_CUSTOM`** (`-locale`) is reported as unsupported rather
  than guessed.
- **Subcommand evidence is pattern-based.**  It recognises simple guard
  shapes, direct `objv[N]` uses (plus one level of local-variable flow for
  script detection) and result constructors in the vocabulary.  Anything
  else is "partial", which is safe because nothing is generated from it,
  but it limits automatic coverage (71 of 243 subcommands).  Data flow
  through helper functions is not followed: for example, argument
  conversion inside `InsertChars` is not seen.
- **The conversion vocabulary is curated** (`generator/config.tcl`, about
  35 function names).  An unknown converter makes the argument "unknown",
  not wrongly typed.  A vocabulary entry with a wrong type would mistype
  every use of that function.  The vocabulary is small and each entry is
  checked by the behavioural tests of the functions that use it.
- **Restricted preprocessor.**  It supports what Tk's sources use.  Full
  C rescanning across expansion boundaries, computed includes and
  unknown directives stop extraction with an error.  Configure-time macros
  (`HAVE_XFT`, …) are assumed undefined, and anything depending on them is
  reported.  For a build with such macros defined, the extraction would
  have to be rerun with those macros in the platform configuration.
- **Macro-generated tables** are supported only through macros the
  expander understands (`WIDGET_TAKEFOCUS_TRUE`, `WIDGET_INHERIT_OPTIONS`,
  `TTK_OPTION_UNDERLINE_DEF`, default macros).  The ttk layout tables
  (`TTK_BEGIN_LAYOUT`) are skipped deliberately.
- **Classic widgets** need an overlay for the command → option-table
  binding.  Only the frame family was bound; button, label, entry and the
  other classic widgets were not attempted.

## Runtime and API

- **Platforms:** the generator evaluates Unix, Windows and macOS
  configurations, and the selected classes' option tables are identical
  on all three.  But the library was built and run only on Linux/X11
  (Ubuntu 24.04, Xvfb).  The Windows/macOS build files are not written
  (the code uses `_Thread_local`, `TclZipfs_AppHook` and standard Tcl/Tk
  APIs only).
- **Value types are mapped conservatively.**  `-underline` values such as
  `end-1` and pixel values with units are readable only through the
  generic string getter; the typed getters convert pixels with
  `Tk_GetPixelsFromObj`.  Colors and fonts are strings.  Treeview items
  and columns are identified by Tk's string ids, not by handles.
- **Optional subcommand arguments** are pointers (`NULL` = omitted).
  Treeview `children(item, newchildren)` maps Tk's get/set dual form
  directly: when `newchildren` is given, the result list is empty.
- **`tkx_widget_call`** is an escape hatch.  It never parses its arguments
  as Tcl, and it refuses the subcommands known to take Tcl scripts
  (detected from the sources), but it cannot validate argument semantics
  of subcommands whose evidence is partial.
- **Not exposed:** the ttk style/theme API (`ttk::style`), `wm` beyond
  title/geometry/minsize/withdraw/show, focus traversal configuration,
  `tk scaling`, `event generate`.
- **Generated names follow Tk's option names** (`tkx_ttk_entry_set_exportselection`),
  so they read like Tk, not like a designed C API.  Language bindings are
  expected to add their own naming.

## Process

- The pinned Tcl/Tk sources are downloaded from SourceForge with SHA-256
  pins, and the SHA-1 published by SourceForge was cross-checked.  There is
  no offline mirror in the repository.
- No CI service was run as part of this work.  `.github/workflows/ci.yml`
  describes the intended Linux/Xvfb job, but it has not been executed on
  GitHub.
