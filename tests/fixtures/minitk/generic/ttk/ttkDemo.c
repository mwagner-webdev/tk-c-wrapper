/*
 * ttkDemo.c -- extractor fixture.  Formatting is deliberately awkward:
 * comments with braces { and commas, strings with escaped quotes and
 * braces, macros, a platform-specific default and a configuration-
 * dependent option.
 */
#include "tk.h"
#include "ttkTheme.h"
#include "ttkWidget.h"
#include "default.h"

#define DEF_DEMO_LABEL "a \"quoted\", {braced} label"
#define LOCAL_MASK (GEOMETRY_CHANGED | 0x100)

static const char *const demoModeStrings[] = {
    "fast", /* a comment, with a comma } */ "slow",
    "very\tslow", NULL
};

static const Tk_OptionSpec BaseSpecs[] = {
    {TK_OPTION_STRING, "-class", "", "", NULL,
	0, TCL_INDEX_NONE, 0,0,READONLY_OPTION},
    {TK_OPTION_STRING, "-style", "style", "Style", "",
	0, TCL_INDEX_NONE, 0,0,STYLE_CHANGED},
    {TK_OPTION_END, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0}
};

static const Tk_OptionSpec DemoSpecs[] = {
    {TK_OPTION_STRING,   "-text",    "text", "Text",
	DEF_DEMO_LABEL, 0, TCL_INDEX_NONE, 0, 0, LOCAL_MASK},
    {TK_OPTION_BORDER, "-background", "background", "Background",
	DEF_DEMO_BG, TCL_INDEX_NONE, 0, TK_OPTION_NULL_OK, "white", 0},
    {TK_OPTION_SYNONYM, "-bg", NULL, NULL,
	NULL, 0, TCL_INDEX_NONE, 0, "-background", 0},
    {TK_OPTION_STRING_TABLE, "-mode", "mode", "Mode",
	"fast", TCL_INDEX_NONE, 0,
	TK_OPTION_VAR(int), demoModeStrings, 0},
    {TK_OPTION_INT, "-width" /* trailing comment } */, "width", "Width",
	DEF_DEMO_WIDTH, 0, TCL_INDEX_NONE, 0, 0, GEOMETRY_CHANGED},
#ifdef HAVE_FANCY
    {TK_OPTION_BOOLEAN, "-fancy", "fancy", "Fancy",
	"0", 0, TCL_INDEX_NONE, 0, 0, 0},
#endif
    {TK_OPTION_STRING, "-style", "style", "Style", "Demo.TLabel",
	0, TCL_INDEX_NONE, 0, 0, 0},
    WIDGET_TAKEFOCUS_TRUE,
    WIDGET_INHERIT_OPTIONS(BaseSpecs)
};

static int DemoGetCommand(void *recordPtr, void *interp, long objc, void *const objv[])
{
    if (objc != 2) {
	Tcl_WrongNumArgs(interp, 2, objv, NULL);
	return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj("x", -1));
    return TCL_OK;
}

static int DemoSetCommand(void *recordPtr, void *interp, long objc, void *const objv[])
{
    int n;
    if ((objc < 3) || (objc > 4)) {
	Tcl_WrongNumArgs(interp, 2, objv, "count ?label?");
	return TCL_ERROR;
    }
    if (Tcl_GetIntFromObj(interp, objv[2], &n) != TCL_OK) {
	return TCL_ERROR;
    }
    if (objc == 4) {
	DoLabel(Tcl_GetString(objv[3]));
    }
    return TCL_OK;
}

static int DemoMoveCommand(void *recordPtr, void *interp, long objc, void *const objv[])
{
    int option;
    if (objc != 3) {
	Tcl_WrongNumArgs(interp, 2, objv, "where");
	return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObjStruct(NULL, objv[2], demoModeStrings, sizeof(char *),
	    "option", 0, &option) != TCL_OK) {
	if (Tcl_GetIntFromObj(interp, objv[2], &option) != TCL_OK) {
	    return TCL_ERROR;
	}
    }
    return TCL_OK;
}

static int DemoQueryCommand(void *recordPtr, void *interp, long objc, void *const objv[])
{
    if (objc == 2) {
	Tcl_SetObjResult(interp, Tcl_NewBooleanObj(1));
	return TCL_OK;
    }
    if (objc != 3) {
	Tcl_WrongNumArgs(interp, 2, objv, "?flag?");
	return TCL_ERROR;
    }
    return TCL_OK;
}

static const Ttk_Ensemble DemoSubCommands[] = {
    { "move",	DemoMoveCommand,0 },
    { 0,0,0 }
};

static const Ttk_Ensemble DemoCommands[] = {
    { "get",	DemoGetCommand, 0 },
    { "query",	DemoQueryCommand, 0 },
    { "set",	DemoSetCommand, 0 },
    { "sub",	0, DemoSubCommands },
    { 0,0,0 }
};

static const WidgetSpec DemoWidgetSpec = {
    "TDemo",
    sizeof(int),
    DemoSpecs,
    DemoCommands,
    0
};

TTK_BEGIN_LAYOUT(DemoLayout)
    TTK_NODE("Demo.label", 0)
TTK_END_LAYOUT

static const Tk_OptionSpec AfterLayoutSpecs[] = {
    {TK_OPTION_DOUBLE, "-angle", "angle", "Angle", "0.0", 0, TCL_INDEX_NONE, 0, 0, 0},
    {TK_OPTION_END, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0}
};

void
TtkDemo_Init(void *interp)
{
    RegisterWidget(interp, "ttk::demo", &DemoWidgetSpec);
}
