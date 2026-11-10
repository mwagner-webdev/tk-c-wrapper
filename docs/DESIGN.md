# Design

## Architecture

```
            consumer (C, Rust/Botlish bindings later)
                         |  tkx.h  (no Tcl/Tk types)
        +----------------+---------------------------------+
        | generated API (tkx_generated.c)                  |
        |   per-class create / option get/set / subcommands|
        |   grid/pack, enums, class metadata               |
        +--------------------------------------------------+
        | runtime (handwritten): tkx_runtime.c,            |
        |   tkx_handles.c, tkx_callbacks.c                 |
        |   handles, lifecycle, event loop, errors,        |
        |   Tcl_EvalObjv invocation, value conversion      |
        +--------------------------------------------------+
        | Tcl 9.1 interpreter + Tk 9.1 (unchanged)         |
        +--------------------------------------------------+
```

The generated code calls only the runtime's helper interface
(`src/tkx_internal.h`).  A generated function is a thin, mechanical
mapping. For example `tkx_ttk_label_set_text(w, s)`:

1. validates the handle (thread, application, generation, kind);
2. builds the words `{path, "configure", "-text", s}` as separate
   `Tcl_Obj`s;
3. invokes them with `Tcl_EvalObjv` and maps a Tk error to `TKX_ERR_TK`
   with Tk's message.

No script is ever built by string concatenation.  Where Tk itself needs a
script (a `-command` option, an event binding), the script is a list
built with `Tcl_NewListObj`, whose only content is the trampoline command
and a numeric callback handle.

Everything that is per-widget lives in generated code, and everything that
is a mechanism lives in the runtime.  The runtime has no knowledge of
individual widget options.

## Handles

`TkxId` is a `uint64_t`:

```
 63      56 55      48 47              24 23               0
 +---------+----------+------------------+------------------+
 |  kind   | app ser. |   generation     |   slot index     |
 +---------+----------+------------------+------------------+
```

- **slot index** (24 bits): an entry in a process-wide slot table.
- **generation** (24 bits): incremented whenever the slot is released.  A
  handle matches only while its generation equals the slot's.  When a
  slot's generation reaches its maximum, the slot is retired rather than
  wrapped, so a stale handle can never become valid again.
- **application serial** (8 bits, never 0): changes with every
  `tkx_app_init()`.  The slot table and its generations survive
  `tkx_app_shutdown()`, so handles from an earlier application fail both
  checks.
- **kind** (8 bits, never 0): the object kind.  Widget kinds are fixed ABI
  numbers assigned in the generator's selection list (`TKX_KIND_TOPLEVEL`
  = 1 … `TKX_KIND_TTK_TREEVIEW` = 7).  `TKX_KIND_CALLBACK` = 200.  The kind
  stored in the slot must equal the kind bits, so a forged handle is
  rejected even if index and generation happen to match.

`TKX_NULL_ID` (0) is never valid.

**Why 64 bits rather than Raven's 32-bit `Rid`.**  Raven packs 4 bits of
type, 8 bits of generation and 20 bits of index into 32 bits (from
`src/core/handle.c`).  An 8-bit generation repeats after 256 reuses of a
slot, so a stale handle kept by a long-running program, or by a binding's
garbage-collected wrapper, can silently alias a new object.  The 64-bit
layout gives 16.7 million generations per slot plus retirement, room for
256 kinds, and an application serial.  It still maps to a plain integer in
every FFI (Rust `u64`, etc.).  The naming conventions and the
"validate on every call" behaviour follow Raven.

**Validation results.**  Lookups distinguish:

| status | meaning |
|---|---|
| `TKX_ERR_INVALID_HANDLE` | never a handle of this application (0, garbage, other serial, forged kind) |
| `TKX_ERR_STALE_HANDLE` | was valid and the object is gone (destroyed or released) |
| `TKX_ERR_WRONG_KIND` | a live handle of another kind (e.g. a label passed to a button function, or a callback handle passed as a widget) |

