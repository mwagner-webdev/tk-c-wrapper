#include "tk.h"
static const Tk_OptionSpec BadFlagSpecs[] = {
    {TK_OPTION_STRING, "-text", "text", "Text", "", 0, TCL_INDEX_NONE, SOME_UNKNOWN_FLAG, 0, 0},
    {TK_OPTION_END, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0}
};
