/*
 * tkx_callbacks.c -- C callbacks for Tk options, event bindings and timers
 * (handwritten).
 *
 * Why handwritten: Tk delivers callbacks by evaluating Tcl scripts.  The
 * bridge from a script to a C function pointer with user data, and its
 * lifetime rules, are a runtime mechanism with no counterpart in Tk's
 * sources.
 *
 * Mechanism: one Tcl command, ::tkx::cb, is created in the application's
 * interpreter.  A callback is registered by storing the script
 *     ::tkx::cb <callback-handle> ?%-fields?
 * built with Tcl_NewListObj (never by string concatenation) in the
 * option or binding.  When Tk evaluates it, the handle is validated
 * (generation check) and the C function is called.  A script that
 * survives its callback (e.g. after removal) refers to a stale handle and
 * is ignored.
 */
#include "tkx_internal.h"
#include <stdlib.h>
#include <string.h>

enum { CB_OPTION = 1, CB_BIND, CB_AFTER };

struct TkxCallback {
    TkxId id;
    int type;
    TkxWidget *widget;          /* owner (NULL for timers) */
    char *key;                  /* option name or event sequence */
    TkxCommandFn commandFn;
    TkxEventFn eventFn;
    TkxTaskFn taskFn;
    void *userData;
    TkxFreeFn freeFn;
    Tcl_TimerToken timer;
    int inUse;                  /* nesting depth of running invocations */
    int released;               /* released while in use: free on return */
    TkxCallback *nextInWidget;
    TkxCallback *prevAll, *nextAll;
};

static TkxCallback *allCallbacks = NULL;

static void
FreeRecord(TkxCallback *cb)
{
    if (cb->freeFn != NULL) {
	TkxFreeFn f = cb->freeFn;
	cb->freeFn = NULL;
	f(cb->userData);
    }
    free(cb->key);
    free(cb);
}

/* Detach the callback from every structure and invalidate its handle.
 * The user data is released now, or after the running invocation. */
static void
Release(TkxCallback *cb)
{
    if (cb->widget != NULL) {
	TkxCallback **pp = &cb->widget->callbacks;
	while (*pp != NULL && *pp != cb) {
	    pp = &(*pp)->nextInWidget;
	}
	if (*pp == cb) {
	    *pp = cb->nextInWidget;
	}
	cb->widget = NULL;
    }
    if (cb->prevAll) cb->prevAll->nextAll = cb->nextAll; else allCallbacks = cb->nextAll;
    if (cb->nextAll) cb->nextAll->prevAll = cb->prevAll;
    cb->prevAll = cb->nextAll = NULL;
    if (cb->timer != NULL) {
	Tcl_DeleteTimerHandler(cb->timer);
	cb->timer = NULL;
    }
    tkx__handle_release(cb->id);
    if (cb->inUse > 0) {
	cb->released = 1;
    } else {
	FreeRecord(cb);
    }
}

static TkxCallback *
NewRecord(int type, TkxWidget *w, const char *key)
{
    TkxCallback *cb = (TkxCallback *)calloc(1, sizeof(TkxCallback));
    if (cb == NULL) {
	tkx__error(TKX_ERR_NO_MEMORY, "out of memory");
	return NULL;
    }
    cb->type = type;
    if (key != NULL) {
	cb->key = (char *)malloc(strlen(key) + 1);
	if (cb->key == NULL) {
	    free(cb);
	    tkx__error(TKX_ERR_NO_MEMORY, "out of memory");
	    return NULL;
	}
	strcpy(cb->key, key);
    }
    cb->id = tkx__handle_alloc(TKX_KIND_CALLBACK, cb);
    if (cb->id == TKX_NULL_ID) {
	free(cb->key);
	free(cb);
	return NULL;
    }
    cb->nextAll = allCallbacks;
    if (allCallbacks) allCallbacks->prevAll = cb;
    allCallbacks = cb;
    if (w != NULL) {
	cb->widget = w;
	cb->nextInWidget = w->callbacks;
	w->callbacks = cb;
    }
    return cb;
}

static TkxCallback *
FindExisting(TkxWidget *w, int type, const char *key)
{
    TkxCallback *cb;
    for (cb = w->callbacks; cb != NULL; cb = cb->nextInWidget) {
	if (cb->type == type && strcmp(cb->key, key) == 0) {
	    return cb;
	}
    }
    return NULL;
}

static Tcl_Obj *
Trampoline(TkxId id)
{
    Tcl_Obj *l = Tcl_NewListObj(0, NULL);
    Tcl_ListObjAppendElement(NULL, l, Tcl_NewStringObj("::tkx::cb", -1));
    Tcl_ListObjAppendElement(NULL, l, Tcl_NewWideIntObj((Tcl_WideInt)id));
    return l;
}

