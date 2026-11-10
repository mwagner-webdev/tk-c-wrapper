#define READONLY_OPTION	0x1
#define STYLE_CHANGED	0x2
#define GEOMETRY_CHANGED	0x4
typedef struct WidgetSpec_ WidgetSpec;
struct WidgetSpec_ {
    const char *className;
    size_t recordSize;
    const Tk_OptionSpec *optionSpecs;
    const Ttk_Ensemble *commands;
    void (*initializeProc)(void *, void *recordPtr);
};
#define WIDGET_TAKEFOCUS_TRUE \
    {TK_OPTION_STRING, "-takefocus", "takeFocus", "TakeFocus", \
	"ttk::takefocus", 0, TCL_INDEX_NONE, 0,0,0 }
#define WIDGET_INHERIT_OPTIONS(baseOptionSpecs) \
    {TK_OPTION_END, 0,0,0, NULL, TCL_INDEX_NONE,TCL_INDEX_NONE, 0, baseOptionSpecs, 0}
#define RegisterWidget(interp, name, specPtr) \
    Tcl_CreateObjCommand2(interp, name, TtkWidgetConstructorObjCmd, (void *)specPtr,NULL)
