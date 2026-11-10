/*
 * test_bridge.c -- tcltest bridge to the compiled tkx C API.
 *
 * Loaded into the tclsh running tests/all.tcl with
 *     load build/<ver>/libtkxtest.so Tkxtest
 * Commands live in the ::tkx namespace of the *test* interpreter.  The
 * tkx application created by tkx::app_init runs in a separate
 * interpreter owned by libtkx.  Callbacks registered from tests run a
 * Tcl script in the test interpreter, so tests can observe them.
 */
#include "test_bridge.h"
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define OMIT "tkx::omit"

static int freedCount = 0;        /* free_fn invocations (lifetime tests) */

/* ------------------------------------------------------------------ */
/* Conversion helpers used by the generated adapters                   */
/* ------------------------------------------------------------------ */

int
tkxb_status(Tcl_Interp *ip, TkxStatus st)
{
    Tcl_SetObjResult(ip, Tcl_ObjPrintf("%s: %s", tkx_status_name(st), tkx_last_error_message()));
    Tcl_SetErrorCode(ip, "TKX", tkx_status_name(st), (char *)NULL);
    return TCL_ERROR;
}

int
tkxb_is_omitted(Tcl_Obj *o)
{
    return strcmp(Tcl_GetString(o), OMIT) == 0;
}

int
tkxb_get_id(Tcl_Interp *ip, Tcl_Obj *o, TkxId *out)
{
    Tcl_WideInt w;
    if (Tcl_GetWideIntFromObj(ip, o, &w) != TCL_OK) {
	return TCL_ERROR;
    }
    *out = (TkxId)w;
    return TCL_OK;
}

int
tkxb_get_int(Tcl_Interp *ip, Tcl_Obj *o, int *out)
{
    return Tcl_GetIntFromObj(ip, o, out);
}

int
tkxb_get_bool(Tcl_Interp *ip, Tcl_Obj *o, int *out)
{
    return Tcl_GetBooleanFromObj(ip, o, out);
}

int
tkxb_get_index(Tcl_Interp *ip, Tcl_Obj *o, int *out)
{
    if (strcmp(Tcl_GetString(o), "end") == 0) {
	*out = TKX_INDEX_END;
	return TCL_OK;
    }
    return Tcl_GetIntFromObj(ip, o, out);
}

int
tkxb_get_double(Tcl_Interp *ip, Tcl_Obj *o, double *out)
{
    return Tcl_GetDoubleFromObj(ip, o, out);
}

int
tkxb_get_sticky(Tcl_Interp *ip, Tcl_Obj *o, unsigned *out)
{
    const char *s = Tcl_GetString(o);
    unsigned f = 0;
    int v;
    if (Tcl_GetIntFromObj(NULL, o, &v) == TCL_OK) {
	*out = (unsigned)v;
	return TCL_OK;
    }
    for (; *s; s++) {
	switch (*s) {
	case 'n': f |= TKX_STICKY_N; break;
	case 's': f |= TKX_STICKY_S; break;
	case 'e': f |= TKX_STICKY_E; break;
	case 'w': f |= TKX_STICKY_W; break;
	default:
	    Tcl_SetObjResult(ip, Tcl_NewStringObj("bad sticky", -1));
	    return TCL_ERROR;
	}
    }
    *out = f;
    return TCL_OK;
}

int
tkxb_get_strv(Tcl_Interp *ip, Tcl_Obj *o, TkxbStrv *out)
{
    Tcl_Size n, i;
    Tcl_Obj **e;
    if (Tcl_ListObjGetElements(ip, o, &n, &e) != TCL_OK) {
	return TCL_ERROR;
    }
    out->keep = o;
    Tcl_IncrRefCount(o);
    out->count = (size_t)n;
    out->items = (const char **)ckalloc(sizeof(char *) * (size_t)(n + 1));
    for (i = 0; i < n; i++) {
	out->items[i] = Tcl_GetString(e[i]);
    }
    return TCL_OK;
}

void
tkxb_free_strv(TkxbStrv *v)
{
    if (v->items != NULL) {
	ckfree(v->items);
    }
    if (v->keep != NULL) {
	Tcl_DecrRefCount(v->keep);
    }
    v->items = NULL;
    v->keep = NULL;
}

