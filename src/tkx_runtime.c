/*
 * tkx_runtime.c -- application lifecycle, event loop, error model, widget
 * registry, command invocation and value conversion (handwritten).
 *
 * Why handwritten (Approach 3): interpreter creation, Tk initialisation,
 * the UI-thread contract, the event loop and the mapping between handles
 * and Tk windows are runtime mechanisms that have no declarative
 * description in Tk's sources.  Everything that is per-widget lives in
 * the generated code, which calls the helpers below.
 *
 * All Tk commands are invoked with Tcl_EvalObjv and one Tcl_Obj per word;
 * no Tcl script is ever built by string concatenation.
 */
#include "tkx_internal.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Error state (per thread)                                            */
/* ------------------------------------------------------------------ */

static _Thread_local TkxStatus lastStatus = TKX_OK;
static _Thread_local char *lastMessage = NULL;
static _Thread_local size_t lastCap = 0;

static void
SetMessage(const char *msg)
{
    size_t n = strlen(msg) + 1;
    if (n > lastCap) {
	char *p = (char *)realloc(lastMessage, n);
	if (p == NULL) {
	    return;
	}
	lastMessage = p;
	lastCap = n;
    }
    memcpy(lastMessage, msg, n);
}

static void
ResetError(void)
{
    lastStatus = TKX_OK;
    if (lastMessage != NULL) {
	lastMessage[0] = '\0';
    }
}

TkxStatus
tkx__error(TkxStatus st, const char *fmt, ...)
{
    char buf[1024];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    lastStatus = st;
    SetMessage(buf);
    return st;
}

TkxStatus
tkx__arg_error(const char *what)
{
    return tkx__error(TKX_ERR_INVALID_ARGUMENT, "invalid argument: %s", what);
}

TkxStatus
tkx_last_error(void)
{
    return lastStatus;
}

const char *
tkx_last_error_message(void)
{
    return lastMessage ? lastMessage : "";
}

const char *
tkx_status_name(TkxStatus st)
{
    switch (st) {
    case TKX_OK: return "TKX_OK";
    case TKX_ERR_NOT_INITIALIZED: return "TKX_ERR_NOT_INITIALIZED";
    case TKX_ERR_ALREADY_INITIALIZED: return "TKX_ERR_ALREADY_INITIALIZED";
    case TKX_ERR_WRONG_THREAD: return "TKX_ERR_WRONG_THREAD";
    case TKX_ERR_INVALID_HANDLE: return "TKX_ERR_INVALID_HANDLE";
    case TKX_ERR_STALE_HANDLE: return "TKX_ERR_STALE_HANDLE";
    case TKX_ERR_WRONG_KIND: return "TKX_ERR_WRONG_KIND";
    case TKX_ERR_INVALID_ARGUMENT: return "TKX_ERR_INVALID_ARGUMENT";
    case TKX_ERR_TK: return "TKX_ERR_TK";
    case TKX_ERR_EMPTY: return "TKX_ERR_EMPTY";
    case TKX_ERR_CONVERSION: return "TKX_ERR_CONVERSION";
    case TKX_ERR_NO_MEMORY: return "TKX_ERR_NO_MEMORY";
    case TKX_ERR_UNSUPPORTED: return "TKX_ERR_UNSUPPORTED";
    }
    return "TKX_ERR_UNKNOWN";
}

/* ------------------------------------------------------------------ */
/* Application state                                                   */
/* ------------------------------------------------------------------ */

Tcl_Interp *tkx__interp = NULL;
static Tcl_ThreadId uiThread;
static int appAlive = 0;          /* protected by appMutex for tkx_app_post */
TCL_DECLARE_MUTEX(appMutex)
static int quitRequested = 0;
static int mainWindowGone = 0;
static TkxId mainWindowId = TKX_NULL_ID;
static Tcl_HashTable pathTable;   /* path -> TkxWidget* */
static unsigned long nameCounter = 0;
static int findExecutableDone = 0;

TkxStatus
tkx__enter(void)
{
    ResetError();
    if (tkx__interp == NULL) {
	return tkx__error(TKX_ERR_NOT_INITIALIZED, "no tkx application (call tkx_app_init)");
    }
    if (Tcl_GetCurrentThread() != uiThread) {
	return tkx__error(TKX_ERR_WRONG_THREAD,
		"tkx functions must be called on the thread that called tkx_app_init");
    }
    return TKX_OK;
}

static const char *
KindName(int kind)
{
    const TkxClassInfo *ci = tkx__class_info(kind);
    if (ci != NULL) {
	return ci->command;
    }
    if (kind == TKX_KIND_CALLBACK) {
	return "callback";
    }
    return "?";
}

TkxStatus
tkx__widget(TkxId id, uint64_t kindMask, TkxWidget **out)
{
    TkxStatus st = tkx__enter();
    TkxWidget *w;
    int kind;

    if (st != TKX_OK) {
	return st;
    }
    w = (TkxWidget *)tkx__handle_lookup(id, 0, &st);
    if (w == NULL) {
	if (st == TKX_ERR_STALE_HANDLE) {
	    return tkx__error(st, "handle 0x%016llx refers to a destroyed object",
		    (unsigned long long)id);
	}
	return tkx__error(st, "0x%016llx is not a valid handle", (unsigned long long)id);
    }
    kind = tkx_handle_kind(id);
    if (kind == TKX_KIND_CALLBACK || tkx__class_info(kind) == NULL) {
	return tkx__error(TKX_ERR_WRONG_KIND, "handle is a %s, not a widget", KindName(kind));
    }
    if (kindMask != 0 && !(kindMask & TKX__KINDBIT(kind))) {
	return tkx__error(TKX_ERR_WRONG_KIND, "handle is a %s widget, not accepted here",
		KindName(kind));
    }
    *out = w;
    return TKX_OK;
}

const TkxClassInfo *
tkx__class_info(int kind)
{
    int i;
    for (i = 0; i < tkx__class_count; i++) {
	if (tkx__classes[i].kind == kind) {
	    return &tkx__classes[i];
	}
    }
    return NULL;
}

TkxStatus
tkx__tk_error(void)
{
    return tkx__error(TKX_ERR_TK, "%s", Tcl_GetStringResult(tkx__interp));
}

