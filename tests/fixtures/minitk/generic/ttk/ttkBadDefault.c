#include "tk.h"
static const Tk_OptionSpec BadDefaultSpecs[] = {
    {TK_OPTION_STRING, "-text", "text", "Text", computeDefault(), 0, TCL_INDEX_NONE, 0, 0, 0},
    {TK_OPTION_END, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0}
};