int
tkxb_get_pair(Tcl_Interp *ip, Tcl_Obj *o, int *a, int *b)
{
    Tcl_Size n;
    Tcl_Obj **e;
    if (Tcl_ListObjGetElements(ip, o, &n, &e) != TCL_OK || n < 1 || n > 2) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("expected 1 or 2 integers", -1));
	return TCL_ERROR;
    }
    if (Tcl_GetIntFromObj(ip, e[0], a) != TCL_OK
	    || Tcl_GetIntFromObj(ip, e[n - 1], b) != TCL_OK) {
	return TCL_ERROR;
    }
    return TCL_OK;
}

int
tkxb_get_enum(Tcl_Interp *ip, Tcl_Obj *o, const char *const *table, int n, int *out)
{
    const char *s = Tcl_GetString(o);
    int i;
    if (strcmp(s, "UNSET") == 0) {
	*out = -1;
	return TCL_OK;
    }
    for (i = 0; i < n; i++) {
	if (strcmp(s, table[i]) == 0) {
	    *out = i;
	    return TCL_OK;
	}
    }
    if (Tcl_GetIntFromObj(NULL, o, out) == TCL_OK) {
	return TCL_OK;          /* raw value, used to test range checks */
    }
    Tcl_SetObjResult(ip, Tcl_ObjPrintf("unknown enum value \"%s\"", s));
    return TCL_ERROR;
}

void
tkxb_set_strlist(Tcl_Interp *ip, TkxStringList *l)
{
    Tcl_Obj *r = Tcl_NewListObj(0, NULL);
    size_t i;
    for (i = 0; i < l->count; i++) {
	Tcl_ListObjAppendElement(NULL, r, Tcl_NewStringObj(l->items[i], -1));
    }
    Tcl_SetObjResult(ip, r);
}

void
tkxb_set_box(Tcl_Interp *ip, TkxBox *b)
{
    Tcl_Obj *v[4];
    v[0] = Tcl_NewWideIntObj(b->x);
    v[1] = Tcl_NewWideIntObj(b->y);
    v[2] = Tcl_NewWideIntObj(b->width);
    v[3] = Tcl_NewWideIntObj(b->height);
    Tcl_SetObjResult(ip, Tcl_NewListObj(4, v));
}

void
tkxb_set_pair(Tcl_Interp *ip, int a, int b)
{
    Tcl_Obj *v[2];
    v[0] = Tcl_NewWideIntObj(a);
    v[1] = Tcl_NewWideIntObj(b);
    Tcl_SetObjResult(ip, Tcl_NewListObj(2, v));
}

void
tkxb_set_enum(Tcl_Interp *ip, const char *const *table, int n, int v)
{
    if (v == -1) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("UNSET", -1));
    } else if (v >= 0 && v < n) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj(table[v], -1));
    } else {
	Tcl_SetObjResult(ip, Tcl_NewWideIntObj(v));
    }
}

/* ------------------------------------------------------------------ */
/* Callbacks that run Tcl scripts in the test interpreter              */
/* ------------------------------------------------------------------ */

typedef struct ScriptCb {
    Tcl_Interp *ip;
    Tcl_Obj *script;
} ScriptCb;

static void
ScriptFree(void *ud)
{
    ScriptCb *s = (ScriptCb *)ud;
    freedCount++;
    Tcl_DecrRefCount(s->script);
    ckfree(s);
}

static ScriptCb *
NewScriptCb(Tcl_Interp *ip, Tcl_Obj *script)
{
    ScriptCb *s = (ScriptCb *)ckalloc(sizeof(ScriptCb));
    s->ip = ip;
    s->script = script;
    Tcl_IncrRefCount(script);
    return s;
}

static void
RunScript(ScriptCb *s, Tcl_Obj *extra)
{
    Tcl_Obj *cmd = Tcl_DuplicateObj(s->script);
    Tcl_IncrRefCount(cmd);
    if (extra != NULL) {
	Tcl_ListObjAppendElement(NULL, cmd, extra);
    }
    if (Tcl_EvalObjEx(s->ip, cmd, TCL_EVAL_GLOBAL) != TCL_OK) {
	Tcl_BackgroundException(s->ip, TCL_ERROR);
    }
    Tcl_DecrRefCount(cmd);
}

static void
CommandCb(TkxId widget, void *ud)
{
    RunScript((ScriptCb *)ud, Tcl_NewWideIntObj((Tcl_WideInt)widget));
}