**Widgets destroyed by Tk itself.**  Each registered widget has a Tk
`StructureNotify` event handler (`Tk_CreateEventHandler`).  When Tk sends
`DestroyNotify`, the handle is released and the widget's callbacks are
freed.  This happens whether the widget was destroyed through
`tkx_widget_destroy`, as a descendant of a destroyed widget, by Tk code
such as a binding running `destroy`, or by the window manager closing a
toplevel.  The `handle-1.7` and `handle-1.8` tests destroy widgets through
Tk directly and check that their handles become stale.

**Path names.**  Widgets get generated path names (`.w12`, `.w3.w15`).
Consumers never see them.  A path→widget hash table maps Tk's answers back
to handles, e.g. for `grid info -in` or `TK_OPTION_WINDOW` values.

## Application lifecycle

- `tkx_app_init(config)` creates the interpreter, runs `Tcl_Init` and
  `Tk_Init`, makes the calling thread the UI thread, and registers the main
  window `.` as a `TKX_KIND_TOPLEVEL` handle.  In a standalone program it
  first calls `TclZipfs_AppHook`, because Tcl 9 keeps its script library
  in a zip archive attached to `libtcl` and an embedder has to mount it.
  When tkx is loaded into a process that already initialised Tcl (the
  test bridge inside `tclsh`), `config->host_initialized_tcl` skips that
  step.  Tk's own options (`-name`, `-display`) are passed through `::argv`
  built as a list.
- `TkxAppConfig.struct_size` versions the configuration struct.  Fields
  that lie beyond the caller's `struct_size` (a program compiled against
  an older `tkx.h`) read as unset; 0 means "the current layout"
  (`lifecycle-1.6`).
- Only one application exists at a time (Tk's model of one main window
  per interpreter, used here with one interpreter).  After
  `tkx_app_shutdown()` a new one may be created.
- `tkx_app_shutdown()` destroys the main window (every widget is
  invalidated through `DestroyNotify`), releases all callbacks (each
  `free_fn` runs once), resets all handles and deletes the interpreter.
- Destroying the main window ends the application:
  `tkx_app_is_running()` returns 0 and `tkx_app_run()` returns.  This is
  Tk's semantics.

## Event loop

tkx has no loop of its own.  It exposes Tcl's notifier:

| function | Tcl/Tk equivalent |
|---|---|
| `tkx_app_process_events()` | `while (Tcl_DoOneEvent(TCL_DONT_WAIT))` (returns count) |
| `tkx_app_wait_event(ms)` | `Tcl_DoOneEvent(0)` with an optional timer for the timeout |
| `tkx_app_update_idletasks()` | `update idletasks` (geometry propagation, redisplay) |
| `tkx_app_run()` / `tkx_app_quit()` | `Tk_MainLoop` with an explicit quit flag |
| `tkx_app_post(fn, data)` | `Tcl_ThreadQueueEvent` + `Tcl_ThreadAlert` (thread-safe) |
| `tkx_after(ms, fn, data, free)` | `Tcl_CreateTimerHandler` (C-level, no script) |

An application can drive Tk from its own loop by calling
`tkx_app_process_events()` regularly, or block in `tkx_app_run()`.  A
binding with an async runtime can wake the UI thread from any thread with
`tkx_app_post()`.

## UI-thread contract

A Tk application belongs to the thread that created it.  Every tkx
function except `tkx_app_post`, the pure handle decoders
(`tkx_handle_kind/index/generation`) and `tkx_status_name` checks
`Tcl_GetCurrentThread()` against the UI thread on entry.  From any other
thread it returns `TKX_ERR_WRONG_THREAD` without touching Tk.  The
`thread-1.1` test calls a setter from a second thread (refused) and posts
a task (delivered).

## Errors

Every function returns a `TkxStatus`, except creators, which return
`TKX_NULL_ID` on failure.  The status and a message are also stored per
thread (`tkx_last_error()`, `tkx_last_error_message()`).  They are reset
on entry to every call, and the message pointer stays valid until the
next call.

