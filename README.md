# tkx — a generated C API for Tcl/Tk

tkx exposes Tk's existing widgets and geometry managers to C (and to anything
that can call C) through a plain C ABI with opaque 64-bit handles.  Consumers
do not write Tcl, see `Tcl_Obj`, or manage widget path names.  Tk does all
the work: its widgets, themes, `grid` and `pack` run unchanged behind the
API.

Most of the API is **generated from Tk's own C sources**.  The generator
reads the declarative tables in Tk 9.1.0 (`Tk_OptionSpec`, `Ttk_Ensemble`,
`WidgetSpec`, string tables, `RegisterWidget` calls, the `TkCmd` table) and,
in a constrained way, the bodies of subcommand implementations and
geometry-manager option parsers.  A small schema overlay supplies the
semantics the sources do not declare.  The runtime underneath (handles,
event loop, callbacks) is handwritten.

```c
#include "tkx.h"

static void on_click(TkxId button, void *label) {
    tkx_ttk_label_set_text(*(TkxId *)label, "clicked");
}

int main(void) {
    tkx_app_init(NULL);
    TkxId win = tkx_app_main_window();
    TkxId label = tkx_ttk_label_create(win);
    TkxId button = tkx_ttk_button_create(win);
    tkx_ttk_label_set_text(label, "Hello");
    tkx_ttk_button_set_text(button, "Press");
    tkx_ttk_button_set_command(button, on_click, &label, NULL);
    tkx_grid(label, 0, 0);
    tkx_grid(button, 1, 0);
    tkx_grid_set_sticky(button, TKX_STICKY_E | TKX_STICKY_W);
    tkx_app_run();
    tkx_app_shutdown();
}
```

## Status

| | |
|---|---|
| Tk baseline | Tcl/Tk **9.1.0** (manifest `8758d345…`), built from the official source release |
| Also tested | Tcl/Tk 9.0.4, with an API generated from the 9.0.4 sources (`make compat`) |
| Widget classes discovered | 22: all 20 ttk widgets + classic `frame`, `toplevel` |
| Classes with generated C functions | `toplevel`, `frame`, `ttk::frame`, `ttk::label`, `ttk::button`, `ttk::entry`, `ttk::treeview` |
| Geometry managers | `grid`, `pack` (option names and value types from Tk's parsers) |
| Generated functions | 370: 235 from declarative tables, 86 inferred from function bodies, 49 with a schema overlay |
| Tests | tcltest, 151 tests. Tk 9.1.0: 151 passed. Tk 9.0.4: 147 passed, 4 skipped (9.1-only features). Every generated function is called successfully by at least one test; most results are compared with what Tk itself reports (`cget`, `grid info`, `winfo`). |

The numbers come from `docs/COVERAGE_TABLES.md` (generated) and test runs; see
[docs/COVERAGE.md](docs/COVERAGE.md).

## Repository layout

```
include/tkx.h              public API: runtime contract (handwritten)
include/tkx_generated.h    public API: widgets, enums, geometry (GENERATED)
src/tkx_runtime.c          lifecycle, event loop, errors, invocation, conversions
src/tkx_handles.c          generational handle registry
src/tkx_callbacks.c        C callbacks for options, bindings, timers
src/tkx_generated.c        generated implementation + class metadata (GENERATED)
generator/                 Tcl: lexer, preprocessor, parser, extractor, generator, check
schema/overrides.tcl       Approach 2 overlays (every entry justified and verified)
generated/api.json         every generated function with provenance (GENERATED)
generated/coverage.json    machine-readable coverage report (GENERATED)
tests/                     tcltest suite + C test bridge (+ generated adapters)
examples/hello.c layout.c  standalone C programs
tools/deps.sh              pinned Tcl/Tk download + build (SHA-256 checked)
tools/irdiff.tcl           schema diff between two Tk source trees
tools/coverage_summary.tcl regenerates docs/COVERAGE_TABLES.md
docs/                      DESIGN, EXTRACTION, COVERAGE, LIMITATIONS
```

## Build and test

Requirements: a C11 compiler, `make`, `curl`, `sha256sum`, the X11
development headers (`libx11-dev`), and Xvfb (`xvfb-run`) for headless
display tests.  No system Tcl/Tk is used; the pinned release is built
locally.

```bash
make deps            # download Tcl/Tk 9.1.0 (SHA-256 checked) and build into deps/9.1.0
make                 # libtkx.so, test bridge, examples, header self-containment check
make test            # full tcltest suite (runs under xvfb-run when DISPLAY is unset)
make check-generated # fail if regenerating from the Tk sources changes committed files
```

Other targets:

```bash
make generate        # regenerate include/tkx_generated.h, src/tkx_generated.c, ...
make test-headless   # generator/ABI tests only; display tests are reported as skipped
make compat          # build + test against Tk 9.0.4 with an API generated from 9.0.4
```

Equivalent direct invocations (the Makefile only sets these variables):

```bash
TKX_BUILD=build/9.1.0 xvfb-run -a deps/9.1.0/install/bin/tclsh9.1 tests/all.tcl
```

```bash
deps/9.1.0/install/bin/tclsh9.1 generator/generate.tcl --tk-src deps/9.1.0/src/tk9.1.0 --tcl-src deps/9.1.0/src/tcl9.1.0 --out .
```

Running the examples (they need a display; with `TKX_EXAMPLE_AUTOCLOSE=1`
they run a scripted interaction and exit):

```bash
xvfb-run -a env TKX_EXAMPLE_AUTOCLOSE=1 build/9.1.0/layout
```

## Documentation

- [docs/DESIGN.md](docs/DESIGN.md): architecture, handles, event loop, ownership, errors, threading
- [docs/EXTRACTION.md](docs/EXTRACTION.md): the three approaches, the experiments, and what worked
- [docs/COVERAGE.md](docs/COVERAGE.md): quantitative coverage and test results
- [docs/LIMITATIONS.md](docs/LIMITATIONS.md): what is not covered, and why