static void
EventCb(const TkxEvent *ev, void *ud)
{
    Tcl_Obj *d = Tcl_NewDictObj();
#define PUT(k, v) Tcl_DictObjPut(NULL, d, Tcl_NewStringObj(k, -1), v)
    PUT("widget", Tcl_NewWideIntObj((Tcl_WideInt)ev->widget));
    PUT("sequence", Tcl_NewStringObj(ev->sequence, -1));
    PUT("x", Tcl_NewWideIntObj(ev->x));
    PUT("y", Tcl_NewWideIntObj(ev->y));
    PUT("root_x", Tcl_NewWideIntObj(ev->root_x));
    PUT("root_y", Tcl_NewWideIntObj(ev->root_y));
    PUT("button", Tcl_NewWideIntObj(ev->button));
    PUT("keycode", Tcl_NewWideIntObj(ev->keycode));
    PUT("keysym", Tcl_NewStringObj(ev->keysym, -1));
    PUT("text", Tcl_NewStringObj(ev->text, -1));
    PUT("width", Tcl_NewWideIntObj(ev->width));
    PUT("height", Tcl_NewWideIntObj(ev->height));
    PUT("state", Tcl_NewWideIntObj(ev->state));
    PUT("delta", Tcl_NewWideIntObj(ev->delta));
#undef PUT
    RunScript((ScriptCb *)ud, d);
}

static void
TaskCb(void *ud)
{
    RunScript((ScriptCb *)ud, NULL);
}

TkxId
tkxb_register_command(Tcl_Interp *ip, TkxId widget, Tcl_Obj *script,
	TkxbCommandSetter setter)
{
    ScriptCb *s;
    TkxId id;
    if (script == NULL) {
	return setter(widget, NULL, NULL, NULL);
    }
    s = NewScriptCb(ip, script);
    id = setter(widget, CommandCb, s, ScriptFree);
    if (id == TKX_NULL_ID) {
	Tcl_DecrRefCount(s->script);   /* not taken over by tkx */
	ckfree(s);
    }
    return id;
}

/* ------------------------------------------------------------------ */
/* Bridge commands                                                     */
/* ------------------------------------------------------------------ */

#define ID_RESULT(ip, id) Tcl_SetObjResult(ip, Tcl_NewWideIntObj((Tcl_WideInt)(id)))

/* Successful calls per generated function (behavioural coverage). */
static Tcl_HashTable callCounts;
static int callCountsInit = 0;

static const TkxbFunc *
FindFn(const char *name)
{
    int lo = 0, hi, mid, c;
    for (hi = 0; tkxb_generated[hi].name != NULL; hi++) {}
    hi--;
    while (lo <= hi) {
	mid = (lo + hi) / 2;
	c = strcmp(name, tkxb_generated[mid].name);
	if (c == 0) {
	    return &tkxb_generated[mid];
	}
	if (c < 0) hi = mid - 1; else lo = mid + 1;
    }
    return NULL;
}

static int
FnCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    const TkxbFunc *f;
    int code;
    (void)cd;
    if (objc < 2) {
	Tcl_WrongNumArgs(ip, 1, objv, "function ?arg ...?");
	return TCL_ERROR;
    }
    f = FindFn(Tcl_GetString(objv[1]));
    if (f == NULL) {
	Tcl_SetObjResult(ip, Tcl_ObjPrintf("no generated function \"%s\"", Tcl_GetString(objv[1])));
	return TCL_ERROR;
    }
    code = f->fn(ip, objc - 2, objv + 2);
    if (code == TCL_OK) {
	int isNew;
	Tcl_HashEntry *he;
	if (!callCountsInit) {
	    Tcl_InitHashTable(&callCounts, TCL_STRING_KEYS);
	    callCountsInit = 1;
	}
	he = Tcl_CreateHashEntry(&callCounts, f->name, &isNew);
	Tcl_SetHashValue(he, (void *)((char *)Tcl_GetHashValue(he) + 1));
	if (isNew) Tcl_SetHashValue(he, (void *)1);
    }
    return code;
}

static int
FnInfoCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    const TkxbFunc *f;
    (void)cd;
    if (objc != 2 || (f = FindFn(Tcl_GetString(objv[1]))) == NULL) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("unknown function", -1));
	return TCL_ERROR;
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj(f->info, -1));
    return TCL_OK;
}

static int
FnCallsCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    Tcl_Obj *d = Tcl_NewDictObj();
    Tcl_HashSearch hs;
    Tcl_HashEntry *he;
    (void)cd; (void)objc; (void)objv;
    if (callCountsInit) {
	for (he = Tcl_FirstHashEntry(&callCounts, &hs); he; he = Tcl_NextHashEntry(&hs)) {
	    Tcl_DictObjPut(NULL, d, Tcl_NewStringObj(Tcl_GetHashKey(&callCounts, he), -1),
		    Tcl_NewWideIntObj((Tcl_WideInt)(intptr_t)Tcl_GetHashValue(he)));
	}
    }
    Tcl_SetObjResult(ip, d);
    return TCL_OK;
}