/* ------------------------------------------------------------------ */
/* Widget registry                                                     */
/* ------------------------------------------------------------------ */

static void
ForgetWidget(TkxWidget *w)
{
    Tcl_HashEntry *he;

    if (w->destroyed) {
	return;
    }
    w->destroyed = 1;
    tkx__callbacks_widget_destroyed(w);
    he = Tcl_FindHashEntry(&pathTable, Tcl_GetString(w->path));
    if (he != NULL && Tcl_GetHashValue(he) == w) {
	Tcl_DeleteHashEntry(he);
    }
    if (w->id == mainWindowId) {
	mainWindowGone = 1;
    }
    tkx__handle_release(w->id);
    Tcl_DecrRefCount(w->path);
    ckfree(w);
}

/*
 * Destruction through Tk itself (a parent destroyed, "destroy" called by
 * a binding, the window manager closing a toplevel) is observed with a
 * StructureNotify event handler: the handle is invalidated when Tk sends
 * DestroyNotify, so no handle ever refers to a dead window.
 */
static void
WidgetEventProc(void *clientData, XEvent *eventPtr)
{
    if (eventPtr->type == DestroyNotify) {
	ForgetWidget((TkxWidget *)clientData);
    }
}

static TkxWidget *
Register(int kind, const char *path)
{
    Tk_Window tkwin = Tk_NameToWindow(tkx__interp, path, Tk_MainWindow(tkx__interp));
    TkxWidget *w;
    Tcl_HashEntry *he;
    int isNew;

    if (tkwin == NULL) {
	tkx__tk_error();
	return NULL;
    }
    w = (TkxWidget *)ckalloc(sizeof(TkxWidget));
    memset(w, 0, sizeof(*w));
    w->kind = kind;
    w->tkwin = tkwin;
    w->path = Tcl_NewStringObj(path, -1);
    Tcl_IncrRefCount(w->path);
    w->id = tkx__handle_alloc(kind, w);
    if (w->id == TKX_NULL_ID) {
	Tcl_DecrRefCount(w->path);
	ckfree(w);
	return NULL;
    }
    he = Tcl_CreateHashEntry(&pathTable, path, &isNew);
    Tcl_SetHashValue(he, w);
    Tk_CreateEventHandler(tkwin, StructureNotifyMask, WidgetEventProc, w);
    return w;
}

TkxWidget *
tkx__widget_by_path(const char *path)
{
    Tcl_HashEntry *he = Tcl_FindHashEntry(&pathTable, path);
    return he ? (TkxWidget *)Tcl_GetHashValue(he) : NULL;
}

TkxId
tkx__create(int kind, const char *tkcmd, TkxId parent, int extrac,
	Tcl_Obj *const extrav[])
{
    TkxWidget *pw = NULL, *w;
    Tcl_Obj *objv[34];
    char path[512];
    const char *ppath;
    TkxStatus st;
    int i;

    if (parent == TKX_NULL_ID) {
	if ((st = tkx__enter()) != TKX_OK) {
	    return TKX_NULL_ID;
	}
	ppath = ".";
    } else {
	if (tkx__widget(parent, 0, &pw) != TKX_OK) {
	    return TKX_NULL_ID;
	}
	ppath = Tcl_GetString(pw->path);
    }
    if (extrac > 32) {
	tkx__arg_error("too many creation options");
	return TKX_NULL_ID;
    }
    snprintf(path, sizeof(path), "%s.w%lu", strcmp(ppath, ".") == 0 ? "" : ppath,
	    ++nameCounter);
    objv[0] = Tcl_NewStringObj(tkcmd, -1);
    objv[1] = Tcl_NewStringObj(path, -1);
    for (i = 0; i < extrac; i++) {
	objv[2 + i] = extrav[i];
    }
    if (tkx__invoke(2 + extrac, objv, NULL) != TKX_OK) {
	return TKX_NULL_ID;
    }
    w = Register(kind, path);
    if (w == NULL) {
	return TKX_NULL_ID;
    }
    return w->id;
}

/* ------------------------------------------------------------------ */
/* Command invocation                                                  */
/* ------------------------------------------------------------------ */

TkxStatus
tkx__invoke(int objc, Tcl_Obj *const objv[], Tcl_Obj **result)
{
    int i, code;

    for (i = 0; i < objc; i++) {
	Tcl_IncrRefCount(objv[i]);
    }
    code = Tcl_EvalObjv(tkx__interp, objc, objv, TCL_EVAL_GLOBAL);
    if (code != TCL_OK) {
	tkx__tk_error();
    } else if (result != NULL) {
	*result = Tcl_GetObjResult(tkx__interp);
	Tcl_IncrRefCount(*result);
    }
    Tcl_ResetResult(tkx__interp);
    for (i = 0; i < objc; i++) {
	Tcl_DecrRefCount(objv[i]);
    }
    return code == TCL_OK ? TKX_OK : TKX_ERR_TK;
}

TkxStatus
tkx__widget_call(TkxWidget *w, int objc, Tcl_Obj *const objv[], Tcl_Obj **result)
{
    Tcl_Obj *v[64];
    int i;

    if (objc + 1 > 64) {
	return tkx__arg_error("too many words");
    }
    v[0] = w->path;
    for (i = 0; i < objc; i++) {
	v[i + 1] = objv[i];
    }
    return tkx__invoke(objc + 1, v, result);
}

TkxStatus
tkx__configure1(TkxWidget *w, const char *opt, Tcl_Obj *value)
{
    Tcl_Obj *v[3];

    if (value == NULL) {
	return tkx_last_error();
    }
    v[0] = Tcl_NewStringObj("configure", -1);
    v[1] = Tcl_NewStringObj(opt, -1);
    v[2] = value;
    return tkx__widget_call(w, 3, v, NULL);
}

TkxStatus
tkx__cget(TkxWidget *w, const char *opt, Tcl_Obj **out)
{
    Tcl_Obj *v[2];

    v[0] = Tcl_NewStringObj("cget", -1);
    v[1] = Tcl_NewStringObj(opt, -1);
    return tkx__widget_call(w, 2, v, out);
}

