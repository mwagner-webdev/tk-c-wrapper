# overrides.tcl --
#
#	Approach 2: small, explicitly marked schema overlays.
#
#	Each entry supplies semantics that Tk's declarative C tables do not
#	carry, states *why* extraction cannot provide it, and names the
#	source evidence the extractor verifies.  If the evidence disappears
#	or changes in a new Tk release, extraction fails or reports drift
#	instead of silently applying a stale overlay.
#
#	Nothing here restates information that is already extracted: option
#	names, types, defaults, aliases, enumerations and subcommand lists
#	always come from the sources.

namespace eval ::tkx::schema {

    # ------------------------------------------------------------------
    # Classic frame family: binding a widget command to its option table.
    #
    # Why: tkFrame.c creates frame, toplevel and labelframe with one
    # function (TkCreateFrame) and picks the option table at run time with
    # optionSpecs[type], where 'type' is an enum constant passed by the
    # command procedure.  The binding is code, not a declarative table.
    #
    # Verified: the TkCmd table maps the command to 'creator'; the
    # creator's body references exactly the enum member; the dispatch
    # array element at that member's ordinal is the option table; the
    # class-name array gives the class; each create-only option appears
    # as a string literal in the widget command procedure, which is where
    # tkFrame.c rejects changes to them.
    # ------------------------------------------------------------------
    variable classic {
	frame {
	    creator Tk_FrameObjCmd
	    file generic/tkFrame.c
	    dispatch {array optionSpecs enum FrameType member TYPE_FRAME}
	    classNames classNames
	    widgetCmd FrameWidgetObjCmd
	    createOnly {-class -colormap -container -visual}
	}
	toplevel {
	    creator Tk_ToplevelObjCmd
	    file generic/tkFrame.c
	    dispatch {array optionSpecs enum FrameType member TYPE_TOPLEVEL}
	    classNames classNames
	    widgetCmd FrameWidgetObjCmd
	    createOnly {-class -colormap -container -screen -use -visual}
	}
    }

    # ------------------------------------------------------------------
    # Option semantics that the option type alone does not express.
    #
    # Key: {widgetCommand optionName}; widgetCommand "*" applies to every
    # class that has the option.  'evidence' is checked against the
    # extracted option record (type and database class); a mismatch is a
    # drift error.
    #
    # treat:
    #   callback   the STRING option holds a Tcl script that Tk evaluates;
    #              the C API exposes it as a C function pointer instead.
    #              'args' names what Tk appends to the script (none here).
    #   excluded   not exposed as a typed accessor; 'why' says why.  The
    #              generic property interface can still reach it.
    #   type       refine the C type of a STRING option (e.g. a list).
    # ------------------------------------------------------------------
    variable options {
	{ttk::button -command} {
	    treat callback args {}
	    evidence {type STRING dbClass Command}
	    why "TK_OPTION_STRING does not say that the string is a script; ttkButton.c evaluates it with Tcl_EvalObjEx in ButtonInvokeCommand."
	}
	{* -textvariable} {
	    treat excluded
	    evidence {type STRING dbClass Variable}
	    why "Names a global Tcl variable that Tk traces; the C API has no Tcl variables. Use the -text accessor or the widget's get/set operations."
	}
	{* -variable} {
	    treat excluded
	    evidence {type STRING dbClass Variable}
	    why "Names a global Tcl variable that Tk traces; the C API has no Tcl variables."
	}
	{ttk::entry -validatecommand} {
	    treat excluded
	    evidence {type STRING dbClass ValidateCommand}
	    why "Script with %-substitutions whose boolean result controls editing; needs a dedicated callback protocol (not in the MVP)."
	}
	{ttk::entry -invalidcommand} {
	    treat excluded
	    evidence {type STRING dbClass InvalidCommand}
	    why "Script with %-substitutions run after failed validation; needs a dedicated callback protocol (not in the MVP)."
	}
	{* -xscrollcommand} {
	    treat excluded
	    evidence {type STRING dbClass ScrollCommand}
	    why "Script prefix to which Tk appends 'first last'; scrollbar wiring is not in the MVP."
	}
	{* -yscrollcommand} {
	    treat excluded
	    evidence {type STRING dbClass ScrollCommand}
	    why "Script prefix to which Tk appends 'first last'; scrollbar wiring is not in the MVP."
	}
	{* -takefocus} {
	    treat excluded
	    evidence {type STRING dbClass TakeFocus}
	    why "Value may be a Tcl script evaluated during keyboard traversal; exposing it as a plain string would let consumers inject Tcl code."
	}
	{ttk::treeview -columns} {
	    treat type type list
	    evidence {type STRING dbClass Columns}
	    why "TK_OPTION_STRING holding a Tcl list of column identifiers; ttkTreeview.c parses it with Tcl_ListObjGetElements."
	}
	{ttk::treeview -displaycolumns} {
	    treat type type list
	    evidence {type STRING dbClass DisplayColumns}
	    why "TK_OPTION_STRING holding a Tcl list of column identifiers (or #all)."
	}
	{ttk::treeview -show} {
	    treat type type list
	    evidence {type STRING dbClass Show}
	    why "TK_OPTION_STRING holding a Tcl list of the words tree and headings."
	}
    }
}

