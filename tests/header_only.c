/*
 * header_only.c -- compile-only check that the public headers are self-
 * contained: no Tcl/Tk headers are on the include path for this file and
 * no Tcl/Tk type may appear.  Built with -std=c99 -pedantic -Werror and as
 * C++ (make header-test).
 */
#include "tkx.h"

#if defined(TCL_MAJOR_VERSION) || defined(TK_MAJOR_VERSION) || defined(_TCL) || defined(_TK)
#error "tkx.h must not include Tcl/Tk headers"
#endif

int tkx_header_only_check(void);
int tkx_header_only_check(void)
{
    /* Assign a few functions to typed pointers so the compiler checks their
     * types.  Locals, not static initializers: with dllimport (Windows) a
     * function's address is not a constant expression in C. */
    TkxStatus (*set_text)(TkxId, const char *) = tkx_ttk_label_set_text;
    TkxId (*create_button)(TkxId) = tkx_ttk_button_create;
    TkxStatus (*grid_set_sticky)(TkxId, unsigned) = tkx_grid_set_sticky;
    TkxStringList l = {0, 0};
    TkxBox b = {0, 0, 0, 0};
    TkxRelief r = TKX_RELIEF_SUNKEN;
    (void)set_text; (void)create_button; (void)grid_set_sticky;
    (void)l; (void)b; (void)r;
    return (int)sizeof(TkxId) + TKX_KIND_TTK_TREEVIEW;
}
