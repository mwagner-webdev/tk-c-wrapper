typedef int Tcl_ObjCmdProc2;
typedef struct TtkEnsemble {
    const char *name;			/* subcommand name */
    Tcl_ObjCmdProc2 *command;		/* implementation, OR: */
    const struct TtkEnsemble *ensemble;	/* nested ensemble */
} Ttk_Ensemble;
#define TTK_BEGIN_LAYOUT(name)	static int name[] = {
#define TTK_NODE(name, flags)	1,
#define TTK_END_LAYOUT		0 };