static int
FnListCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    Tcl_Obj *l = Tcl_NewListObj(0, NULL);
    int i;
    (void)cd; (void)objc; (void)objv;
    for (i = 0; tkxb_generated[i].name != NULL; i++) {
	Tcl_ListObjAppendElement(NULL, l, Tcl_NewStringObj(tkxb_generated[i].name, -1));
    }
    Tcl_SetObjResult(ip, l);
    return TCL_OK;
}

static int
AppInitCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    TkxAppConfig cfg;
    Tcl_Size i;
    TkxStatus st;
    (void)cd;
    memset(&cfg, 0, sizeof(cfg));
    cfg.struct_size = sizeof(cfg);
    cfg.host_initialized_tcl = 1;   /* the bridge runs inside tclsh */
    for (i = 1; i + 1 < objc; i += 2) {
	const char *k = Tcl_GetString(objv[i]);
	if (strcmp(k, "-withdraw") == 0) {
	    if (Tcl_GetBooleanFromObj(ip, objv[i + 1], &cfg.withdraw_main_window) != TCL_OK) {
		return TCL_ERROR;
	    }
	} else if (strcmp(k, "-legacy_struct") == 0) {
	    /* Simulate a caller compiled against an older, shorter config
	     * struct that ends before withdraw_main_window. */
	    int legacy;
	    if (Tcl_GetBooleanFromObj(ip, objv[i + 1], &legacy) != TCL_OK) {
		return TCL_ERROR;
	    }
	    if (legacy) {
		cfg.struct_size = offsetof(TkxAppConfig, withdraw_main_window);
	    }
	} else if (strcmp(k, "-name") == 0) {
	    cfg.app_name = Tcl_GetString(objv[i + 1]);
	} else {
	    Tcl_SetObjResult(ip, Tcl_ObjPrintf("bad option %s", k));
	    return TCL_ERROR;
	}
    }
    st = tkx_app_init(&cfg);
    return st == TKX_OK ? TCL_OK : tkxb_status(ip, st);
}

/* Simple wrappers: each maps one C function. */
#define SIMPLE_ST(name, call) \
static int name(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[]) \
{ TkxStatus st; (void)cd; (void)objc; (void)objv; st = (call); \
  return st == TKX_OK ? TCL_OK : tkxb_status(ip, st); }

SIMPLE_ST(AppShutdownCmd, tkx_app_shutdown())
SIMPLE_ST(UpdateIdleCmd, tkx_app_update_idletasks())

static int
ProcessEventsCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    int n = tkx_app_process_events();
    (void)cd; (void)objc; (void)objv;
    if (n < 0) return tkxb_status(ip, tkx_last_error());
    Tcl_SetObjResult(ip, Tcl_NewWideIntObj(n));
    return TCL_OK;
}

static int
WaitEventCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    int ms = 0, r;
    (void)cd;
    if (objc > 1 && Tcl_GetIntFromObj(ip, objv[1], &ms) != TCL_OK) return TCL_ERROR;
    r = tkx_app_wait_event(ms);
    if (r < 0) return tkxb_status(ip, tkx_last_error());
    Tcl_SetObjResult(ip, Tcl_NewWideIntObj(r));
    return TCL_OK;
}

static int
IsRunningCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    (void)cd; (void)objc; (void)objv;
    Tcl_SetObjResult(ip, Tcl_NewBooleanObj(tkx_app_is_running()));
    return TCL_OK;
}

static int
QuitCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    (void)cd; (void)ip; (void)objc; (void)objv;
    tkx_app_quit();
    return TCL_OK;
}

static int
MainWindowCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    TkxId id = tkx_app_main_window();
    (void)cd; (void)objc; (void)objv;
    if (id == TKX_NULL_ID) return tkxb_status(ip, tkx_last_error());
    ID_RESULT(ip, id);
    return TCL_OK;
}

