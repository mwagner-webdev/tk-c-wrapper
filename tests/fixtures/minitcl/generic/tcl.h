/* Minimal stand-in for tcl.h used by the extractor fixtures. */
#ifndef _TCL
#define _TCL
#define TCL_PATCH_LEVEL "0.0.1"
#define TCL_INDEX_NONE ((Tcl_Size)-1)
#define TCL_NULL_OK 32
#ifndef NULL
#define NULL ((void *)0)
#endif
typedef long Tcl_Size;
#endif
