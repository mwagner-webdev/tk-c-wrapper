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

/* Use a few declarations so the compiler checks their types. */
static TkxStatus (*const set_text)(TkxId, const char *) = tkx_ttk_label_set_text;
static TkxId (*const create_button)(TkxId) = tkx_ttk_button_create;
static TkxStatus (*const grid_set_sticky)(TkxId, unsigned) = tkx_grid_set_sticky;

int tkx_header_only_check(void);
int tkx_header_only_check(void)
{
    TkxStringList l = {0, 0};
    TkxBox b = {0, 0, 0, 0};
    TkxRelief r = TKX_RELIEF_SUNKEN;
    (void)l; (void)b; (void)r;
    return (int)sizeof(set_text) + (int)sizeof(create_button) + (int)sizeof(grid_set_sticky)
	+ (int)sizeof(TkxId) + TKX_KIND_TTK_TREEVIEW;
}