static int
HandleInfoCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    TkxId id;
    const char *what = (const char *)cd;
    if (objc != 2 || tkxb_get_id(ip, objv[1], &id) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("expected a handle", -1));
	return TCL_ERROR;
    }
    if (strcmp(what, "valid") == 0) {
	Tcl_SetObjResult(ip, Tcl_NewBooleanObj(tkx_handle_is_valid(id)));
    } else if (strcmp(what, "kind") == 0) {
	Tcl_SetObjResult(ip, Tcl_NewWideIntObj(tkx_handle_kind(id)));
    } else if (strcmp(what, "index") == 0) {
	Tcl_SetObjResult(ip, Tcl_NewWideIntObj(tkx_handle_index(id)));
    } else if (strcmp(what, "generation") == 0) {
	Tcl_SetObjResult(ip, Tcl_NewWideIntObj(tkx_handle_generation(id)));
    } else if (strcmp(what, "path") == 0) {
	const char *p = tkx__test_path(id);
	Tcl_SetObjResult(ip, Tcl_NewStringObj(p ? p : "", -1));
    }
    return TCL_OK;
}

static int
WidgetCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    const char *what = (const char *)cd;
    TkxId id;
    TkxStatus st;
    if (objc < 2 || tkxb_get_id(ip, objv[1], &id) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("expected a handle", -1));
	return TCL_ERROR;
    }
    if (strcmp(what, "destroy") == 0) {
	st = tkx_widget_destroy(id);
	return st == TKX_OK ? TCL_OK : tkxb_status(ip, st);
    } else if (strcmp(what, "parent") == 0) {
	TkxId p;
	if ((st = tkx_widget_parent(id, &p)) != TKX_OK) return tkxb_status(ip, st);
	ID_RESULT(ip, p);
    } else if (strcmp(what, "reqsize") == 0) {
	int w, h;
	if ((st = tkx_widget_requested_size(id, &w, &h)) != TKX_OK) return tkxb_status(ip, st);
	tkxb_set_pair(ip, w, h);
    } else if (strcmp(what, "geometry") == 0) {
	TkxBox b;
	if ((st = tkx_widget_geometry(id, &b)) != TKX_OK) return tkxb_status(ip, st);
	tkxb_set_box(ip, &b);
    } else if (strcmp(what, "mapped") == 0) {
	int m;
	if ((st = tkx_widget_is_mapped(id, &m)) != TKX_OK) return tkxb_status(ip, st);
	Tcl_SetObjResult(ip, Tcl_NewBooleanObj(m));
    } else if (strcmp(what, "manager") == 0) {
	char *s;
	if ((st = tkx_widget_manager(id, &s)) != TKX_OK) return tkxb_status(ip, st);
	Tcl_SetObjResult(ip, Tcl_NewStringObj(s, -1));
	tkx_free(s);
    } else if (strcmp(what, "focus") == 0) {
	if ((st = tkx_widget_focus(id)) != TKX_OK) return tkxb_status(ip, st);
    } else if (strcmp(what, "withdraw") == 0) {
	if ((st = tkx_window_withdraw(id)) != TKX_OK) return tkxb_status(ip, st);
    } else if (strcmp(what, "show") == 0) {
	if ((st = tkx_window_show(id)) != TKX_OK) return tkxb_status(ip, st);
    } else if (strcmp(what, "title") == 0) {
	if (objc > 2) {
	    if ((st = tkx_window_set_title(id, Tcl_GetString(objv[2]))) != TKX_OK) return tkxb_status(ip, st);
	} else {
	    char *s;
	    if ((st = tkx_window_get_title(id, &s)) != TKX_OK) return tkxb_status(ip, st);
	    Tcl_SetObjResult(ip, Tcl_NewStringObj(s, -1));
	    tkx_free(s);
	}
    } else if (strcmp(what, "wgeometry") == 0 || strcmp(what, "minsize") == 0) {
	int w, h;
	if (objc != 4 || Tcl_GetIntFromObj(ip, objv[2], &w) != TCL_OK
		|| Tcl_GetIntFromObj(ip, objv[3], &h) != TCL_OK) return TCL_ERROR;
	st = what[0] == 'w' ? tkx_window_set_geometry(id, w, h) : tkx_window_set_minsize(id, w, h);
	if (st != TKX_OK) return tkxb_status(ip, st);
    } else if (strcmp(what, "callback_remove") == 0) {
	if ((st = tkx_callback_remove(id)) != TKX_OK) return tkxb_status(ip, st);
    }
    return TCL_OK;
}

static int
WindowCreateCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    TkxId id;
    (void)cd;
    id = tkx_window_create(objc > 1 ? Tcl_GetString(objv[1]) : NULL);
    if (id == TKX_NULL_ID) return tkxb_status(ip, tkx_last_error());
    ID_RESULT(ip, id);
    return TCL_OK;
}

