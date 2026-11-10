/*
 * tkx.h -- public C API of tkx, a C wrapper around Tcl/Tk.
 *
 * This header is handwritten.  It defines the runtime contract (handles,
 * status codes, application lifecycle, event loop, callbacks, generic
 * properties) and includes the generated per-widget API from
 * tkx_generated.h.
 *
 * The header does not require Tcl or Tk headers and exposes no Tcl/Tk
 * types.  All strings are UTF-8.  Strings passed in are copied by the
 * library before the call returns.  Strings and lists returned through
 * out-parameters are owned by the caller and must be released with
 * tkx_free() / tkx_string_list_free().
 *
 * Threading: tkx follows Tk's rule that a Tk application lives on one
 * thread.  Every function must be called on the thread that called
 * tkx_app_init() (the UI thread), except tkx_app_post(), tkx_handle_*()
 * decoding helpers and tkx_status_name(), which are thread-safe.  Calls
 * from another thread fail with TKX_ERR_WRONG_THREAD without touching Tk.
 */
#ifndef TKX_H
#define TKX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(TKX_BUILD)
#    define TKX_API __declspec(dllexport)
#  else
#    define TKX_API __declspec(dllimport)
#  endif
#elif defined(__GNUC__)
#  define TKX_API __attribute__((visibility("default")))
#else
#  define TKX_API
#endif

#define TKX_ABI_VERSION 1

/* ------------------------------------------------------------------ */
/* Handles                                                             */
/* ------------------------------------------------------------------ */

/*
 * An opaque 64-bit handle.  Layout (informative; use the accessors):
 *   bits  0..23  slot index
 *   bits 24..47  generation of the slot (stale handles never revalidate)
 *   bits 48..55  application instance serial (never 0)
 *   bits 56..63  object kind (TkxKind, never 0)
 * TKX_NULL_ID (0) is never a valid handle.
 */
typedef uint64_t TkxId;
#define TKX_NULL_ID ((TkxId)0)

/* Object kinds.  Widget kinds are generated (see tkx_generated.h); the
 * values below are reserved for runtime objects. */
#define TKX_KIND_CALLBACK 200

/* ------------------------------------------------------------------ */
/* Status codes                                                        */
/* ------------------------------------------------------------------ */

typedef enum TkxStatus {
    TKX_OK = 0,
    TKX_ERR_NOT_INITIALIZED = 1,  /* tkx_app_init() not called / app gone */
    TKX_ERR_ALREADY_INITIALIZED = 2,
    TKX_ERR_WRONG_THREAD = 3,     /* called off the UI thread */
    TKX_ERR_INVALID_HANDLE = 4,   /* never a handle of this application */
    TKX_ERR_STALE_HANDLE = 5,     /* the object was destroyed */
    TKX_ERR_WRONG_KIND = 6,       /* handle of another object kind */
    TKX_ERR_INVALID_ARGUMENT = 7, /* rejected before reaching Tk */
    TKX_ERR_TK = 8,               /* Tk reported an error (see message) */
    TKX_ERR_EMPTY = 9,            /* the value is empty / not set */
    TKX_ERR_CONVERSION = 10,      /* value cannot be represented in the C type */
    TKX_ERR_NO_MEMORY = 11,
    TKX_ERR_UNSUPPORTED = 12      /* option/operation not available here */
} TkxStatus;

/* Status and message of the most recent failing call on this thread.
 * Every API call resets them on entry.  The message pointer stays valid
 * until the next tkx call on the same thread. */
TKX_API TkxStatus tkx_last_error(void);
TKX_API const char *tkx_last_error_message(void);
TKX_API const char *tkx_status_name(TkxStatus status);

/* ------------------------------------------------------------------ */
/* Memory                                                              */
/* ------------------------------------------------------------------ */

typedef struct TkxStringList {
    size_t count;
    char **items;      /* count UTF-8 strings */
} TkxStringList;

typedef struct TkxBox {
    int x, y, width, height;
} TkxBox;

TKX_API void tkx_free(void *ptr);
TKX_API void tkx_string_list_free(TkxStringList *list);

/* ------------------------------------------------------------------ */
/* Application lifecycle and event loop                                */
/* ------------------------------------------------------------------ */

typedef struct TkxAppConfig {
    size_t struct_size;        /* sizeof(TkxAppConfig), for ABI evolution */
    const char *app_name;      /* Tk application name (default "tkx") */
    const char *class_name;    /* class of the main window (default from name) */
    const char *display;       /* X11 display; NULL = $DISPLAY */
    int withdraw_main_window;  /* nonzero: start with the main window hidden */
    int host_initialized_tcl;  /* nonzero: the process already initialised the
                                  Tcl library (tkx loaded from a Tcl program);
                                  tkx then skips locating the Tcl library */
} TkxAppConfig;

/* Create the Tcl interpreter, initialise Tk and make the calling thread
 * the UI thread.  config may be NULL.  Only one application may exist at
 * a time; after tkx_app_shutdown() a new one may be created. */
TKX_API TkxStatus tkx_app_init(const TkxAppConfig *config);

