# Extraction feasibility report

The research question: can Tk's own C sources be the source of truth for
generating most of a C wrapper?  Three approaches were tried in priority
order on Tk 9.1.0, on two structurally different widget families: ttk
widgets (`WidgetSpec` + `Ttk_Ensemble`) and classic widgets (one creation
function, option table chosen at run time), plus the geometry managers
`grid` and `pack`, which have no declarative tables at all.

**Result.** Approach 1 carries the large majority of the API.  The
declarative tables (tier A) give all options of all 22 widget classes
exactly.  Constrained analysis of function bodies (tier B) types the
geometry managers completely and fully infers 71 of 243 subcommands.
Approach 2 (46 overlay entries, each checked against the sources) closes
the semantic gaps.  Approach 3 is limited to the runtime mechanisms and to
`wm`, `winfo`, `bind` and `destroy`: 47 public functions.  Of the 370
generated functions, 235 come from declarative tables, 86 from inferred
evidence and 49 needed an overlay.  All 370 are called successfully by the
tests, and most results are compared with what Tk itself reports.

## Pipeline

```
Tk source tree ─► clex.tcl ─► cpp.tcl (×3 platforms) ─► cparse.tcl ─► extract.tcl ─► resolve.tcl ─► IR
   (pinned)       lexer        restricted preprocessor   declarations   tier A         tier B +
                                                          initializers                   classes
IR + schema/overrides.tcl ─► generate.tcl ─► tkx_generated.{h,c}, bridge adapters, api.json, coverage.json
                                     check.tcl ─► fail on drift from committed files
```

All of it is Tcl (about 4,900 lines) and runs in about 7 s for three
platform configurations (22 source files, about 856,000 tokens lexed in
total).

### Lexer (`generator/clex.tcl`)

One regular-expression alternation without capture groups, so the
tokenizing loop runs in C.  It recognises comments (block comments are
written without non-greedy quantifiers, which Tcl handles badly when
mixed), string and char literals with escapes, identifiers, preprocessing
numbers, punctuators and backslash-newline continuations.  Preprocessor
directives are grouped into one token, with a whitespace-before flag so
`#define F(x)` and `#define F (x)` are distinguished.  Any character
outside C's lexical classes is an error with file:line.  The only
exception is Objective-C `@`, which macOS headers contain.

### Restricted preprocessor (`generator/cpp.tcl`)

- `#if/#ifdef/#ifndef/#elif/#else/#endif` with integer expressions,
  `defined`, and macro expansion.  `#define`/`#undef` cover object-like,
  function-like and variadic macros with `#` and `##`.  `#include "…"`
  and `<…>` are resolved only inside the Tcl/Tk source trees; system
  headers are skipped and recorded.
- **Platform configurations.**  Each file is preprocessed three times,
  with `unix` (nothing predefined), `win` (`_WIN32`) and `macos`
  (`MAC_OSX_TK`, `__APPLE__`, `__OBJC__`).  This is how the per-platform
  defaults (`tkUnixDefault.h` / `tkWinDefault.h` / `tkMacOSXDefault.h`)
  are obtained.
- **Assumptions are recorded, not hidden.**  An undefined name in `#if`
  evaluates to 0, as in C.  If the name is not a platform macro and is
  `#define`d nowhere in the source trees, it is an *assumption* (a
  configure-time option such as `HAVE_XFT`).  Tokens produced under an
  assumption carry it.  A region skipped because of an assumption is
  recorded by position, so a table that lost an entry that way is
  reported (fixture test `extract-1.4`).  Conditions whose value cannot
  change with the assumed name (`#if defined(X) || 1`) record nothing
  (`cpp-1.6`).
- **Position-aware macros.**  Definitions are kept with their position in
  the token stream, so expansion at a point uses the definition in force
  there.
- **Compiler-assisted preprocessing** (`cc -E`) was considered and not
  used.  It needs a complete platform toolchain and headers for each
  configuration (no `windows.h` or Cocoa on Linux), so it can evaluate
  only the host platform.  It also discards the macro names that the
  extractor uses for provenance and symbolic interpretation: flags are
  read as `TK_OPTION_NULL_OK` terms, not numbers.  It would remain
  deterministic, but it would lose platform coverage and provenance.

### Constrained parser (`generator/cparse.tcl`)

This is not a C parser.  It indexes exactly these shapes, with exact
brace/paren/bracket matching on the token stream:

- initialised objects `<type> NAME[...] = { ... };`
- function definitions
- enums
- struct definitions and struct typedefs
- local initialised arrays and enums inside function bodies (grid and
  pack keep their option names there)

Initializers are parsed into a tree of brace groups and expressions.
Designated initializers and braces inside expressions are rejected.