static int
PropCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    const char *what = (const char *)cd;
    TkxId id;
    TkxStatus st;
    const char *opt;
    if (objc < 3 || tkxb_get_id(ip, objv[1], &id) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("usage: handle option ?value?", -1));
	return TCL_ERROR;
    }
    opt = Tcl_GetString(objv[2]);
    if (strcmp(what, "set_string") == 0 && objc == 4) {
	st = tkx_widget_set_string(id, opt, Tcl_GetString(objv[3]));
    } else if (strcmp(what, "get_string") == 0) {
	char *s = NULL;
	st = tkx_widget_get_string(id, opt, &s);
	if (st == TKX_OK) { Tcl_SetObjResult(ip, Tcl_NewStringObj(s, -1)); tkx_free(s); }
    } else if (strcmp(what, "set_int") == 0 && objc == 4) {
	int v;
	if (Tcl_GetIntFromObj(ip, objv[3], &v) != TCL_OK) return TCL_ERROR;
	st = tkx_widget_set_int(id, opt, v);
    } else if (strcmp(what, "get_int") == 0) {
	int v = 0;
	st = tkx_widget_get_int(id, opt, &v);
	if (st == TKX_OK) Tcl_SetObjResult(ip, Tcl_NewWideIntObj(v));
    } else if (strcmp(what, "set_double") == 0 && objc == 4) {
	double v;
	if (Tcl_GetDoubleFromObj(ip, objv[3], &v) != TCL_OK) return TCL_ERROR;
	st = tkx_widget_set_double(id, opt, v);
    } else if (strcmp(what, "get_double") == 0) {
	double v = 0;
	st = tkx_widget_get_double(id, opt, &v);
	if (st == TKX_OK) Tcl_SetObjResult(ip, Tcl_NewDoubleObj(v));
    } else {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("wrong # args", -1));
	return TCL_ERROR;
    }
    return st == TKX_OK ? TCL_OK : tkxb_status(ip, st);
}

static int
CallCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    TkxId id;
    const char *argv[64];
    char *res = NULL;
    Tcl_Size i;
    TkxStatus st;
    (void)cd;
    if (objc < 3 || objc > 60 || tkxb_get_id(ip, objv[1], &id) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("usage: handle subcommand ?arg ...?", -1));
	return TCL_ERROR;
    }
    for (i = 3; i < objc; i++) {
	argv[i - 3] = Tcl_GetString(objv[i]);
    }
    st = tkx_widget_call(id, Tcl_GetString(objv[2]), (int)(objc - 3), argv, &res);
    if (st != TKX_OK) return tkxb_status(ip, st);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(res, -1));
    tkx_free(res);
    return TCL_OK;
}

static int
BindCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    TkxId id, cb;
    ScriptCb *s;
    (void)cd;
    if (objc != 4 || tkxb_get_id(ip, objv[1], &id) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("usage: handle sequence script", -1));
	return TCL_ERROR;
    }
    s = NewScriptCb(ip, objv[3]);
    cb = tkx_bind(id, Tcl_GetString(objv[2]), EventCb, s, ScriptFree);
    if (cb == TKX_NULL_ID) {
	TkxStatus st = tkx_last_error();
	Tcl_DecrRefCount(s->script);
	ckfree(s);
	return tkxb_status(ip, st);
    }
    ID_RESULT(ip, cb);
    return TCL_OK;
}

static int
AfterCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    int ms;
    TkxId cb;
    ScriptCb *s;
    (void)cd;
    if (objc != 3 || Tcl_GetIntFromObj(ip, objv[1], &ms) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("usage: ms script", -1));
	return TCL_ERROR;
    }
    s = NewScriptCb(ip, objv[2]);
    cb = tkx_after(ms, TaskCb, s, ScriptFree);
    if (cb == TKX_NULL_ID) {
	TkxStatus st = tkx_last_error();
	Tcl_DecrRefCount(s->script);
	ckfree(s);
	return tkxb_status(ip, st);
    }
    ID_RESULT(ip, cb);
    return TCL_OK;
}

static int
LastErrorCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    Tcl_Obj *v[2];
    (void)cd; (void)objc; (void)objv;
    v[0] = Tcl_NewStringObj(tkx_status_name(tkx_last_error()), -1);
    v[1] = Tcl_NewStringObj(tkx_last_error_message(), -1);
    Tcl_SetObjResult(ip, Tcl_NewListObj(2, v));
    return TCL_OK;
}