/* ------------------------------------------------------------------ */
/* Dispatch                                                            */
/* ------------------------------------------------------------------ */

static int
IntArg(Tcl_Obj *o)
{
    int v;
    return Tcl_GetIntFromObj(NULL, o, &v) == TCL_OK ? v : 0;
}

static int
CallbackCmd(void *clientData, Tcl_Interp *interp, Tcl_Size objc,
	Tcl_Obj *const objv[])
{
    Tcl_WideInt wid;
    TkxCallback *cb;
    TkxStatus st;
    TkxId owner;
    (void)clientData;

    if (objc < 2 || Tcl_GetWideIntFromObj(NULL, objv[1], &wid) != TCL_OK) {
	return TCL_OK;
    }
    cb = (TkxCallback *)tkx__handle_lookup((TkxId)wid, TKX_KIND_CALLBACK, &st);
    if (cb == NULL) {
	return TCL_OK;          /* stale script: the callback was released */
    }
    owner = cb->widget ? cb->widget->id : TKX_NULL_ID;
    cb->inUse++;
    if (cb->type == CB_OPTION && cb->commandFn != NULL) {
	cb->commandFn(owner, cb->userData);
    } else if (cb->type == CB_BIND && cb->eventFn != NULL) {
	TkxEvent ev;
	TkxWidget *w;
	memset(&ev, 0, sizeof(ev));
	ev.sequence = cb->key;
	ev.keysym = "";
	ev.text = "";
	if (objc >= 15) {
	    w = tkx__widget_by_path(Tcl_GetString(objv[2]));
	    ev.widget = w ? w->id : owner;
	    ev.x = IntArg(objv[3]);
	    ev.y = IntArg(objv[4]);
	    ev.root_x = IntArg(objv[5]);
	    ev.root_y = IntArg(objv[6]);
	    ev.button = IntArg(objv[7]);
	    ev.keycode = IntArg(objv[8]);
	    ev.keysym = strcmp(Tcl_GetString(objv[9]), "??") ? Tcl_GetString(objv[9]) : "";
	    ev.text = strcmp(Tcl_GetString(objv[10]), "??") ? Tcl_GetString(objv[10]) : "";
	    ev.width = IntArg(objv[11]);
	    ev.height = IntArg(objv[12]);
	    ev.state = (unsigned)IntArg(objv[13]);
	    ev.delta = IntArg(objv[14]);
	} else {
	    ev.widget = owner;
	}
	cb->eventFn(&ev, cb->userData);
    }
    cb->inUse--;
    if (cb->released && cb->inUse == 0) {
	FreeRecord(cb);
    }
    Tcl_ResetResult(interp);
    return TCL_OK;
}

int
tkx__callbacks_init(Tcl_Interp *interp)
{
    if (Tcl_CreateNamespace(interp, "::tkx", NULL, NULL) == NULL) {
	return TCL_ERROR;
    }
    return Tcl_CreateObjCommand2(interp, "::tkx::cb", CallbackCmd, NULL, NULL)
	    ? TCL_OK : TCL_ERROR;
}

/* ------------------------------------------------------------------ */
/* Option callbacks (used by generated *_set_command functions)        */
/* ------------------------------------------------------------------ */

TkxId
tkx__callback_option(TkxWidget *w, const char *option, TkxCommandFn fn,
	void *userData, TkxFreeFn freeFn)
{
    TkxCallback *old = FindExisting(w, CB_OPTION, option), *cb;
    TkxId wid = w->id;

    if (fn == NULL) {
	/* Clear the option; the previous callback is released. */
	if (tkx__configure1(w, option, Tcl_NewObj()) != TKX_OK) {
	    return TKX_NULL_ID;
	}
	if (old != NULL) {
	    Release(old);
	}
	return TKX_NULL_ID;
    }
    cb = NewRecord(CB_OPTION, w, option);
    if (cb == NULL) {
	return TKX_NULL_ID;
    }
    cb->commandFn = fn;
    cb->userData = userData;
    cb->freeFn = freeFn;
    if (tkx__configure1(w, option, Trampoline(cb->id)) != TKX_OK) {
	cb->freeFn = NULL;      /* registration failed: caller keeps ownership */
	Release(cb);
	return TKX_NULL_ID;
    }
    /* The widget may have been destroyed by the configure call itself. */
    if (tkx__handle_lookup(wid, 0, &(TkxStatus){TKX_OK}) != NULL && old != NULL) {
	Release(old);
    }
    return cb->id;
}

/* ------------------------------------------------------------------ */
/* Event bindings                                                      */
/* ------------------------------------------------------------------ */

