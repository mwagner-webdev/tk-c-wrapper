/*
 * tkx_internal.h -- private interface between the handwritten runtime and
 * the generated code.  Not installed; may include Tcl/Tk headers.
 */
#ifndef TKX_INTERNAL_H
#define TKX_INTERNAL_H

#define TKX_BUILD 1
#include "tkx.h"
#include <tcl.h>
#include <tk.h>

/* ----- handles (tkx_handles.c) ----- */

#define TKX__INDEX_BITS 24
#define TKX__GEN_BITS 24
#define TKX__INDEX_MASK ((1u << TKX__INDEX_BITS) - 1u)
#define TKX__GEN_MASK ((1u << TKX__GEN_BITS) - 1u)

TkxId tkx__handle_alloc(int kind, void *object);
void *tkx__handle_lookup(TkxId id, int kind, TkxStatus *status);
void tkx__handle_release(TkxId id);
void tkx__handles_reset_all(void);   /* invalidate every live handle */
unsigned tkx__app_serial(void);
void tkx__next_app_serial(void);

/* ----- runtime state (tkx_runtime.c) ----- */

typedef struct TkxCallback TkxCallback;

typedef struct TkxWidget {
    TkxId id;
    int kind;
    Tcl_Obj *path;            /* widget path name (owned reference) */
    Tk_Window tkwin;
    TkxCallback *callbacks;   /* callbacks owned by this widget */
    int destroyed;
} TkxWidget;

extern Tcl_Interp *tkx__interp;

/* Entry checks: reset the error state, verify the UI thread and an
 * initialised application. */
TkxStatus tkx__enter(void);
/* Entry check + handle validation.  kindMask: bitmask of accepted widget
 * kinds (bit k set => kind k accepted), 0 = any widget kind. */
TkxStatus tkx__widget(TkxId id, uint64_t kindMask, TkxWidget **out);
#define TKX__KINDBIT(k) ((uint64_t)1 << (k))

/* Error reporting. */
TkxStatus tkx__error(TkxStatus st, const char *fmt, ...);
TkxStatus tkx__tk_error(void);      /* TKX_ERR_TK with the interp result */
TkxStatus tkx__arg_error(const char *what);

/* Widget creation: "tkcmd newpath ?extra...?", registers the handle. */
TkxId tkx__create(int kind, const char *tkcmd, TkxId parent,
	int extrac, Tcl_Obj *const extrav[]);
TkxWidget *tkx__widget_by_path(const char *path);

/* Command invocation.  objv elements may have refcount 0; they are
 * retained for the call and released afterwards.  *result (if result is
 * non-NULL) receives a new reference. */
TkxStatus tkx__invoke(int objc, Tcl_Obj *const objv[], Tcl_Obj **result);
TkxStatus tkx__widget_call(TkxWidget *w, int objc, Tcl_Obj *const objv[],
	Tcl_Obj **result);
TkxStatus tkx__configure1(TkxWidget *w, const char *opt, Tcl_Obj *value);
TkxStatus tkx__cget(TkxWidget *w, const char *opt, Tcl_Obj **out);

/* Value construction (return objects with refcount 0; NULL + error on
 * failure). */
Tcl_Obj *tkx__str(const char *s);
Tcl_Obj *tkx__int(int v);
Tcl_Obj *tkx__bool(int v);
Tcl_Obj *tkx__double(double v);
Tcl_Obj *tkx__index(int v);
Tcl_Obj *tkx__strlist(const char *const *items, size_t n);
Tcl_Obj *tkx__enum(const char *const *table, int count, int value, int nullOk);
Tcl_Obj *tkx__window(TkxId id);
Tcl_Obj *tkx__sticky(unsigned flags);
Tcl_Obj *tkx__padding(int before, int after);
void tkx__discard(int objc, Tcl_Obj *const objv[]);  /* free refcount-0 objs */

/* Value conversion. */
TkxStatus tkx__to_string(Tcl_Obj *o, char **out);
TkxStatus tkx__to_int(Tcl_Obj *o, int *out);
TkxStatus tkx__to_bool(Tcl_Obj *o, int *out);
TkxStatus tkx__to_double(Tcl_Obj *o, double *out);
TkxStatus tkx__to_pixels(TkxWidget *w, Tcl_Obj *o, int *out);
TkxStatus tkx__to_enum(Tcl_Obj *o, const char *const *table, int count, int *out);
TkxStatus tkx__to_window(Tcl_Obj *o, TkxId *out);
TkxStatus tkx__to_strlist(Tcl_Obj *o, TkxStringList *out);
TkxStatus tkx__to_box(Tcl_Obj *o, TkxBox *out);
TkxStatus tkx__to_sticky(Tcl_Obj *o, unsigned *out);
TkxStatus tkx__to_padding(TkxWidget *w, Tcl_Obj *o, int *before, int *after);
TkxStatus tkx__dict_get(Tcl_Obj *dict, const char *key, Tcl_Obj **out);

/* ----- callbacks (tkx_callbacks.c) ----- */

TkxId tkx__callback_option(TkxWidget *w, const char *option,
	TkxCommandFn fn, void *userData, TkxFreeFn freeFn);
void tkx__callbacks_widget_destroyed(TkxWidget *w);
void tkx__callbacks_shutdown(void);
int tkx__callbacks_init(Tcl_Interp *interp);

/* ----- generated metadata (tkx_generated.c) ----- */

/* refused: 1 if tkx_widget_call() must refuse the subcommand (cget and
 * configure, or an argument Tk evaluates as a script). */
typedef struct TkxSubcommandInfo {
    const char *name;
    int refused;
} TkxSubcommandInfo;

typedef struct TkxClassInfo {
    int kind;
    const char *command;          /* Tk command, e.g. "ttk::button" */
    const TkxOptionInfo *options;
    int optionCount;
    const struct TkxSubcommandInfo *subcommands;
    int subcommandCount;
} TkxClassInfo;

extern const TkxClassInfo tkx__classes[];
extern const int tkx__class_count;
const TkxClassInfo *tkx__class_info(int kind);

#endif /* TKX_INTERNAL_H */