Two lessons from the real sources:

- `TTK_BEGIN_LAYOUT … TTK_END_LAYOUT` expands to a complete declaration,
  but in unexpanded tokens it has no `;`.  The following option table then
  absorbed the layout tokens into its type.  The parser therefore asks the
  macro table whether an identifier's expansion ends a statement.
- To make sure such problems can never cause a silent omission, every
  initialised declaration that *mentions* `Tk_OptionSpec`, `Ttk_Ensemble`,
  `WidgetSpec` or `TkCmd` must have one of the canonical forms, or
  extraction fails (`extract-2.4`).

## Approach 1 — deterministic extraction from the C sources

### Tier A: declarative tables (exact)

| construct | where | what is extracted |
|---|---|---|
| `Tk_OptionSpec[]` (33 tables, 222 entries) | ttk*.c, tkFrame.c | name, database name/class, type, default (through macros, per platform), flags (`NULL_OK`…), mono default, synonym target, string table, custom option, chain (`WIDGET_INHERIT_OPTIONS`, `TK_OPTION_END` clientData), typeMask (evaluated; `READONLY_OPTION` bit) |
| struct layouts | tk.h, ttkTheme.h, ttkWidget.h, tkWindow.c | field order of `Tk_OptionSpec`, `Ttk_Ensemble`, `WidgetSpec_`, `TkCmd`, read from the headers rather than assumed |
| `Tk_OptionType` enum | tk.h | valid option types |
| `Ttk_Ensemble[]` (22) | ttk*.c | subcommand tree, implementing functions, nested ensembles |
| `WidgetSpec` (20) | ttk*.c | class name, option table, command table |
| `RegisterWidget(...)` (20) | ttk*.c | widget command → WidgetSpec (classes are discovered, not listed) |
| `TkCmd commands[]` (62) | tkWindow.c | Tk command → C function (5 entries exist only on Windows/macOS) |
| string tables (39) | everywhere | enumeration values (`ttkCompoundStrings`, `sideNames`, …) |
| built-in enum binding | tkConfig.c | `TK_OPTION_RELIEF/JUSTIFY/ANCHOR` → `tkReliefStrings`/… found in `DoObjConfig`'s `case TK_OPTION_X:` blocks |

Option chains are flattened with Tk's lookup rule: the first table in the
chain wins (`GetOption` in tkConfig.c).  Shadowed entries are reported.

**Coverage, tier A alone.**  All 321 options of the 22 discovered classes
are extracted with name, type, default, flags and provenance.  268 of the
315 non-alias options can be mapped to typed C accessors from this
information alone (236 read/write, 31 read-only, 1 callback via overlay).

**What tier A cannot know:**

- that a `TK_OPTION_STRING` is a script (`-command`), a Tcl variable name
  (`-textvariable`) or a Tcl list (`-columns`);
- which classic options are create-only (checked imperatively with
  `strncmp` in `FrameWidgetObjCmd`);
- which option table a classic command uses (selected at run time by
  `optionSpecs[type]`);
- anything about subcommand arguments or results;
- anything about grid/pack, whose options are parsed in `switch`
  statements.

### Tier B: constrained evidence from function bodies

Inference uses a small, explicit vocabulary of Tk/Tcl C functions
(`generator/config.tcl`).  Conversions include `Tcl_GetIntFromObj` → int,
`Tk_GetPixelsFromObj` → pixels, `TkParsePadAmount` → padding,
`StringToSticky` → sticky, `Tcl_GetIndexFromObj(…, table, …)` → enum of
that table, `EntryIndex` → index, `FindItem` → treeview item, and
`Tcl_EvalObjEx` / `Tk_CreateBinding@4` → *script*.  Results map
`Tcl_NewBooleanObj` → boolean, `Ttk_NewBoxObj` → box, and so on.  Every
inference records the function name and the source line.

**Subcommands.**  For every leaf of every ensemble, the implementing
function is found and analysed:

- **Arity:** the `if (COND) { Tcl_WrongNumArgs(...); return TCL_ERROR; }`
  guard is evaluated for every argument count.  Any `objc` test *before*
  the guard means several forms (`$w state` vs `$w state spec`).  That is
  reported, not collapsed (this bug was found and fixed during
  development; test `evidence-1.4`).
- **Arguments:** every occurrence of `objv[N]` is classified through its
  call chain, ignoring error-message formatting.  If occurrences disagree
  (treeview `move` tries an argument as `before|after` and otherwise as
  an item), the argument is polymorphic and left untyped (`evidence-1.3`).
- **Result:** `Tcl_SetObjResult(interp, CTOR(...))` outside error paths,
  including variables assigned from a constructor and `item->idObj`.
  A result delegated to another function is unknown.