- `TKX_ERR_TK` carries Tk's own message unchanged, e.g. `bad relief
  "bogus": must be flat, groove, …` or `cannot use geometry manager "pack"
  inside ".w31": grid is already managing its content windows`.  tkx does
  not re-implement Tk's validation.  It forwards the value and reports
  Tk's verdict.
- `TKX_ERR_INVALID_ARGUMENT` is raised before Tk is reached, only for
  things the C types make checkable: a `NULL` string, an enum value out of
  range, a negative index other than `TKX_INDEX_END`, invalid sticky bits,
  negative padding.
- `TKX_ERR_EMPTY`: the value is empty (an unset nullable option, a widget
  not managed by the queried geometry manager, the bbox of an invisible
  item).  For enums an empty value is reported as `*_UNSET` with
  `TKX_OK`.
- `TKX_ERR_CONVERSION`: Tk returned a value that the C type cannot
  represent (e.g. `-underline end-1` read as `int`).

## Ownership and memory

- Strings passed in are copied before the call returns.
- Strings and lists returned through out-parameters belong to the caller:
  `tkx_free()` and `tkx_string_list_free()`.
- Widgets are owned by Tk.  Destroying a widget destroys its descendants,
  and all their handles become stale.
- Callbacks: see below.

## Callbacks

```c
typedef void (*TkxCommandFn)(TkxId widget, void *user_data);
typedef void (*TkxEventFn)(const TkxEvent *event, void *user_data);
typedef void (*TkxFreeFn)(void *user_data);
```

- Option callbacks (`tkx_ttk_button_set_command`), event bindings
  (`tkx_bind`) and timers (`tkx_after`) return a callback handle
  (`TKX_KIND_CALLBACK`).
- **Lifetime.**  A callback is released, and its `free_fn` runs exactly
  once, when any of these happens:
  - it is removed with `tkx_callback_remove`;
  - it is replaced by a new registration for the same option or event
    sequence (one per widget and sequence);
  - its widget is destroyed;
  - a one-shot timer fires;
  - `tkx_app_shutdown` runs.

  If registration fails, ownership of `user_data` stays with the caller.
- **Reentrancy.**  Callbacks may call any tkx function: create, configure
  or destroy widgets (including their own widget) and remove themselves.
  While a callback runs, its record is pinned; a release during the call
  invalidates the handle immediately and defers `free_fn` until the call
  returns.  The `command-1.7`, `command-1.8` and `command-1.9` tests cover
  this.
- **Stale scripts.**  The script stored in Tk is
  `::tkx::cb <callback-handle> ?%-fields?`.  If it is evaluated after the
  callback was released, the handle lookup fails and nothing is called.
- **Event fields.**  `TkxEvent` carries the widget handle, the sequence,
  pointer coordinates, button, keycode, keysym, text, size, state and
  wheel delta.  They are filled from Tk's `%`-substitutions, which Tk
  quotes itself.

## Generic interfaces (escape hatches)

- `tkx_widget_set/get_string|int|double(w, "-option", …)` accept any
  option in the class metadata, aliases included.  They refuse options
  flagged as holding Tcl code or Tcl variable names (`-command`,
  `-textvariable`, `-validatecommand`, `-takefocus`, …) with
  `TKX_ERR_UNSUPPORTED`, so no Tcl code can enter through them.
- `tkx_widget_call(w, "subcommand", argc, argv, &result)` invokes an
  extracted subcommand, with each argument as one literal word.  It
  refuses `cget`/`configure` and every subcommand whose evidence shows an
  argument reaching a script evaluator (`instate`, treeview `tag`), or
  which configures sub-objects with script-valued options (treeview
  `heading`).
- `tkx_class_option_count/tkx_class_option(kind, i)` expose the generated
  metadata: name, database name and class, value type, flags, aliases,
  enum values and source provenance (e.g. `generic/ttk/ttkButton.c:62`).
  Language bindings can use them to build higher-level APIs at run time.

## Value types

| Tk option type | C setter parameter | C getter out-parameter |
|---|---|---|
| BOOLEAN | `int` (0/1) | `int *` |
| INT | `int` | `int *` |
| DOUBLE | `double` | `double *` |
| STRING, COLOR, BORDER, FONT, CURSOR | `const char *` | `char **` (free with `tkx_free`) |
| STRING_TABLE, RELIEF, JUSTIFY, ANCHOR | generated enum (`TkxCompound`, `TkxRelief`, …) | enum `*` (`*_UNSET` for empty) |
| PIXELS | `int` (pixels) | `int *` (converted with `Tk_GetPixelsFromObj`, so `"1c"` reads as pixels) |
| INDEX | `int` (`TKX_INDEX_END` = "end") | `int *` |
| WINDOW | `TkxId` | `TkxId *` |
| STRING holding a list (overlay) | `const char *const *, size_t` | `TkxStringList *` |
| STRING holding a script (overlay) | `TkxCommandFn, void *, TkxFreeFn` | — |

Geometry-manager values add `sticky` (`TKX_STICKY_*` flags), `padding`
(two ints, before/after) and widget handles for `-in`, `-after` and
`-before`.

Nullable options (`TK_OPTION_NULL_OK`) of non-string type get an extra
`tkx_<class>_unset_<option>` that sets the empty value.

## Tcl/Tk build configuration

`tools/deps.sh` builds the pinned release with `--enable-shared`:

| platform | configure | Tk options |
|---|---|---|
| Linux/Unix | `unix/configure` | `--disable-xft --disable-bidi` (no Xft or HarfBuzz development headers needed; core X fonts) |
| macOS | `unix/configure` | `--enable-aqua` |
| Windows (MSYS2 MINGW64) | `win/configure` | `--enable-64bit` (also for Tcl) |

The Tk options affect rendering only, not any option table: the extractor
reads the source, not the build.  The Makefile takes link flags from the
installed `tclConfig.sh`/`tkConfig.sh`, which know each platform's library
names (`libtcl9tk9.1.so`, `libtcl9tk9.1.dylib`, `tcl9tk91.dll`).  On Linux
and macOS the shared libraries carry an rpath (`libtkx.dylib` has the
install name `@rpath/libtkx.dylib`), so no installation is needed.
Windows has no rpath: the Tcl/Tk DLLs and `libtkx.dll` must be on `PATH`,
which `make test` arranges; `libtkx.dll.a` is the import library.

## Platforms

Extraction evaluates every source file for three platform configurations
(`unix`, `win`, `macos`; see `generator/config.tcl`).  Defaults that differ
per platform are recorded per platform, such as `DEF_FRAME_BG_COLOR`,
which is `#d9d9d9`, `SystemButtonFace` and `systemWindowBackgroundColor`
respectively.  They appear only in documentation and metadata, never in
behaviour, because Tk applies its own defaults.  No option table of the
selected classes differs between platforms in 9.1.0.  So the generated C
contains no platform conditionals.

