/* Minimal stand-in for tk.h: the struct layouts the extractor reads. */
#ifndef _TK
#define _TK
#include <tcl.h>
#define TK_PATCH_LEVEL "0.0.1"
typedef enum {
    TK_OPTION_BOOLEAN, TK_OPTION_INT, TK_OPTION_DOUBLE, TK_OPTION_STRING,
    TK_OPTION_STRING_TABLE, TK_OPTION_COLOR, TK_OPTION_FONT,
    TK_OPTION_BITMAP, TK_OPTION_BORDER, TK_OPTION_RELIEF, TK_OPTION_CURSOR,
    TK_OPTION_JUSTIFY, TK_OPTION_ANCHOR, TK_OPTION_SYNONYM,
    TK_OPTION_PIXELS, TK_OPTION_WINDOW, TK_OPTION_END, TK_OPTION_CUSTOM,
    TK_OPTION_STYLE, TK_OPTION_INDEX
} Tk_OptionType;
typedef struct Tk_OptionSpec {
    Tk_OptionType type;
    const char *optionName;
    const char *dbName;
    const char *dbClass;
    const char *defValue;
    Tcl_Size objOffset;
    Tcl_Size internalOffset;
    int flags;
    const void *clientData;
    int typeMask;
} Tk_OptionSpec;
#define TK_OPTION_DONT_SET_DEFAULT (1 << 3)
#define TK_OPTION_NULL_OK TCL_NULL_OK
#define TK_OPTION_VAR(type) ((sizeof(type) < 2 * sizeof(int)) ? 64 : 192)
#endif