/* ------------------------------------------------------------------ */
/* Value construction                                                  */
/* ------------------------------------------------------------------ */

Tcl_Obj *
tkx__str(const char *s)
{
    return s ? Tcl_NewStringObj(s, -1) : Tcl_NewObj();
}

Tcl_Obj *
tkx__int(int v)
{
    return Tcl_NewWideIntObj((Tcl_WideInt)v);
}

Tcl_Obj *
tkx__bool(int v)
{
    return Tcl_NewBooleanObj(v != 0);
}

Tcl_Obj *
tkx__double(double v)
{
    return Tcl_NewDoubleObj(v);
}

Tcl_Obj *
tkx__index(int v)
{
    if (v == TKX_INDEX_END) {
	return Tcl_NewStringObj("end", -1);
    }
    if (v < 0) {
	tkx__error(TKX_ERR_INVALID_ARGUMENT,
		"invalid index %d (use a position >= 0 or TKX_INDEX_END)", v);
	return NULL;
    }
    return Tcl_NewWideIntObj(v);
}

Tcl_Obj *
tkx__strlist(const char *const *items, size_t n)
{
    Tcl_Obj *l = Tcl_NewListObj(0, NULL);
    size_t i;

    for (i = 0; i < n; i++) {
	if (items[i] == NULL) {
	    Tcl_IncrRefCount(l);
	    Tcl_DecrRefCount(l);
	    tkx__arg_error("NULL string in list");
	    return NULL;
	}
	Tcl_ListObjAppendElement(NULL, l, Tcl_NewStringObj(items[i], -1));
    }
    return l;
}

Tcl_Obj *
tkx__enum(const char *const *table, int count, int value, int nullOk)
{
    if (value == -1 && nullOk) {
	return Tcl_NewObj();
    }
    if (value < 0 || value >= count) {
	tkx__error(TKX_ERR_INVALID_ARGUMENT, "enumeration value %d out of range%s",
		value, value == -1 ? " (this option cannot be unset)" : "");
	return NULL;
    }
    return Tcl_NewStringObj(table[value], -1);
}

Tcl_Obj *
tkx__window(TkxId id)
{
    TkxWidget *w;
    TkxStatus st;

    if (id == TKX_NULL_ID) {
	return Tcl_NewObj();
    }
    w = (TkxWidget *)tkx__handle_lookup(id, 0, &st);
    if (w == NULL || tkx__class_info(tkx_handle_kind(id)) == NULL) {
	tkx__error(st == TKX_OK ? TKX_ERR_WRONG_KIND : st,
		"window argument is not a live widget handle");
	return NULL;
    }
    return Tcl_DuplicateObj(w->path);
}

Tcl_Obj *
tkx__sticky(unsigned flags)
{
    char buf[5];
    int n = 0;

    if (flags & ~TKX_STICKY_NSEW) {
	tkx__arg_error("sticky flags");
	return NULL;
    }
    if (flags & TKX_STICKY_N) buf[n++] = 'n';
    if (flags & TKX_STICKY_S) buf[n++] = 's';
    if (flags & TKX_STICKY_E) buf[n++] = 'e';
    if (flags & TKX_STICKY_W) buf[n++] = 'w';
    return Tcl_NewStringObj(buf, n);
}

Tcl_Obj *
tkx__padding(int before, int after)
{
    Tcl_Obj *v[2];

    if (before < 0 || after < 0) {
	tkx__arg_error("padding must be >= 0");
	return NULL;
    }
    v[0] = Tcl_NewWideIntObj(before);
    v[1] = Tcl_NewWideIntObj(after);
    return Tcl_NewListObj(2, v);
}

void
tkx__discard(int objc, Tcl_Obj *const objv[])
{
    int i;
    for (i = 0; i < objc; i++) {
	Tcl_IncrRefCount(objv[i]);
	Tcl_DecrRefCount(objv[i]);
    }
}

/* ------------------------------------------------------------------ */
/* Value conversion                                                    */
/* ------------------------------------------------------------------ */

static int
IsEmpty(Tcl_Obj *o)
{
    Tcl_Size len;
    Tcl_GetStringFromObj(o, &len);
    return len == 0;
}

static char *
DupString(const char *s, Tcl_Size len)
{
    char *p = (char *)malloc((size_t)len + 1);
    if (p != NULL) {
	memcpy(p, s, (size_t)len);
	p[len] = '\0';
    }
    return p;
}

TkxStatus
tkx__to_string(Tcl_Obj *o, char **out)
{
    Tcl_Size len;
    const char *s = Tcl_GetStringFromObj(o, &len);

    *out = DupString(s, len);
    return *out ? TKX_OK : tkx__error(TKX_ERR_NO_MEMORY, "out of memory");
}

TkxStatus
tkx__to_int(Tcl_Obj *o, int *out)
{
    if (IsEmpty(o)) {
	return tkx__error(TKX_ERR_EMPTY, "value is empty");
    }
    if (Tcl_GetIntFromObj(NULL, o, out) != TCL_OK) {
	return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not an integer", Tcl_GetString(o));
    }
    return TKX_OK;
}

TkxStatus
tkx__to_bool(Tcl_Obj *o, int *out)
{
    int b;
    if (IsEmpty(o)) {
	return tkx__error(TKX_ERR_EMPTY, "value is empty");
    }
    if (Tcl_GetBooleanFromObj(NULL, o, &b) != TCL_OK) {
	return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not a boolean", Tcl_GetString(o));
    }
    *out = b ? 1 : 0;
    return TKX_OK;
}

TkxStatus
tkx__to_double(Tcl_Obj *o, double *out)
{
    if (IsEmpty(o)) {
	return tkx__error(TKX_ERR_EMPTY, "value is empty");
    }
    if (Tcl_GetDoubleFromObj(NULL, o, out) != TCL_OK) {
	return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not a number", Tcl_GetString(o));
    }
    return TKX_OK;
}

TkxStatus
tkx__to_pixels(TkxWidget *w, Tcl_Obj *o, int *out)
{
    if (IsEmpty(o)) {
	return tkx__error(TKX_ERR_EMPTY, "value is empty");
    }
    if (Tk_GetPixelsFromObj(NULL, w->tkwin, o, out) != TCL_OK) {
	return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not a screen distance",
		Tcl_GetString(o));
    }
    return TKX_OK;
}