/* Destroy every widget (handles become stale), free callbacks and delete
 * the interpreter. */
TKX_API TkxStatus tkx_app_shutdown(void);

/* Nonzero while the main window exists and tkx_app_quit() was not called. */
TKX_API int tkx_app_is_running(void);

/* Handle of the main window "." (kind TKX_KIND_TOPLEVEL). */
TKX_API TkxId tkx_app_main_window(void);

/* Process all pending events without waiting.  Returns the number of
 * events processed, or -1 on error. */
TKX_API int tkx_app_process_events(void);

/* Wait for and process one event (or until timeout_ms elapses; a
 * negative timeout waits indefinitely).  Returns 1 if an event was
 * processed, 0 on timeout, -1 on error. */
TKX_API int tkx_app_wait_event(int timeout_ms);

/* Process idle callbacks only (geometry propagation, redisplay), like
 * Tk's "update idletasks". */
TKX_API TkxStatus tkx_app_update_idletasks(void);

/* Run the event loop until tkx_app_quit() is called or the main window
 * is destroyed. */
TKX_API TkxStatus tkx_app_run(void);
TKX_API void tkx_app_quit(void);

/* Thread-safe: queue fn(user_data) to run on the UI thread during event
 * processing.  Returns TKX_ERR_NOT_INITIALIZED if no application exists. */
typedef void (*TkxTaskFn)(void *user_data);
TKX_API TkxStatus tkx_app_post(TkxTaskFn fn, void *user_data);

/* ------------------------------------------------------------------ */
/* Handle utilities                                                    */
/* ------------------------------------------------------------------ */

TKX_API int tkx_handle_is_valid(TkxId id);     /* live object of this app */
TKX_API int tkx_handle_kind(TkxId id);         /* decoded kind (thread-safe) */
TKX_API uint32_t tkx_handle_index(TkxId id);   /* decoded slot (thread-safe) */
TKX_API uint32_t tkx_handle_generation(TkxId id);

/* ------------------------------------------------------------------ */
/* Widgets (generic part)                                              */
/* ------------------------------------------------------------------ */

/* Destroy a widget and its descendants.  All their handles and the
 * callbacks attached to them become invalid.  Widgets destroyed by Tk
 * itself (e.g. a parent destroyed, or the user closing a window) are
 * invalidated the same way. */
TKX_API TkxStatus tkx_widget_destroy(TkxId widget);

TKX_API TkxStatus tkx_widget_parent(TkxId widget, TkxId *out);

/* Requested and actual geometry (Tk's winfo reqwidth/reqheight/width/
 * height/x/y).  Call tkx_app_update_idletasks() first for settled values. */
TKX_API TkxStatus tkx_widget_requested_size(TkxId widget, int *width, int *height);
TKX_API TkxStatus tkx_widget_geometry(TkxId widget, TkxBox *out);
TKX_API TkxStatus tkx_widget_is_mapped(TkxId widget, int *out);

/* Name of the geometry manager managing the widget ("grid", "pack", ...)
 * or an empty string. */
TKX_API TkxStatus tkx_widget_manager(TkxId widget, char **out);

/* Keyboard focus. */
TKX_API TkxStatus tkx_widget_focus(TkxId widget);

/* Top-level window operations (kind TKX_KIND_TOPLEVEL). */
TKX_API TkxId tkx_window_create(const char *title);
TKX_API TkxStatus tkx_window_set_title(TkxId toplevel, const char *title);
TKX_API TkxStatus tkx_window_get_title(TkxId toplevel, char **out);
TKX_API TkxStatus tkx_window_set_geometry(TkxId toplevel, int width, int height);
TKX_API TkxStatus tkx_window_set_minsize(TkxId toplevel, int width, int height);
TKX_API TkxStatus tkx_window_withdraw(TkxId toplevel);
TKX_API TkxStatus tkx_window_show(TkxId toplevel);

/* ------------------------------------------------------------------ */
/* Generic, typed property access (escape hatch)                       */
/* ------------------------------------------------------------------ */

/*
 * Options are named as in Tk ("-text").  Only options listed in the
 * widget class metadata (tkx_class_option) are accepted; options whose
 * value Tk evaluates as a script are refused with TKX_ERR_UNSUPPORTED so
 * that no Tcl code can be injected through this interface.
 */
TKX_API TkxStatus tkx_widget_set_string(TkxId w, const char *option, const char *value);
TKX_API TkxStatus tkx_widget_get_string(TkxId w, const char *option, char **out);
TKX_API TkxStatus tkx_widget_set_int(TkxId w, const char *option, int value);
TKX_API TkxStatus tkx_widget_get_int(TkxId w, const char *option, int *out);
TKX_API TkxStatus tkx_widget_set_double(TkxId w, const char *option, double value);
TKX_API TkxStatus tkx_widget_get_double(TkxId w, const char *option, double *out);