static int
FreedCountCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    (void)cd; (void)objc; (void)objv;
    Tcl_SetObjResult(ip, Tcl_NewWideIntObj(freedCount));
    return TCL_OK;
}

static int
OptionInfoCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    int kind, n, i;
    Tcl_Obj *l;
    (void)cd;
    if (objc != 2 || Tcl_GetIntFromObj(ip, objv[1], &kind) != TCL_OK) return TCL_ERROR;
    n = tkx_class_option_count(kind);
    if (n < 0) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("unknown kind", -1));
	return TCL_ERROR;
    }
    l = Tcl_NewListObj(0, NULL);
    for (i = 0; i < n; i++) {
	const TkxOptionInfo *o = tkx_class_option(kind, i);
	Tcl_Obj *d = Tcl_NewDictObj();
	Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("name", -1), Tcl_NewStringObj(o->name, -1));
	Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("type", -1), Tcl_NewWideIntObj(o->type));
	Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("flags", -1), Tcl_NewWideIntObj(o->flags));
	Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("alias", -1), Tcl_NewStringObj(o->alias_of ? o->alias_of : "", -1));
	Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("enum", -1), Tcl_NewWideIntObj(o->enum_count));
	Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("source", -1), Tcl_NewStringObj(o->source, -1));
	Tcl_ListObjAppendElement(NULL, l, d);
    }
    Tcl_SetObjResult(ip, l);
    return TCL_OK;
}

static int
KindNameCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    int kind;
    const char *n;
    (void)cd;
    if (objc != 2 || Tcl_GetIntFromObj(ip, objv[1], &kind) != TCL_OK) return TCL_ERROR;
    n = tkx_kind_name(kind);
    Tcl_SetObjResult(ip, Tcl_NewStringObj(n ? n : "", -1));
    return TCL_OK;
}

/* Evaluate a script in the tkx application's own interpreter.  Test
 * verification only: lets tests compare the wrapper's effects with
 * Tk's own view (grid info, winfo ...). */
static int
AppEvalCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    Tcl_Interp *app = (Tcl_Interp *)tkx__test_interp();
    int code;
    (void)cd;
    if (objc != 2 || app == NULL) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("usage: script (with an application)", -1));
	return TCL_ERROR;
    }
    code = Tcl_EvalObjEx(app, objv[1], TCL_EVAL_GLOBAL);
    Tcl_SetObjResult(ip, Tcl_GetObjResult(app));
    Tcl_ResetResult(app);
    return code == TCL_OK ? TCL_OK : TCL_ERROR;
}

/* Thread-contract test: from a second thread, call a widget function
 * (must fail with TKX_ERR_WRONG_THREAD) and post a task (must succeed). */
typedef struct ThreadArgs {
    TkxId widget;
    TkxStatus setStatus;
    TkxStatus postStatus;
    ScriptCb *task;
} ThreadArgs;

/* Tcl's portable thread API (pthreads on Unix, Win32 threads on Windows). */
static Tcl_ThreadCreateType
ThreadMain(void *p)
{
    ThreadArgs *a = (ThreadArgs *)p;
    a->setStatus = tkx_ttk_label_set_text(a->widget, "from thread");
    a->postStatus = tkx_app_post(TaskCb, a->task);
    TCL_THREAD_CREATE_RETURN;
}

static int
ThreadTestCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    ThreadArgs a;
    Tcl_ThreadId t;
    int result;
    Tcl_Obj *v[2];
    (void)cd;
    if (objc != 3 || tkxb_get_id(ip, objv[1], &a.widget) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("usage: label-handle script", -1));
	return TCL_ERROR;
    }
    a.task = NewScriptCb(ip, objv[2]);   /* leaked on purpose if never run */
    if (Tcl_CreateThread(&t, ThreadMain, &a, TCL_THREAD_STACK_DEFAULT,
	    TCL_THREAD_JOINABLE) != TCL_OK) {
	Tcl_SetObjResult(ip, Tcl_NewStringObj("cannot create thread", -1));
	return TCL_ERROR;
    }
    Tcl_JoinThread(t, &result);
    v[0] = Tcl_NewStringObj(tkx_status_name(a.setStatus), -1);
    v[1] = Tcl_NewStringObj(tkx_status_name(a.postStatus), -1);
    Tcl_SetObjResult(ip, Tcl_NewListObj(2, v));
    return TCL_OK;
}