TkxStatus
tkx__to_enum(Tcl_Obj *o, const char *const *table, int count, int *out)
{
    Tcl_Size len;
    const char *s = Tcl_GetStringFromObj(o, &len);
    int i, match = -1;

    if (len == 0) {
	*out = -1;   /* unset */
	return TKX_OK;
    }
    for (i = 0; i < count; i++) {
	if (strcmp(s, table[i]) == 0) {
	    *out = i;
	    return TKX_OK;
	}
    }
    /* Tk accepts unique abbreviations; values set elsewhere may be one. */
    for (i = 0; i < count; i++) {
	if (strncmp(s, table[i], (size_t)len) == 0) {
	    if (match >= 0) {
		match = -2;
		break;
	    }
	    match = i;
	}
    }
    if (match < 0) {
	return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not a known value", s);
    }
    *out = match;
    return TKX_OK;
}

TkxStatus
tkx__to_window(Tcl_Obj *o, TkxId *out)
{
    TkxWidget *w;

    if (IsEmpty(o)) {
	*out = TKX_NULL_ID;
	return TKX_OK;
    }
    w = tkx__widget_by_path(Tcl_GetString(o));
    if (w == NULL) {
	return tkx__error(TKX_ERR_CONVERSION,
		"window \"%s\" was not created through tkx", Tcl_GetString(o));
    }
    *out = w->id;
    return TKX_OK;
}

TkxStatus
tkx__to_strlist(Tcl_Obj *o, TkxStringList *out)
{
    Tcl_Size n, i;
    Tcl_Obj **elems;

    out->count = 0;
    out->items = NULL;
    if (Tcl_ListObjGetElements(NULL, o, &n, &elems) != TCL_OK) {
	return tkx__error(TKX_ERR_CONVERSION, "value is not a list");
    }
    if (n == 0) {
	return TKX_OK;
    }
    out->items = (char **)calloc((size_t)n, sizeof(char *));
    if (out->items == NULL) {
	return tkx__error(TKX_ERR_NO_MEMORY, "out of memory");
    }
    for (i = 0; i < n; i++) {
	Tcl_Size len;
	const char *s = Tcl_GetStringFromObj(elems[i], &len);
	out->items[i] = DupString(s, len);
	if (out->items[i] == NULL) {
	    out->count = (size_t)i;
	    tkx_string_list_free(out);
	    return tkx__error(TKX_ERR_NO_MEMORY, "out of memory");
	}
    }
    out->count = (size_t)n;
    return TKX_OK;
}

TkxStatus
tkx__to_box(Tcl_Obj *o, TkxBox *out)
{
    Tcl_Size n;
    Tcl_Obj **e;
    int v[4], i;

    if (IsEmpty(o)) {
	return tkx__error(TKX_ERR_EMPTY, "no bounding box (not visible)");
    }
    if (Tcl_ListObjGetElements(NULL, o, &n, &e) != TCL_OK || n != 4) {
	return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not a box", Tcl_GetString(o));
    }
    for (i = 0; i < 4; i++) {
	if (Tcl_GetIntFromObj(NULL, e[i], &v[i]) != TCL_OK) {
	    return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not a box", Tcl_GetString(o));
	}
    }
    out->x = v[0];
    out->y = v[1];
    out->width = v[2];
    out->height = v[3];
    return TKX_OK;
}

TkxStatus
tkx__to_sticky(Tcl_Obj *o, unsigned *out)
{
    const char *s = Tcl_GetString(o);
    unsigned f = 0;

    for (; *s; s++) {
	switch (*s) {
	case 'n': case 'N': f |= TKX_STICKY_N; break;
	case 's': case 'S': f |= TKX_STICKY_S; break;
	case 'e': case 'E': f |= TKX_STICKY_E; break;
	case 'w': case 'W': f |= TKX_STICKY_W; break;
	case ' ': case ',': break;
	default:
	    return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not a sticky value",
		    Tcl_GetString(o));
	}
    }
    *out = f;
    return TKX_OK;
}

TkxStatus
tkx__to_padding(TkxWidget *w, Tcl_Obj *o, int *before, int *after)
{
    Tcl_Size n;
    Tcl_Obj **e;

    if (Tcl_ListObjGetElements(NULL, o, &n, &e) != TCL_OK || n < 1 || n > 2) {
	return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not a padding value",
		Tcl_GetString(o));
    }
    if (Tk_GetPixelsFromObj(NULL, w->tkwin, e[0], before) != TCL_OK
	    || Tk_GetPixelsFromObj(NULL, w->tkwin, e[n - 1], after) != TCL_OK) {
	return tkx__error(TKX_ERR_CONVERSION, "\"%s\" is not a padding value",
		Tcl_GetString(o));
    }
    return TKX_OK;
}

TkxStatus
tkx__dict_get(Tcl_Obj *dict, const char *key, Tcl_Obj **out)
{
    Tcl_Obj *k = Tcl_NewStringObj(key, -1), *v = NULL;
    int code;

    Tcl_IncrRefCount(k);
    code = Tcl_DictObjGet(NULL, dict, k, &v);
    Tcl_DecrRefCount(k);
    if (code != TCL_OK || v == NULL) {
	return tkx__error(TKX_ERR_EMPTY, "no value for %s (window not managed?)", key);
    }
    Tcl_IncrRefCount(v);
    *out = v;
    return TKX_OK;
}

/* ------------------------------------------------------------------ */
/* Memory                                                              */
/* ------------------------------------------------------------------ */

void
tkx_free(void *p)
{
    free(p);
}

void
tkx_string_list_free(TkxStringList *l)
{
    size_t i;
    if (l == NULL) {
	return;
    }
    for (i = 0; i < l->count; i++) {
	free(l->items[i]);
    }
    free(l->items);
    l->items = NULL;
    l->count = 0;
}

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