/* Value types reported by the class metadata. */
typedef enum TkxValueType {
    TKX_TYPE_STRING = 1, TKX_TYPE_INT, TKX_TYPE_BOOL, TKX_TYPE_DOUBLE,
    TKX_TYPE_ENUM, TKX_TYPE_COLOR, TKX_TYPE_FONT, TKX_TYPE_CURSOR,
    TKX_TYPE_PIXELS, TKX_TYPE_WINDOW, TKX_TYPE_INDEX, TKX_TYPE_LIST,
    TKX_TYPE_BITMAP, TKX_TYPE_CALLBACK, TKX_TYPE_OPAQUE
} TkxValueType;

#define TKX_OPT_NULL_OK     0x01u  /* may be set to empty / unset */
#define TKX_OPT_READONLY    0x02u  /* cannot be changed after creation */
#define TKX_OPT_ALIAS       0x04u  /* synonym of alias_of */
#define TKX_OPT_SCRIPT      0x08u  /* value is a Tcl script: not settable generically */
#define TKX_OPT_NO_ACCESSOR 0x10u  /* no typed accessor was generated */

typedef struct TkxOptionInfo {
    const char *name;            /* "-text" */
    const char *db_name;
    const char *db_class;
    TkxValueType type;
    unsigned flags;              /* TKX_OPT_* */
    const char *alias_of;        /* for aliases, else NULL */
    const char *const *enum_values;  /* for TKX_TYPE_ENUM, else NULL */
    int enum_count;
    const char *source;          /* provenance "generic/ttk/ttkButton.c:62" */
} TkxOptionInfo;

/* Introspection of the generated class metadata. */
TKX_API const char *tkx_kind_name(int kind);            /* "ttk::button" */
TKX_API int tkx_class_option_count(int kind);
TKX_API const TkxOptionInfo *tkx_class_option(int kind, int index);

/* ------------------------------------------------------------------ */
/* Generic widget command invocation (escape hatch)                    */
/* ------------------------------------------------------------------ */

/* Invoke "$widget subcommand arg..." with every argument passed as a
 * separate word (no script parsing, no substitution).  The subcommand
 * must be one of the extracted subcommands of the widget class; cget and
 * configure are refused (use the property functions).  result may be
 * NULL. */
TKX_API TkxStatus tkx_widget_call(TkxId widget, const char *subcommand,
	int argc, const char *const *argv, char **result);

/* ------------------------------------------------------------------ */
/* Callbacks and events                                                */
/* ------------------------------------------------------------------ */

/*
 * Callbacks are plain C function pointers with user data.  Registering
 * returns a callback handle (kind TKX_KIND_CALLBACK).  A callback is
 * released -- and its free_fn, if any, called exactly once -- when it is
 * removed with tkx_callback_remove(), replaced by another registration
 * for the same option or event sequence, when its widget is destroyed,
 * or at tkx_app_shutdown().  A callback may destroy its own widget or
 * remove itself; release is deferred until the callback returns.
 */
typedef void (*TkxFreeFn)(void *user_data);
typedef void (*TkxCommandFn)(TkxId widget, void *user_data);

typedef struct TkxEvent {
    TkxId widget;          /* widget the event was delivered to */
    const char *sequence;  /* sequence the callback was bound to */
    int x, y;              /* widget-relative pointer position (%x %y) */
    int root_x, root_y;    /* screen position (%X %Y) */
    int button;            /* mouse button (%b), 0 if not applicable */
    int keycode;           /* %k, 0 if not applicable */
    const char *keysym;    /* %K, "" if not applicable */
    const char *text;      /* %A: UTF-8 text of a key press, "" otherwise */
    int width, height;     /* %w %h for Configure events, else 0 */
    unsigned state;        /* modifier state (%s) */
    int delta;             /* mouse wheel delta (%D), 0 otherwise */
} TkxEvent;
typedef void (*TkxEventFn)(const TkxEvent *event, void *user_data);

/* Bind fn to a Tk event sequence ("<Button-1>", "<Return>",
 * "<<TreeviewSelect>>") on a widget.  One tkx binding exists per widget
 * and sequence; binding again replaces it. */
TKX_API TkxId tkx_bind(TkxId widget, const char *sequence, TkxEventFn fn,
	void *user_data, TkxFreeFn free_fn);

TKX_API TkxStatus tkx_callback_remove(TkxId callback);

/* Run fn once on the UI thread after delay_ms (Tk's "after"). */
TKX_API TkxId tkx_after(int delay_ms, TkxTaskFn fn, void *user_data, TkxFreeFn free_fn);

/* ------------------------------------------------------------------ */
/* Values shared by generated functions                                */
/* ------------------------------------------------------------------ */

/* Index argument meaning "end" (entry and treeview positions). */
#define TKX_INDEX_END (-1)

/* Sticky flags for grid. */
#define TKX_STICKY_N 0x1u
#define TKX_STICKY_S 0x2u
#define TKX_STICKY_E 0x4u
#define TKX_STICKY_W 0x8u
#define TKX_STICKY_NSEW 0xFu

#ifdef __cplusplus
}
#endif

/* Angle brackets: the include path decides which generated API is used
 * (the committed one, or one generated for another Tk version). */
#include <tkx_generated.h>

#endif /* TKX_H */