namespace eval ::tkx::schema {

    # ------------------------------------------------------------------
    # Subcommand signatures for operations whose evidence (resolve.tcl)
    # is incomplete.  Subcommands with complete evidence are generated
    # without an entry here.
    #
    # Key: {widgetCommand subcommand-path}; "*" matches every selected
    # class whose extracted ensemble contains the subcommand.
    #   name     C name suffix (default: path joined with "_")
    #   params   {{name type ?optional?} ...}
    #   words    how params become Tcl words after the subcommand path:
    #            NAME           the value of param NAME
    #            {-flag NAME}   "-flag value", only if NAME is given
    #            (default: every param in order)
    #   result   result type
    #   evidence {usage U}: U must be one of the Tcl_WrongNumArgs usage
    #            strings extracted from the implementing function.
    # ------------------------------------------------------------------
    variable commands {
	{ttk::entry insert} {
	    params {{index index} {text string}}
	    result none
	    evidence {usage "index text"}
	    why "The text argument is handed to the internal InsertChars as a Tcl_Obj, so the conversion vocabulary cannot type it; InsertChars leaves the result empty on success."
	}
	{ttk::entry delete} {
	    params {{first index} {last index optional}}
	    result none
	    evidence {usage "firstIndex ?lastIndex?"}
	    why "The result is delegated to the internal DeleteChars, which leaves it empty on success."
	}
	{ttk::button invoke} {
	    params {}
	    result none
	    evidence {usage "invoke"}
	    why "The result is that of the -command script; in tkx that script is the callback trampoline, whose result is empty."
	}
	{* state} {
	    name state_set
	    params {{spec statespec}}
	    result statespec
	    evidence {usage "state-spec"}
	    why "TtkWidgetStateCommand has a query form (no argument) and a set form; only the set form is generated here, the query form is state_get."
	}
	{* state#get} {
	    path state
	    name state_get
	    params {}
	    result statespec
	    evidence {usage "state-spec"}
	    why "Query form of the multi-form state subcommand."
	}
	{* instate} {
	    params {{spec statespec}}
	    result boolean
	    evidence {usage "state-spec ?script?"}
	    why "The optional second argument is a Tcl script; only the query form without a script is exposed."
	}
	{ttk::treeview insert} {
	    params {{parent item} {index index} {id string optional}}
	    words {parent index {-id id}}
	    result item
	    evidence {usage "?parent index?|?before|after item? ?-id id? ?-option value ...?"}
	    why "Variable number of arguments with an option-value tail; item options are set through the generated item accessors instead."
	}
	{ttk::treeview focus} {
	    name focus_get
	    params {}
	    result string
	    evidence {usage "?item?"}
	    why "Multi-form command: no argument queries the focus item (empty if none)."
	}
	{ttk::treeview focus#set} {
	    path focus
	    name focus_set
	    params {{item item}}
	    result none
	    evidence {usage "?item?"}
	    why "Multi-form command: one argument sets the focus item."
	}
	{ttk::treeview selection} {
	    name selection_get
	    params {}
	    result list
	    evidence {}
	    why "Multi-form command (query, or add/remove/set/toggle with an item list); the subcommand table selopStrings is extracted but the forms are code."
	}
	{ttk::treeview selection#set} {
	    path selection
	    name selection_set
	    params {{items itemlist}}
	    words {=set items}
	    result none
	    evidence {}
	    why "Set form of the multi-form selection subcommand."
	}
    }