- **Script arguments:** any argument reaching a script evaluator, directly
  or through one local variable (`script = Tcl_GetString(objv[5]);
  Tk_CreateBinding(…, script, …)`), marks the subcommand as taking Tcl
  code.  Such subcommands are never generated and are refused by the
  generic call.  This also was found by testing: an earlier version had
  generated `tkx_ttk_treeview_tag_bind(…, const char *script)`.

"Complete" evidence (arity, every argument and the result known, no script
argument) is generated without any overlay.  Across all 22 classes: **71
complete**, 107 partial, 21 with script arguments, and 44 `cget`/`configure`
(covered by the option accessors).

**Geometry managers.**  `grid` and `pack` are found in the `TkCmd` table.
The subcommand table is the string array passed with `objv[1]`; a second
array without deprecated names identifies `grid slaves`/`pack slaves` as
deprecated.  It is paired with the local `enum` of the same length.  Each
subcommand's handler is the first non-API call that receives `objv`.  In
each handler, the option table (`objv[i]`) is paired with its enum, and
each option's value type comes from the conversion applied to `objv[i+1]`
in its `case K:` or `if (index == K)` block.  `pack -fill`, which is
parsed with a `strcmp` chain, becomes an enum of the compared literals.

Result: **25 of 27** option names in the handler tables have a typed
value.  The 2 untyped are `-column`/`-row` of `grid content`, which is
not used.  Getters are generated only for options that appear as
literals in the `info` subcommand's implementation, so pack's `-after`
and `-before`, which `pack info` never reports, have setters only.

### What Approach 1 generated correctly

All 235 "extracted" and 86 "inferred" functions are called successfully by
the tests against Tk 9.1.0.  Every option accessor goes through a
data-driven round trip checked against Tk's own `cget`.  Geometry
functions are checked through `grid info`/`pack info`/`winfo` and by
comparing with the same layout built in plain Tcl/Tk (`compare-1.1`,
identical requested sizes).  Most inferred subcommands are asserted on
their results; a few (treeview `drag`/`drop`) are only checked for
success.

### What failed or needed more information

- Semantic types of `TK_OPTION_STRING`: scripts, variables, lists.
- `TK_OPTION_CUSTOM` (`-locale`): the value syntax is defined by custom C
  code, so it is reported as `unsupported` (3 options across all classes).
- Subcommands with option-value tails (`item`, `insert`, `heading`),
  multi-form commands (`state`, `focus`, `selection`), and results
  delegated to internal helpers (`InsertChars`, `DeleteChars`).
- The classic class binding (code, not table).
- Sub-object option tables (treeview item/heading/column): extracted
  exactly, but bound to their subcommands only through a record field
  assigned at run time.

## Approach 2 — schema overlays

`schema/overrides.tcl` has 46 entries.  None restates extracted
information.  Each entry carries `why` and `evidence`, which the generator
or extractor verifies against the current sources.  If the evidence no
longer matches, generation fails with `overlay drift`.  The `gen-1.1` and
`gen-1.2` tests mutate an overlay and check that this happens.

| kind | entries | example | verified evidence |
|---|---|---|---|
| classic class binding | 2 | `frame` → `optionSpecs[TYPE_FRAME]`, create-only `-class -colormap -container -visual` | TkCmd maps the command to the creator; the creator body references exactly that enum member; the dispatch array element at that ordinal; each create-only name is a literal in `FrameWidgetObjCmd` |
| option semantics | 12 | `ttk::button -command` is a callback; `-textvariable` excluded; `-columns` is a list; `-displaycolumns` is a list *or the literal* `#all` | option type, database class, default (`#all`) |
| subcommand signatures | 11 | `ttk::entry insert(index, text)`, `state_set`/`state_get`, treeview `insert(parent, index, ?id?)` | the usage string extracted from `Tcl_WrongNumArgs` |
| sub-object tables | 3 | treeview `item` ↔ `ItemOptionSpecs` | `X.itemOptionTable = Tk_CreateOptionTable(interp, ItemOptionSpecs)` exists; the subcommand delegates to `ConfigureItem`, which uses that field |
| sub-object option semantics | 5 | item `-values` is a list; heading `-command` excluded | type, database class |
| geometry signatures/composites | 13 | `propagate_get/_set`, `size`, composite `tkx_grid(w,row,col)` | subcommand exists in the extracted table; usage string matches |

The 49 "schema" functions come from these entries.  The two classic
`create` functions are labelled "schema" because of the binding; their 60
option accessors are labelled "extracted", because the option records
themselves come from tier A.