TkxStatus
tkx_app_init(const TkxAppConfig *config)
{
    Tcl_Interp *interp;
    Tcl_Obj *argv, *v[2];
    TkxWidget *mw;
    const char *name = "tkx";

    ResetError();
    if (tkx__interp != NULL) {
	return tkx__error(TKX_ERR_ALREADY_INITIALIZED, "a tkx application already exists");
    }
    if (config != NULL && config->struct_size != 0
	    && config->struct_size < sizeof(size_t)) {
	return tkx__arg_error("config->struct_size");
    }
    if (!findExecutableDone) {
	if (config == NULL || !config->host_initialized_tcl) {
	    /* Not hosted by tclsh or another Tcl program: locate the Tcl
	     * library, which Tcl 9 may keep in a zip archive attached to
	     * libtcl (TclZipfs_AppHook also calls Tcl_FindExecutable). */
	    static int hookArgc = 1;
	    static char *hookArgv0[] = {(char *)"tkx", NULL};
	    static char **hookArgv = hookArgv0;
	    TclZipfs_AppHook(&hookArgc, &hookArgv);
	}
	findExecutableDone = 1;
    }
    interp = Tcl_CreateInterp();
    if (Tcl_Init(interp) != TCL_OK) {
	tkx__error(TKX_ERR_TK, "Tcl_Init failed: %s", Tcl_GetStringResult(interp));
	Tcl_DeleteInterp(interp);
	return TKX_ERR_TK;
    }
    /* Tk reads its command-line options from ::argv; build it as a list. */
    argv = Tcl_NewListObj(0, NULL);
    if (config != NULL && config->app_name != NULL) {
	name = config->app_name;
    }
    Tcl_ListObjAppendElement(NULL, argv, Tcl_NewStringObj("-name", -1));
    Tcl_ListObjAppendElement(NULL, argv, Tcl_NewStringObj(name, -1));
    if (config != NULL && config->display != NULL) {
	Tcl_ListObjAppendElement(NULL, argv, Tcl_NewStringObj("-display", -1));
	Tcl_ListObjAppendElement(NULL, argv, Tcl_NewStringObj(config->display, -1));
    }
    Tcl_SetVar2Ex(interp, "argv", NULL, argv, TCL_GLOBAL_ONLY);
    {
	Tcl_Size argcount = 0;
	Tcl_ListObjLength(NULL, argv, &argcount);
	Tcl_SetVar2Ex(interp, "argc", NULL, Tcl_NewWideIntObj(argcount), TCL_GLOBAL_ONLY);
    }
    Tcl_SetVar2Ex(interp, "argv0", NULL, Tcl_NewStringObj(name, -1), TCL_GLOBAL_ONLY);
    if (Tk_Init(interp) != TCL_OK) {
	tkx__error(TKX_ERR_TK, "Tk_Init failed: %s", Tcl_GetStringResult(interp));
	Tcl_DeleteInterp(interp);
	return TKX_ERR_TK;
    }
    tkx__interp = interp;
    uiThread = Tcl_GetCurrentThread();
    tkx__next_app_serial();
    Tcl_InitHashTable(&pathTable, TCL_STRING_KEYS);
    quitRequested = 0;
    mainWindowGone = 0;
    nameCounter = 0;
    if (tkx__callbacks_init(interp) != TCL_OK) {
	tkx__error(TKX_ERR_TK, "callback initialisation failed");
	goto fail;
    }
    if (config != NULL && config->class_name != NULL) {
	/* "tk appname" changes the name; the class of "." is fixed at
	 * creation and follows the application name. */
    }
    mw = Register(TKX_KIND_TOPLEVEL, ".");
    if (mw == NULL) {
	goto fail;
    }
    mainWindowId = mw->id;
    if (config != NULL && config->withdraw_main_window) {
	v[0] = Tcl_NewStringObj("wm", -1);
	v[1] = Tcl_NewStringObj("withdraw", -1);
	{
	    Tcl_Obj *w3[3] = {v[0], v[1], mw->path};
	    tkx__invoke(3, w3, NULL);
	}
    }
    Tcl_MutexLock(&appMutex);
    appAlive = 1;
    Tcl_MutexUnlock(&appMutex);
    ResetError();
    return TKX_OK;
fail:
    Tcl_DeleteInterp(interp);
    tkx__interp = NULL;
    Tcl_DeleteHashTable(&pathTable);
    return TKX_ERR_TK;
}

TkxStatus
tkx_app_shutdown(void)
{
    TkxStatus st = tkx__enter();
    Tcl_HashSearch hs;
    Tcl_HashEntry *he;
    Tk_Window mainWin;

    if (st != TKX_OK) {
	return st;
    }
    Tcl_MutexLock(&appMutex);
    appAlive = 0;
    Tcl_MutexUnlock(&appMutex);
    mainWin = Tk_MainWindow(tkx__interp);
    if (mainWin != NULL) {
	Tk_DestroyWindow(mainWin);   /* DestroyNotify invalidates every widget */
    }
    /* Anything left (should be nothing): release it too. */
    for (he = Tcl_FirstHashEntry(&pathTable, &hs); he != NULL;
	    he = Tcl_FirstHashEntry(&pathTable, &hs)) {
	ForgetWidget((TkxWidget *)Tcl_GetHashValue(he));
    }
    tkx__callbacks_shutdown();
    tkx__handles_reset_all();
    Tcl_DeleteHashTable(&pathTable);
    Tcl_DeleteInterp(tkx__interp);
    tkx__interp = NULL;
    mainWindowId = TKX_NULL_ID;
    /* Let Tcl run pending deletion callbacks. */
    while (Tcl_DoOneEvent(TCL_DONT_WAIT | TCL_ALL_EVENTS)) {}
    ResetError();
    return TKX_OK;
}

int
tkx_app_is_running(void)
{
    if (tkx__enter() != TKX_OK) {
	return 0;
    }
    return !quitRequested && !mainWindowGone;
}

TkxId
tkx_app_main_window(void)
{
    if (tkx__enter() != TKX_OK) {
	return TKX_NULL_ID;
    }
    if (mainWindowGone) {
	tkx__error(TKX_ERR_STALE_HANDLE, "the main window has been destroyed");
	return TKX_NULL_ID;
    }
    return mainWindowId;
}

