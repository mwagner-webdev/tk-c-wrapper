#include "tk.h"
#define MY_TYPE (TK_OPTION_STRING)
static const Tk_OptionSpec BadTypeSpecs[] = {
    {MY_TYPE, "-text", "text", "Text", "", 0, TCL_INDEX_NONE, 0, 0, 0},
    {TK_OPTION_END, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0}
};