    # ------------------------------------------------------------------
    # Sub-object option tables: options of things inside a widget that
    # are configured through a subcommand ("$tv item $id -text x").
    #
    # Verified: the option table exists in the widget's source file, a
    # Tk_CreateOptionTable(..., table) result is stored in field 'field',
    # and the subcommand's handler delegates to 'configure', whose body
    # uses that field.
    # ------------------------------------------------------------------
    variable subobjects {
	{ttk::treeview item} {
	    table ItemOptionSpecs key {item item} field itemOptionTable configure ConfigureItem
	    why "The link between the item subcommand and ItemOptionSpecs goes through a widget record field assigned at run time."
	}
	{ttk::treeview heading} {
	    table HeadingOptionSpecs key {column column} field headingOptionTable configure ConfigureHeading
	    why "Same pattern for column headings."
	}
	{ttk::treeview column} {
	    table ColumnOptionSpecs key {column column} field columnOptionTable configure ConfigureColumn
	    why "Same pattern for columns."
	}
    }

    variable subobjectOptions {
	{ttk::treeview item -values} {
	    treat type type list
	    evidence {type STRING dbClass Values}
	    why "TK_OPTION_STRING holding a Tcl list of column values."
	}
	{ttk::treeview item -tags} {
	    treat type type list
	    evidence {type STRING dbClass Tags}
	    why "TK_OPTION_STRING holding a Tcl list of tag names."
	}
	{ttk::treeview item -id} {
	    treat excluded
	    evidence {type STRING dbClass ID}
	    why "Only meaningful when the item is created (insert -id); see tkx_ttk_treeview_insert."
	}
	{ttk::treeview column -id} {
	    treat excluded
	    evidence {type STRING dbClass ID}
	    why "Column identifiers are fixed by -columns; changing -id after creation is not supported by the C API."
	}
	{ttk::treeview heading -command} {
	    treat excluded
	    evidence {type STRING dbClass ""}
	    why "Tcl script evaluated when the heading is clicked; heading callbacks are not in the MVP (use tkx_bind on the treeview)."
	}
    }

    # ------------------------------------------------------------------
    # Geometry managers.  Subcommand names, handlers, option names and
    # option value types are extracted (resolve.tcl); the overlay only
    # says which handler is the per-window configure operation, which is
    # the row/column operation, and gives signatures for the remaining
    # subcommands.  Every 'sub' must exist in the extracted subcommand
    # table and 'usage' must match the extracted usage string.
    # ------------------------------------------------------------------
    variable geometry {
	grid {
	    configure configure
	    info info
	    slots {rowconfigure columnconfigure}
	    composite {
		grid {options {-row row -column column}
		      why "Convenience: the most common grid call, 'grid configure w -row r -column c', as one function."}
	    }
	    commands {
		forget    {sub forget params {} result none usage ""
		           why "Variadic window list; the C function takes one widget."}
		remove    {sub remove params {} result none usage ""
		           why "Variadic window list; the C function takes one widget."}
		propagate_set {sub propagate params {{flag boolean}} result none usage "window ?boolean?"
		           why "Multi-form (query/set) subcommand."}
		propagate_get {sub propagate params {} result boolean usage "window ?boolean?"
		           why "Multi-form (query/set) subcommand."}
		anchor_set {sub anchor params {{anchor enum:ANCHOR}} result none usage "window ?anchor?"
		           why "Multi-form (query/set) subcommand."}
		anchor_get {sub anchor params {} result enum:ANCHOR usage "window ?anchor?"
		           why "Multi-form (query/set) subcommand."}
		size      {sub size params {} result list usage "window"
		           why "Returns a two-element list {columns rows}."}
		bbox      {sub bbox params {} result box usage "window ?column row ?column row??"
		           why "Optional cell-range arguments are not exposed."}
	    }
	}
	pack {
	    configure configure
	    info info
	    slots {}
	    composite {
		pack {options {}
		      why "Convenience: 'pack configure w' with Tk's default packing."}
	    }
	    commands {
		forget    {sub forget params {} result none usage ""
		           why "Implemented inline in Tk_PackObjCmd with a window list."}
		propagate_set {sub propagate params {{flag boolean}} result none usage "window ?boolean?"
		           why "Multi-form (query/set) subcommand."}
		propagate_get {sub propagate params {} result boolean usage "window ?boolean?"
		           why "Multi-form (query/set) subcommand."}
	    }
	}
    }

    # Options of non-selected or selected classes that are not exposed for
    # reasons specific to the C API (in addition to 'options' above).
    variable optionsExtra {
	{toplevel -menu} {
	    treat excluded
	    evidence {type STRING dbClass Menu}
	    why "Names a menu widget by path; menus are not part of the MVP."
	}
    }
}