static int
EnumValuesCmd(void *cd, Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv[])
{
    int i, j;
    (void)cd;
    if (objc != 2) {
	Tcl_WrongNumArgs(ip, 1, objv, "enumName");
	return TCL_ERROR;
    }
    for (i = 0; tkxb_enums[i].name != NULL; i++) {
	if (strcmp(tkxb_enums[i].name, Tcl_GetString(objv[1])) == 0) {
	    Tcl_Obj *l = Tcl_NewListObj(0, NULL);
	    for (j = 0; j < tkxb_enums[i].count; j++) {
		Tcl_ListObjAppendElement(NULL, l, Tcl_NewStringObj(tkxb_enums[i].values[j], -1));
	    }
	    Tcl_SetObjResult(ip, l);
	    return TCL_OK;
	}
    }
    Tcl_SetObjResult(ip, Tcl_NewStringObj("unknown enum", -1));
    return TCL_ERROR;
}

DLLEXPORT int
Tkxtest_Init(Tcl_Interp *ip)
{
    static const struct { const char *name; Tcl_ObjCmdProc2 *proc; const char *cd; } cmds[] = {
	{"fn", FnCmd, NULL}, {"fnlist", FnListCmd, NULL}, {"fninfo", FnInfoCmd, NULL}, {"fn_calls", FnCallsCmd, NULL},
	{"app_init", AppInitCmd, NULL}, {"app_shutdown", AppShutdownCmd, NULL},
	{"process_events", ProcessEventsCmd, NULL}, {"update_idletasks", UpdateIdleCmd, NULL},
	{"wait_event", WaitEventCmd, NULL}, {"is_running", IsRunningCmd, NULL},
	{"quit", QuitCmd, NULL}, {"main_window", MainWindowCmd, NULL},
	{"valid", HandleInfoCmd, "valid"}, {"kind", HandleInfoCmd, "kind"},
	{"index", HandleInfoCmd, "index"}, {"generation", HandleInfoCmd, "generation"},
	{"path", HandleInfoCmd, "path"},
	{"destroy", WidgetCmd, "destroy"}, {"parent", WidgetCmd, "parent"},
	{"reqsize", WidgetCmd, "reqsize"}, {"geometry", WidgetCmd, "geometry"},
	{"mapped", WidgetCmd, "mapped"}, {"manager", WidgetCmd, "manager"},
	{"focus", WidgetCmd, "focus"}, {"withdraw", WidgetCmd, "withdraw"},
	{"show", WidgetCmd, "show"}, {"title", WidgetCmd, "title"},
	{"window_geometry", WidgetCmd, "wgeometry"}, {"window_minsize", WidgetCmd, "minsize"},
	{"callback_remove", WidgetCmd, "callback_remove"},
	{"window_create", WindowCreateCmd, NULL},
	{"set_string", PropCmd, "set_string"}, {"get_string", PropCmd, "get_string"},
	{"set_int", PropCmd, "set_int"}, {"get_int", PropCmd, "get_int"},
	{"set_double", PropCmd, "set_double"}, {"get_double", PropCmd, "get_double"},
	{"call", CallCmd, NULL}, {"bind", BindCmd, NULL}, {"after", AfterCmd, NULL},
	{"last_error", LastErrorCmd, NULL}, {"freed_count", FreedCountCmd, NULL},
	{"option_info", OptionInfoCmd, NULL}, {"kind_name", KindNameCmd, NULL},
	{"app_eval", AppEvalCmd, NULL}, {"enum_values", EnumValuesCmd, NULL}, {"thread_test", ThreadTestCmd, NULL},
    };
    size_t i;
    if (Tcl_InitStubs(ip, "9.0", 0) == NULL) {
	return TCL_ERROR;
    }
    Tcl_CreateNamespace(ip, "::tkx", NULL, NULL);
    for (i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++) {
	char name[64];
	snprintf(name, sizeof(name), "::tkx::%s", cmds[i].name);
	Tcl_CreateObjCommand2(ip, name, cmds[i].proc, (void *)cmds[i].cd, NULL);
    }
    Tcl_SetVar2Ex(ip, "::tkx::omit", NULL, Tcl_NewStringObj(OMIT, -1), TCL_GLOBAL_ONLY);
    Tcl_SetVar2Ex(ip, "::tkx::tk_source_version", NULL,
	    Tcl_NewStringObj(TKX_TK_SOURCE_VERSION, -1), TCL_GLOBAL_ONLY);
    return Tcl_PkgProvide(ip, "tkxtest", "1.0");
}