TkxId
tkx_bind(TkxId widget, const char *sequence, TkxEventFn fn, void *userData,
	TkxFreeFn freeFn)
{
    TkxWidget *w;
    TkxCallback *old, *cb;
    Tcl_Obj *script, *v[4];
    static const char *const fields[] = {
	"%W", "%x", "%y", "%X", "%Y", "%b", "%k", "%K", "%A", "%w", "%h", "%s", "%D"
    };
    size_t i;

    if (tkx__widget(widget, 0, &w) != TKX_OK) {
	return TKX_NULL_ID;
    }
    if (sequence == NULL || sequence[0] == '\0' || fn == NULL) {
	tkx__arg_error("sequence/fn");
	return TKX_NULL_ID;
    }
    old = FindExisting(w, CB_BIND, sequence);
    cb = NewRecord(CB_BIND, w, sequence);
    if (cb == NULL) {
	return TKX_NULL_ID;
    }
    cb->eventFn = fn;
    cb->userData = userData;
    cb->freeFn = freeFn;
    script = Trampoline(cb->id);
    for (i = 0; i < sizeof(fields) / sizeof(fields[0]); i++) {
	Tcl_ListObjAppendElement(NULL, script, Tcl_NewStringObj(fields[i], -1));
    }
    v[0] = Tcl_NewStringObj("::bind", -1);
    v[1] = w->path;
    v[2] = Tcl_NewStringObj(sequence, -1);
    v[3] = script;
    if (tkx__invoke(4, v, NULL) != TKX_OK) {
	cb->freeFn = NULL;
	Release(cb);
	return TKX_NULL_ID;
    }
    if (old != NULL) {
	Release(old);
    }
    return cb->id;
}

/* ------------------------------------------------------------------ */
/* Timers                                                              */
/* ------------------------------------------------------------------ */

static void
TimerProc(void *clientData)
{
    TkxCallback *cb = (TkxCallback *)clientData;
    cb->timer = NULL;
    cb->inUse++;
    if (cb->taskFn != NULL) {
	cb->taskFn(cb->userData);
    }
    cb->inUse--;
    if (!cb->released) {
	Release(cb);            /* one-shot */
    } else if (cb->inUse == 0) {
	FreeRecord(cb);
    }
}

TkxId
tkx_after(int delayMs, TkxTaskFn fn, void *userData, TkxFreeFn freeFn)
{
    TkxCallback *cb;

    if (tkx__enter() != TKX_OK) {
	return TKX_NULL_ID;
    }
    if (fn == NULL || delayMs < 0) {
	tkx__arg_error("fn/delay_ms");
	return TKX_NULL_ID;
    }
    cb = NewRecord(CB_AFTER, NULL, NULL);
    if (cb == NULL) {
	return TKX_NULL_ID;
    }
    cb->taskFn = fn;
    cb->userData = userData;
    cb->freeFn = freeFn;
    cb->timer = Tcl_CreateTimerHandler(delayMs, TimerProc, cb);
    return cb->id;
}

/* ------------------------------------------------------------------ */
/* Removal and lifetime                                                */
/* ------------------------------------------------------------------ */

TkxStatus
tkx_callback_remove(TkxId id)
{
    TkxCallback *cb;
    TkxStatus st = tkx__enter();

    if (st != TKX_OK) {
	return st;
    }
    cb = (TkxCallback *)tkx__handle_lookup(id, TKX_KIND_CALLBACK, &st);
    if (cb == NULL) {
	return tkx__error(st, "not a live callback handle");
    }
    if (cb->widget != NULL && !cb->widget->destroyed) {
	TkxWidget *w = cb->widget;
	if (cb->type == CB_OPTION) {
	    tkx__configure1(w, cb->key, Tcl_NewObj());
	} else if (cb->type == CB_BIND) {
	    Tcl_Obj *v[4];
	    v[0] = Tcl_NewStringObj("::bind", -1);
	    v[1] = w->path;
	    v[2] = Tcl_NewStringObj(cb->key, -1);
	    v[3] = Tcl_NewObj();
	    tkx__invoke(4, v, NULL);
	}
	/* The Tk call may have released it already (widget destroyed). */
	if (tkx__handle_lookup(id, TKX_KIND_CALLBACK, &st) == NULL) {
	    return TKX_OK;
	}
    }
    Release(cb);
    return TKX_OK;
}

void
tkx__callbacks_widget_destroyed(TkxWidget *w)
{
    while (w->callbacks != NULL) {
	Release(w->callbacks);
    }
}

void
tkx__callbacks_shutdown(void)
{
    while (allCallbacks != NULL) {
	Release(allCallbacks);
    }
}