int
tkx_app_process_events(void)
{
    int n = 0;

    if (tkx__enter() != TKX_OK) {
	return -1;
    }
    while (tkx__interp != NULL && Tcl_DoOneEvent(TCL_DONT_WAIT | TCL_ALL_EVENTS)) {
	n++;
    }
    return n;
}

static void
TimeoutProc(void *clientData)
{
    *(int *)clientData = 1;
}

int
tkx_app_wait_event(int timeoutMs)
{
    int timedOut = 0, r;
    Tcl_TimerToken t = NULL;

    if (tkx__enter() != TKX_OK) {
	return -1;
    }
    if (timeoutMs >= 0) {
	t = Tcl_CreateTimerHandler(timeoutMs, TimeoutProc, &timedOut);
    }
    r = Tcl_DoOneEvent(TCL_ALL_EVENTS);
    if (t != NULL && !timedOut) {
	Tcl_DeleteTimerHandler(t);
    }
    return timedOut ? 0 : (r ? 1 : 0);
}

TkxStatus
tkx_app_update_idletasks(void)
{
    TkxStatus st = tkx__enter();
    if (st != TKX_OK) {
	return st;
    }
    while (Tcl_DoOneEvent(TCL_IDLE_EVENTS | TCL_DONT_WAIT)) {}
    return TKX_OK;
}

TkxStatus
tkx_app_run(void)
{
    TkxStatus st = tkx__enter();
    if (st != TKX_OK) {
	return st;
    }
    quitRequested = 0;
    while (tkx__interp != NULL && !quitRequested && !mainWindowGone) {
	Tcl_DoOneEvent(TCL_ALL_EVENTS);
    }
    return TKX_OK;
}

void
tkx_app_quit(void)
{
    if (tkx__enter() == TKX_OK) {
	quitRequested = 1;
    }
}

/* Thread-safe posting of tasks to the UI thread. */
typedef struct PostEvent {
    Tcl_Event header;
    TkxTaskFn fn;
    void *userData;
} PostEvent;

static int
PostEventProc(Tcl_Event *evPtr, int flags)
{
    PostEvent *pe = (PostEvent *)evPtr;
    (void)flags;
    if (tkx__interp != NULL && pe->fn != NULL) {
	pe->fn(pe->userData);
    }
    return 1;
}

TkxStatus
tkx_app_post(TkxTaskFn fn, void *userData)
{
    PostEvent *pe;

    if (fn == NULL) {
	return TKX_ERR_INVALID_ARGUMENT;
    }
    Tcl_MutexLock(&appMutex);
    if (!appAlive) {
	Tcl_MutexUnlock(&appMutex);
	return TKX_ERR_NOT_INITIALIZED;
    }
    pe = (PostEvent *)ckalloc(sizeof(PostEvent));
    pe->header.proc = PostEventProc;
    pe->fn = fn;
    pe->userData = userData;
    Tcl_ThreadQueueEvent(uiThread, (Tcl_Event *)pe, TCL_QUEUE_TAIL | TCL_QUEUE_ALERT_IF_EMPTY);
    Tcl_ThreadAlert(uiThread);
    Tcl_MutexUnlock(&appMutex);
    return TKX_OK;
}

/* ------------------------------------------------------------------ */
/* Generic widget operations                                           */
/* ------------------------------------------------------------------ */

static TkxStatus
Words(int objc, const char *const *words, TkxWidget *w, int pathPos, Tcl_Obj **result)
{
    Tcl_Obj *v[8];
    int i;

    for (i = 0; i < objc; i++) {
	v[i] = (i == pathPos) ? w->path : Tcl_NewStringObj(words[i], -1);
    }
    return tkx__invoke(objc, v, result);
}

TkxStatus
tkx_widget_destroy(TkxId widget)
{
    TkxWidget *w;
    TkxStatus st = tkx__widget(widget, 0, &w);
    static const char *const words[] = {"::destroy", NULL};

    if (st != TKX_OK) {
	return st;
    }
    return Words(2, words, w, 1, NULL);
}

TkxStatus
tkx_widget_parent(TkxId widget, TkxId *out)
{
    TkxWidget *w, *p;
    Tk_Window pw;
    TkxStatus st = tkx__widget(widget, 0, &w);

    if (st != TKX_OK) {
	return st;
    }
    if (out == NULL) {
	return tkx__arg_error("out");
    }
    pw = Tk_Parent(w->tkwin);
    if (pw == NULL) {
	*out = TKX_NULL_ID;
	return TKX_OK;
    }
    p = tkx__widget_by_path(Tk_PathName(pw));
    *out = p ? p->id : TKX_NULL_ID;
    return TKX_OK;
}

TkxStatus
tkx_widget_requested_size(TkxId widget, int *width, int *height)
{
    TkxWidget *w;
    TkxStatus st = tkx__widget(widget, 0, &w);

    if (st != TKX_OK) {
	return st;
    }
    if (width == NULL || height == NULL) {
	return tkx__arg_error("width/height");
    }
    *width = Tk_ReqWidth(w->tkwin);
    *height = Tk_ReqHeight(w->tkwin);
    return TKX_OK;
}

TkxStatus
tkx_widget_geometry(TkxId widget, TkxBox *out)
{
    TkxWidget *w;
    TkxStatus st = tkx__widget(widget, 0, &w);

    if (st != TKX_OK) {
	return st;
    }
    if (out == NULL) {
	return tkx__arg_error("out");
    }
    out->x = Tk_X(w->tkwin);
    out->y = Tk_Y(w->tkwin);
    out->width = Tk_Width(w->tkwin);
    out->height = Tk_Height(w->tkwin);
    return TKX_OK;
}

TkxStatus
tkx_widget_is_mapped(TkxId widget, int *out)
{
    TkxWidget *w;
    TkxStatus st = tkx__widget(widget, 0, &w);

    if (st != TKX_OK) {
	return st;
    }
    if (out == NULL) {
	return tkx__arg_error("out");
    }
    *out = Tk_IsMapped(w->tkwin) ? 1 : 0;
    return TKX_OK;
}

