/*
 * test_bridge.h -- shared declarations of the tcltest bridge.
 *
 * The bridge is a Tcl extension (libtkxtest.so) loaded into the tclsh
 * that runs tcltest.  It calls the *compiled* tkx C API; the tkx
 * application runs in its own interpreter, separate from the test
 * interpreter.
 */
#ifndef TKX_TEST_BRIDGE_H
#define TKX_TEST_BRIDGE_H

#include <tcl.h>
#include "tkx.h"

typedef struct TkxbStrv {
    size_t count;
    const char **items;
    Tcl_Obj *keep;
} TkxbStrv;

typedef struct TkxbFunc {
    const char *name;
    int (*fn)(Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[]);
} TkxbFunc;

extern const TkxbFunc tkxb_generated[];

int tkxb_status(Tcl_Interp *ip, TkxStatus st);
int tkxb_is_omitted(Tcl_Obj *o);
int tkxb_get_id(Tcl_Interp *ip, Tcl_Obj *o, TkxId *out);
int tkxb_get_int(Tcl_Interp *ip, Tcl_Obj *o, int *out);
int tkxb_get_bool(Tcl_Interp *ip, Tcl_Obj *o, int *out);
int tkxb_get_index(Tcl_Interp *ip, Tcl_Obj *o, int *out);
int tkxb_get_double(Tcl_Interp *ip, Tcl_Obj *o, double *out);
int tkxb_get_sticky(Tcl_Interp *ip, Tcl_Obj *o, unsigned *out);
int tkxb_get_strv(Tcl_Interp *ip, Tcl_Obj *o, TkxbStrv *out);
void tkxb_free_strv(TkxbStrv *v);
int tkxb_get_pair(Tcl_Interp *ip, Tcl_Obj *o, int *a, int *b);
int tkxb_get_enum(Tcl_Interp *ip, Tcl_Obj *o, const char *const *table, int n, int *out);
void tkxb_set_strlist(Tcl_Interp *ip, TkxStringList *l);
void tkxb_set_box(Tcl_Interp *ip, TkxBox *b);
void tkxb_set_pair(Tcl_Interp *ip, int a, int b);
void tkxb_set_enum(Tcl_Interp *ip, const char *const *table, int n, int v);

typedef TkxId (*TkxbCommandSetter)(TkxId, TkxCommandFn, void *, TkxFreeFn);
TkxId tkxb_register_command(Tcl_Interp *ip, TkxId widget, Tcl_Obj *script,
	TkxbCommandSetter setter);

/* Test-only hooks exported by libtkx (not part of the public API). */
TKX_API void *tkx__test_interp(void);
TKX_API const char *tkx__test_path(TkxId id);

#endif