The library, the test bridge and the examples are built and the full suite
runs in CI on Linux/X11 (Xvfb), macOS/Aqua and Windows (MSYS2 MINGW64);
see COVERAGE for the results.  The handwritten runtime has three
platform-specific points:

- **Embedded start-up (Windows).**  `TclZipfs_AppHook` takes a
  wide-character `argv` on Windows; tkx passes a dummy one, since Tcl
  finds the executable itself there.
- **Tk Aqua and the host's stdio (macOS).**  On its first initialisation
  Tk Aqua checks stdin.  If stdin looks like `/dev/null` (a program
  started from Finder or by a CI runner), Tk either opens a Tk console
  window or, when the host has a startup script, `dup2`s `/dev/null` over
  stdout and stderr.  A library must not do either to its host, so on
  macOS tkx shows stdin to Tk as an empty pipe while `Tk_Init` runs and
  then restores it.
- **Idle work after `Tk_Init` (all platforms; needed on macOS).**  Tk Aqua's
  first initialisation schedules an idle callback that holds a raw
  pointer to the root `NSWindow` and is never cancelled.  `tkx_app_init`
  therefore runs pending idle callbacks before it returns (after the
  optional `withdraw`), so an application shut down right after start-up
  cannot run that callback against a destroyed window.

One Tcl portability rule surfaced in the test bridge rather than the
library: a thread created with `Tcl_CreateThread` must end with
`Tcl_ExitThread`.  On Windows `Tcl_JoinThread` is signalled only from
there, so a thread that just returns leaves its joiner waiting forever.