TkxStatus
tkx_widget_manager(TkxId widget, char **out)
{
    TkxWidget *w;
    Tcl_Obj *r;
    static const char *const words[] = {"::winfo", "manager", NULL};
    TkxStatus st = tkx__widget(widget, 0, &w);

    if (st != TKX_OK) {
	return st;
    }
    if (out == NULL) {
	return tkx__arg_error("out");
    }
    if ((st = Words(3, words, w, 2, &r)) != TKX_OK) {
	return st;
    }
    st = tkx__to_string(r, out);
    Tcl_DecrRefCount(r);
    return st;
}

TkxStatus
tkx_widget_focus(TkxId widget)
{
    TkxWidget *w;
    static const char *const words[] = {"::focus", NULL};
    TkxStatus st = tkx__widget(widget, 0, &w);

    if (st != TKX_OK) {
	return st;
    }
    return Words(2, words, w, 1, NULL);
}

/* Top-level windows: "wm" is irregular (one big switch over strings in
 * tkUnixWm.c/tkWinWm.c/tkMacOSXWm.c, different per platform), so the
 * few operations needed are handwritten here. */

static TkxStatus
Wm(TkxId toplevel, const char *op, int extrac, Tcl_Obj *extra[], Tcl_Obj **result)
{
    TkxWidget *w;
    Tcl_Obj *v[6];
    int i;
    TkxStatus st = tkx__widget(toplevel, TKX__KINDBIT(TKX_KIND_TOPLEVEL), &w);

    if (st != TKX_OK) {
	tkx__discard(extrac, extra);
	return st;
    }
    v[0] = Tcl_NewStringObj("::wm", -1);
    v[1] = Tcl_NewStringObj(op, -1);
    v[2] = w->path;
    for (i = 0; i < extrac; i++) {
	v[3 + i] = extra[i];
    }
    return tkx__invoke(3 + extrac, v, result);
}

TkxId
tkx_window_create(const char *title)
{
    TkxId id = tkx_toplevel_create(TKX_NULL_ID);
    if (id != TKX_NULL_ID && title != NULL) {
	if (tkx_window_set_title(id, title) != TKX_OK) {
	    TkxStatus st = tkx_last_error();
	    char msg[512];
	    snprintf(msg, sizeof(msg), "%s", tkx_last_error_message());
	    tkx_widget_destroy(id);
	    tkx__error(st, "%s", msg);
	    return TKX_NULL_ID;
	}
    }
    return id;
}

TkxStatus
tkx_window_set_title(TkxId toplevel, const char *title)
{
    Tcl_Obj *e[1];
    if (title == NULL) {
	return tkx__arg_error("title");
    }
    e[0] = Tcl_NewStringObj(title, -1);
    return Wm(toplevel, "title", 1, e, NULL);
}

TkxStatus
tkx_window_get_title(TkxId toplevel, char **out)
{
    Tcl_Obj *r;
    TkxStatus st;
    if (out == NULL) {
	return tkx__arg_error("out");
    }
    if ((st = Wm(toplevel, "title", 0, NULL, &r)) != TKX_OK) {
	return st;
    }
    st = tkx__to_string(r, out);
    Tcl_DecrRefCount(r);
    return st;
}

TkxStatus
tkx_window_set_geometry(TkxId toplevel, int width, int height)
{
    Tcl_Obj *e[1];
    char buf[64];
    if (width <= 0 || height <= 0) {
	return tkx__arg_error("width/height");
    }
    snprintf(buf, sizeof(buf), "%dx%d", width, height);
    e[0] = Tcl_NewStringObj(buf, -1);
    return Wm(toplevel, "geometry", 1, e, NULL);
}

TkxStatus
tkx_window_set_minsize(TkxId toplevel, int width, int height)
{
    Tcl_Obj *e[2];
    e[0] = Tcl_NewWideIntObj(width);
    e[1] = Tcl_NewWideIntObj(height);
    return Wm(toplevel, "minsize", 2, e, NULL);
}

TkxStatus
tkx_window_withdraw(TkxId toplevel)
{
    return Wm(toplevel, "withdraw", 0, NULL, NULL);
}

TkxStatus
tkx_window_show(TkxId toplevel)
{
    return Wm(toplevel, "deiconify", 0, NULL, NULL);
}

/* ------------------------------------------------------------------ */
/* Generic properties                                                  */
/* ------------------------------------------------------------------ */

static TkxStatus
FindOption(TkxId widget, const char *option, int forSet, TkxWidget **wout,
	const TkxOptionInfo **oout)
{
    TkxWidget *w;
    const TkxClassInfo *ci;
    TkxStatus st = tkx__widget(widget, 0, &w);
    int i;

    if (st != TKX_OK) {
	return st;
    }
    if (option == NULL) {
	return tkx__arg_error("option");
    }
    ci = tkx__class_info(w->kind);
    for (i = 0; i < ci->optionCount; i++) {
	if (strcmp(ci->options[i].name, option) == 0) {
	    const TkxOptionInfo *oi = &ci->options[i];
	    if (oi->flags & TKX_OPT_ALIAS) {
		int j;
		for (j = 0; j < ci->optionCount; j++) {
		    if (strcmp(ci->options[j].name, oi->alias_of) == 0) {
			oi = &ci->options[j];
			break;
		    }
		}
	    }
	    if ((oi->flags & TKX_OPT_SCRIPT) || oi->type == TKX_TYPE_CALLBACK) {
		return tkx__error(TKX_ERR_UNSUPPORTED,
			"option %s holds Tcl code or a Tcl variable name; not accessible "
			"through the generic interface", option);
	    }
	    (void)forSet;
	    *wout = w;
	    *oout = oi;
	    return TKX_OK;
	}
    }
    return tkx__error(TKX_ERR_UNSUPPORTED, "%s widgets have no option %s",
	    ci->command, option);
}

TkxStatus
tkx_widget_set_string(TkxId widget, const char *option, const char *value)
{
    TkxWidget *w;
    const TkxOptionInfo *oi;
    TkxStatus st = FindOption(widget, option, 1, &w, &oi);
    if (st != TKX_OK) {
	return st;
    }
    if (value == NULL) {
	return tkx__arg_error("value");
    }
    return tkx__configure1(w, oi->name, Tcl_NewStringObj(value, -1));
}

