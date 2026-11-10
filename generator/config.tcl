# config.tcl --
#
#	Extraction configuration: *where* to look in a Tk source tree and how
#	Tk's own C vocabulary maps to semantic types.  Nothing in this file
#	describes an individual widget: widget classes, options, defaults,
#	enumerations and subcommands are all discovered from the sources.
#
#	The vocabulary tables below name Tcl/Tk C functions and give the
#	value type each one parses or produces.  They are used to interpret
#	imperative code (subcommand bodies, geometry-manager option parsing).
#	Every inference made with them is recorded with the function name and
#	source location, and anything not covered is reported as unresolved.

namespace eval ::tkx::config {
    # Platform configurations evaluated for every scanned file.  Only
    # platform-intrinsic macros are predefined; any other undefined macro
    # met in an #if is recorded as an assumption (see cpp.tcl).
    variable platforms {
	unix {
	    predefined {}
	    tkdirs {generic generic/ttk unix bitmaps}
	    tcldirs {generic unix}
	}
	win {
	    predefined {_WIN32 1 WIN32 1}
	    tkdirs {generic generic/ttk win xlib bitmaps}
	    tcldirs {generic win}
	}
	macos {
	    predefined {MAC_OSX_TK 1 MAC_OSX_TCL 1 __APPLE__ 1 __MACH__ 1 __OBJC__ 1}
	    tkdirs {generic generic/ttk macosx xlib bitmaps}
	    tcldirs {generic macosx unix}
	}
    }
    variable knownPlatformMacros {
	_WIN32 WIN32 MAC_OSX_TK MAC_OSX_TCL __APPLE__ __MACH__ __OBJC__
    }

    # Headers whose declarations (not only macros) are needed: the struct
    # layouts of the declarative tables are read from here, so a change
    # of field order in Tk is picked up rather than assumed.
    variable keepHeaders {
	generic/tk.h generic/ttk/ttkTheme.h generic/ttk/ttkWidget.h
    }

    # Source discovery.  ttk widget implementations are found by scanning
    # every generic/ttk/*.c file for RegisterWidget calls; the files below
    # are always scanned because they hold shared tables.
    variable ttkGlob generic/ttk/*.c
    variable ttkSupport {
	generic/ttk/ttkInit.c generic/ttk/ttkWidget.c generic/ttk/ttkScroll.c
    }
    variable classicFiles {
	generic/tkWindow.c generic/tkFrame.c generic/tkGrid.c
	generic/tkPack.c generic/tkConfig.c generic/tk3d.c generic/tkGet.c
    }

    # Identifiers never macro-expanded inside extracted initializers: they
    # are interpreted symbolically (flags) or are opaque (offsets).
    variable protect {
	TK_OPTION_NULL_OK TK_OPTION_VAR TK_OPTION_ENUM_VAR
	TK_OPTION_DONT_SET_DEFAULT TK_OPTION_NEG_OK
	TCL_INDEX_NONE NULL offsetof sizeof
    }

    # Option-spec flag vocabulary (tk.h).
    variable optionFlags {
	TK_OPTION_NULL_OK nullOk
	TK_OPTION_DONT_SET_DEFAULT dontSetDefault
	TK_OPTION_ENUM_VAR enumVar
	TK_OPTION_VAR storageVar
	TK_OPTION_NEG_OK negOk
    }

    # Built-in option types whose legal values come from a string table.
    # The binding (type -> table) is *extracted* from tkConfig.c's
    # DoObjConfig switch; this list only names the types to look for.
    variable builtinEnumTypes {RELIEF JUSTIFY ANCHOR}

    # Value-conversion vocabulary: C function -> semantic type.
    # "enum@N" means: the legal values are the string table passed as
    # argument N (0-based).  A key "fn@N" applies only to argument N of fn.
    # "script" marks a value that Tk evaluates as Tcl code; such
    # subcommands are refused by the generic tkx_widget_call().
    variable conversions {
	Tcl_GetIntFromObj		int
	Tcl_GetSizeIntFromObj		int
	Tcl_GetBooleanFromObj		boolean
	Tcl_GetBoolFromObj		boolean
	Tcl_GetDoubleFromObj		double
	Tk_GetPixelsFromObj		pixels
	Tk_GetDoublePixelsFromObj	pixels
	TkParsePadAmount		padding
	TkGetWindowFromObj		window
	Tk_GetAnchorFromObj		anchor
	Tk_GetJustifyFromObj		justify
	Tk_GetReliefFromObj		relief
	StringToSticky			sticky
	Tcl_GetIndexFromObj		enum@2
	Tcl_GetIndexFromObjStruct	enum@2
	TkGetIntForIndex		index
	EntryIndex			index
	Tcl_GetString			string
	Tcl_GetStringFromObj		string
	Tk_GetUid			string
	TtkGetStateSpecFromObj		statespec
	Ttk_GetStateSpecFromObj		statespec
	Tcl_EvalObjEx			script
	Tcl_EvalObjv			script
	Tk_CreateBinding@3		string
	Tk_CreateBinding@4		script
	FindItem			item
	GetItemListFromObj		itemlist
	FindColumn			column
	Ttk_GetTagFromObj		tag
    }

    # Result-constructor vocabulary for Tcl_SetObjResult(interp, CTOR(...)).
    variable results {
	Tcl_NewStringObj	string
	Tcl_NewBooleanObj	boolean
	Tcl_NewIntObj		int
	Tcl_NewWideIntObj	int
	Tcl_NewSizeIntObj	int
	TkNewIndexObj		int
	Tcl_NewDoubleObj	double
	Ttk_NewBoxObj		box
	Tcl_NewListObj		list
	Ttk_NewStateSpecObj	statespec
	ItemID			item
    }

    # Result fields: Tcl_SetObjResult(interp, x->FIELD) where FIELD holds a
    # Tcl_Obj of a known kind (ttkTreeview.c keeps item ids in idObj).
    variable resultFields {
	idObj	item
    }
}