**`#all` is an example of a semantic trap that only behavioural testing
revealed.**  ttkTreeview.c compares the option's *string* with `#all`
(`strcmp`) before parsing it as a list.  A one-element Tcl list `{#all}`
has a different string, so a generic "list" mapping silently broke the
special value.  The overlay records the literal, and the generator passes
it unquoted.

### Synchronisation: does a Tk update give a predictable diff?

`tools/irdiff.tcl` extracts two source trees and diffs the normalised
schema.  The result for Tk 9.0.4 → 9.1.0 is in
`docs/schema-diff-9.0.4-to-9.1.0.txt`:

- **563 → 610 entries: 47 added, 41 changed, 0 removed.**
- Added: the `ttk::toggleswitch` widget, 17 new treeview subcommands
  (`depth`, `haschildren`, `collapse`, `range`, …), new options
  (`-textangle`, `-headingheight`, `-rowheight`, `-locale`).
- Changed: `-selectmode` gained `single`/`multiple`; `ttk::label -anchor`
  and `-justify` lost their `w`/`left` defaults and became nullable;
  storage flags changed (`TK_OPTION_VAR(bool)`), with no effect on the API;
  usage strings were reworded.

Every line names a class, an option or subcommand, and a field, so review
is mechanical.  Generating for 9.0.4 with the 9.1.0 overlays stopped at
exactly two entries.  Treeview `focus` was worded `?newFocus?` instead of
`?item?`, and `insert` lacked the new `before|after` form.  Both were
reviewed and accepted as equivalent (`usageAlternatives`).  The 9.0.4 API
(359 functions) was then built and tested against the 9.0.4 runtime.  The
same suite passes, except 4 tests of 9.1-only features, which are skipped
with constraint `tk91`.

**Maintenance consequence.**  A Tk update is handled by regenerating,
reading the generator's drift errors, and reading the schema diff.  Most
changes reach the API without human input: new options, enum values,
defaults, new simple subcommands.  Overlay entries fail loudly when their
evidence changes; they are never silently stale.

## Approach 3 — handwritten C

The 47 public functions in `include/tkx.h` are handwritten.  Their
implementations are in `src/tkx_runtime.c`, `src/tkx_handles.c` and
`src/tkx_callbacks.c`.

| group | functions | why not generated |
|---|---|---|
| lifecycle, event loop, threads | `tkx_app_*` (11) | interpreter creation, Tk initialisation, the notifier and the UI-thread contract have no description in Tk's widget sources |
| errors, memory | `tkx_last_error*`, `tkx_status_name`, `tkx_free`, `tkx_string_list_free` (5) | runtime contract |
| handles | `tkx_handle_*` (4) | runtime mechanism (see DESIGN) |
| callbacks | `tkx_bind`, `tkx_callback_remove`, `tkx_after` (3) | Tk delivers callbacks by evaluating scripts; the script↔C-function bridge and its lifetime rules are runtime mechanisms. `bind` is not a widget command: `Tk_BindObjCmd` parses event sequences in C (tkBind.c) with no declarative table |
| toplevel windows | `tkx_window_*` (7) | `wm` is one large string switch per platform (tkUnixWm.c, tkWinWm.c, tkMacOSXWm.c) with irregular, platform-dependent signatures; only 5 operations are needed |
| generic widget queries | `tkx_widget_destroy/parent/requested_size/geometry/is_mapped/manager/focus` (7) | `destroy`, `winfo` and `focus` are not widget subcommands; `winfo` is a 40-way string switch. They use the Tk C API (`Tk_ReqWidth`, `Tk_Parent`) or one command each |
| escape hatches and metadata | `tkx_widget_set/get_*` (6), `tkx_widget_call`, `tkx_kind_name`, `tkx_class_option_count`, `tkx_class_option` (4) | generic code driven by the generated metadata tables |

The handwritten runtime is about 2,300 lines of C.  The generated
implementation is about 8,200 lines.

## Comparison and selection

| criterion | Approach 1 | Approach 2 | Approach 3 |
|---|---|---|---|
| share of generated functions | 321 / 370 (87 %) | 49 / 370 (13 %) | — (47 runtime functions) |
| correctness evidence | 370/370 functions behaviourally tested | same | runtime tests (handles, callbacks, lifecycle, threads) |
| determinism | byte-identical regeneration (`gen-1.3`), committed output checked (`gen-1.4`, `make check-generated`) | overlay is code-reviewed data | n/a |
| update effort | none for additive changes | overlay entries fail loudly on drift | manual |
| failure mode | unsupported constructs stop extraction with file:line | drift error | — |

**Selection:** Approach 1 is used wherever its evidence is complete.
Approach 2 is applied per option and per operation where semantics are
missing.  Approach 3 is used only for mechanisms with no source-level
description.  None of the approaches was abandoned for a whole widget
family.