TkxStatus
tkx_widget_get_string(TkxId widget, const char *option, char **out)
{
    TkxWidget *w;
    const TkxOptionInfo *oi;
    Tcl_Obj *v;
    TkxStatus st = FindOption(widget, option, 0, &w, &oi);
    if (st != TKX_OK) {
	return st;
    }
    if (out == NULL) {
	return tkx__arg_error("out");
    }
    if ((st = tkx__cget(w, oi->name, &v)) != TKX_OK) {
	return st;
    }
    st = tkx__to_string(v, out);
    Tcl_DecrRefCount(v);
    return st;
}

TkxStatus
tkx_widget_set_int(TkxId widget, const char *option, int value)
{
    TkxWidget *w;
    const TkxOptionInfo *oi;
    TkxStatus st = FindOption(widget, option, 1, &w, &oi);
    if (st != TKX_OK) {
	return st;
    }
    return tkx__configure1(w, oi->name, oi->type == TKX_TYPE_BOOL
	    ? Tcl_NewBooleanObj(value != 0) : Tcl_NewWideIntObj(value));
}

TkxStatus
tkx_widget_get_int(TkxId widget, const char *option, int *out)
{
    TkxWidget *w;
    const TkxOptionInfo *oi;
    Tcl_Obj *v;
    TkxStatus st = FindOption(widget, option, 0, &w, &oi);
    if (st != TKX_OK) {
	return st;
    }
    if (out == NULL) {
	return tkx__arg_error("out");
    }
    if ((st = tkx__cget(w, oi->name, &v)) != TKX_OK) {
	return st;
    }
    if (oi->type == TKX_TYPE_PIXELS) {
	st = tkx__to_pixels(w, v, out);
    } else if (oi->type == TKX_TYPE_BOOL) {
	st = tkx__to_bool(v, out);
    } else {
	st = tkx__to_int(v, out);
    }
    Tcl_DecrRefCount(v);
    return st;
}

TkxStatus
tkx_widget_set_double(TkxId widget, const char *option, double value)
{
    TkxWidget *w;
    const TkxOptionInfo *oi;
    TkxStatus st = FindOption(widget, option, 1, &w, &oi);
    if (st != TKX_OK) {
	return st;
    }
    return tkx__configure1(w, oi->name, Tcl_NewDoubleObj(value));
}

TkxStatus
tkx_widget_get_double(TkxId widget, const char *option, double *out)
{
    TkxWidget *w;
    const TkxOptionInfo *oi;
    Tcl_Obj *v;
    TkxStatus st = FindOption(widget, option, 0, &w, &oi);
    if (st != TKX_OK) {
	return st;
    }
    if (out == NULL) {
	return tkx__arg_error("out");
    }
    if ((st = tkx__cget(w, oi->name, &v)) != TKX_OK) {
	return st;
    }
    st = tkx__to_double(v, out);
    Tcl_DecrRefCount(v);
    return st;
}

const char *
tkx_kind_name(int kind)
{
    const TkxClassInfo *ci = tkx__class_info(kind);
    return ci ? ci->command : (kind == TKX_KIND_CALLBACK ? "callback" : NULL);
}

int
tkx_class_option_count(int kind)
{
    const TkxClassInfo *ci = tkx__class_info(kind);
    return ci ? ci->optionCount : -1;
}

const TkxOptionInfo *
tkx_class_option(int kind, int index)
{
    const TkxClassInfo *ci = tkx__class_info(kind);
    if (ci == NULL || index < 0 || index >= ci->optionCount) {
	return NULL;
    }
    return &ci->options[index];
}

/* ------------------------------------------------------------------ */
/* Generic subcommand invocation                                       */
/* ------------------------------------------------------------------ */

TkxStatus
tkx_widget_call(TkxId widget, const char *subcommand, int argc,
	const char *const *argv, char **result)
{
    TkxWidget *w;
    const TkxClassInfo *ci;
    Tcl_Obj *v[64], *r = NULL;
    int i, found = -1;
    TkxStatus st = tkx__widget(widget, 0, &w);

    if (st != TKX_OK) {
	return st;
    }
    if (subcommand == NULL || argc < 0 || argc > 60 || (argc > 0 && argv == NULL)) {
	return tkx__arg_error("subcommand/argc/argv");
    }
    ci = tkx__class_info(w->kind);
    for (i = 0; i < ci->subcommandCount; i++) {
	if (strcmp(ci->subcommands[i].name, subcommand) == 0) {
	    found = i;
	    break;
	}
    }
    if (found < 0) {
	return tkx__error(TKX_ERR_UNSUPPORTED, "%s widgets have no subcommand \"%s\"",
		ci->command, subcommand);
    }
    if (ci->subcommands[found].refused) {
	return tkx__error(TKX_ERR_UNSUPPORTED,
		"subcommand \"%s\" is not available through tkx_widget_call "
		"(use the typed functions; it takes options or Tcl scripts)", subcommand);
    }
    v[0] = Tcl_NewStringObj(subcommand, -1);
    for (i = 0; i < argc; i++) {
	if (argv[i] == NULL) {
	    tkx__discard(i + 1, v);
	    return tkx__arg_error("argv element is NULL");
	}
	v[i + 1] = Tcl_NewStringObj(argv[i], -1);
    }
    st = tkx__widget_call(w, argc + 1, v, result ? &r : NULL);
    if (st == TKX_OK && result != NULL) {
	st = tkx__to_string(r, result);
	Tcl_DecrRefCount(r);
    }
    return st;
}

/* ------------------------------------------------------------------ */
/* Test hooks (exported for the tcltest bridge; not in the public      */
/* header and not part of the API contract).                           */
/* ------------------------------------------------------------------ */

TKX_API void *tkx__test_interp(void);
TKX_API const char *tkx__test_path(TkxId id);

TKX_API void *
tkx__test_interp(void)
{
    return tkx__interp;
}

TKX_API const char *
tkx__test_path(TkxId id)
{
    TkxStatus st;
    TkxWidget *w;

    if (tkx__interp == NULL) {
	return NULL;
    }
    w = (TkxWidget *)tkx__handle_lookup(id, 0, &st);
    if (w == NULL || tkx__class_info(tkx_handle_kind(id)) == NULL) {
	return NULL;
    }
    return Tcl_GetString(w->path);
}
