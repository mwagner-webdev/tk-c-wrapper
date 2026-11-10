# extract.tcl --
#
#	Deterministic extraction of Tk's widget-command interface from Tk's C
#	sources (Approach 1).  Produces a normalised intermediate
#	representation (IR, a Tcl dict) with provenance for every item.
#
#	Tier A (declarative, exact):
#	    Tk_OptionSpec tables, Ttk_Ensemble tables, ttk WidgetSpecs,
#	    RegisterWidget calls, the TkCmd command table, string tables,
#	    enums, built-in enum bindings (tkConfig.c).
#	Tier B (constrained evidence from imperative code):
#	    subcommand arity/usage/argument conversions/result constructors,
#	    geometry-manager subcommands and option value conversions.
#	Anything outside these patterns is reported, never guessed.
#
#	Usage as a script:
#	    tclsh extract.tcl --tk-src DIR --tcl-src DIR ?--out FILE?
#	writes the IR as a Tcl dict (used by generate.tcl).

set dir [file dirname [file normalize [info script]]]
source [file join $dir cpp.tcl]
source [file join $dir cparse.tcl]
source [file join $dir config.tcl]

namespace eval ::tkx::extract {
    variable diags {}
    variable units	;# array: "$plat,$rel" -> unit dict
    variable tkRoot
    variable tclRoot
    variable here [file dirname [file normalize [info script]]]
}

proc ::tkx::extract::Diag {level where msg} {
    variable diags
    lappend diags [list $level $where $msg]
}

proc ::tkx::extract::Fail {where msg} {
    return -code error -errorcode {TKX EXTRACT} "EXTRACT $where: $msg"
}

# ---------------------------------------------------------------------
# Translation units
# ---------------------------------------------------------------------

proc ::tkx::extract::PlatformConfig {plat} {
    variable tkRoot
    variable tclRoot
    set p [dict get $::tkx::config::platforms $plat]
    set inc {}
    foreach d [dict get $p tkdirs] { lappend inc [file join $tkRoot $d] }
    foreach d [dict get $p tcldirs] { lappend inc [file join $tclRoot $d] }
    return [dict create name $plat predefined [dict get $p predefined] \
	    known $::tkx::config::knownPlatformMacros incpath $inc \
	    keepHeaders $::tkx::config::keepHeaders]
}

proc ::tkx::extract::Unit {plat rel} {
    variable units
    variable tkRoot
    variable tclRoot
    if {[info exists units($plat,$rel)]} { return $units($plat,$rel) }
    set r [cpp::run [file join $tkRoot $rel] [PlatformConfig $plat] \
	    [list $tkRoot "" $tclRoot "tcl:"]]
    set toks [dict get $r tokens]
    set macros [dict get $r macros]
    set idx [cparse::index $toks $rel [list ::tkx::extract::StmtMacro $macros]]
    CheckDeclForms $idx $rel
    set hidx [dict create]
    dict for {h htoks} [dict get $r headerTokens] {
	dict set hidx $h [cparse::index $htoks $h]
    }
    foreach d [dict get $r diags] {
	lassign $d level where msg
	# #error directives reached in headers that are irrelevant to the
	# extracted tables are informational, but stay visible.
	Diag note $where "\[$plat] preprocessing $rel: $msg"
    }
    set u [dict create rel $rel plat $plat toks $toks idx $idx hidx $hidx \
	    macros [dict get $r macros] conds [dict get $r conds] skips [dict get $r skips]]
    set units($plat,$rel) $u
    return $u
}

# Is name (at raw position pos) a macro whose body ends a statement?
proc ::tkx::extract::StmtMacro {macros name pos} {
    if {![dict exists $macros $name]} { return 0 }
    set def [cpp::lookupIn $macros $name $pos]
    if {$def eq {}} { return 0 }
    set last [lindex [dict get $def body] end 1]
    return [expr {$last in {; \}}}]
}

# Every initialised declaration that mentions one of the extracted table
# types must have exactly the canonical form, otherwise extraction fails
# instead of silently skipping a table.
proc ::tkx::extract::CheckDeclForms {idx rel} {
    foreach d [dict get $idx decls] {
	set words [dict get $d type]
	foreach tt {Tk_OptionSpec Ttk_Ensemble WidgetSpec TkCmd} {
	    if {$tt in $words && [BaseType $words] ni [list [list $tt] [list $tt *]]} {
		Fail "$rel:[dict get $d line]" "declaration of [dict get $d name] mentions $tt but has an unsupported form: $words"
	    }
	}
    }
}

proc ::tkx::extract::Platforms {} {
    lsort [dict keys $::tkx::config::platforms]
}

# Base type of a declaration: type words without qualifiers.
proc ::tkx::extract::BaseType {words} {
    set out {}
    foreach w $words {
	if {$w in {static const extern MODULE_SCOPE volatile register}} continue
	lappend out $w
    }
    return $out
}

proc ::tkx::extract::Struct {u name} {
    foreach h [lsort [dict keys [dict get $u hidx]]] {
	set structs [dict get $u hidx $h structs]
	if {[dict exists $structs $name]} {
	    return [list [dict get $structs $name fields] $h]
	}
    }
    set structs [dict get $u idx structs]
    if {[dict exists $structs $name]} {
	return [list [dict get $structs $name fields] [dict get $u rel]]
    }
    Fail [dict get $u rel] "struct $name not found in scanned headers"
}

# Macro-expand and parse a declaration's initializer.
proc ::tkx::extract::InitTree {u decl} {
    set toks {}
    set conds {}
    foreach t [lrange [dict get $u toks] [dict get $decl initStart] [dict get $decl initEnd]] {
	lappend toks [lrange $t 0 2]
	set c [lindex $t 3]
	if {$c != 0 && $c ni $conds} { lappend conds $c }
    }
    set rel [dict get $u rel]
    set where "$rel:[dict get $decl line]"
    set exp [cpp::expand $toks [list cpp::lookupIn [dict get $u macros]] \
	    [dict get $decl initStart] $::tkx::config::protect $where]
    set tree [cparse::parseInit $exp $rel]
    set condText {}
    foreach c [lsort -integer $conds] { lappend condText [lindex [dict get $u conds] $c] }
    # Regions skipped under an assumption inside the initializer.
    foreach sk [dict get $u skips] {
	lassign $sk pos text
	if {$pos >= [dict get $decl initStart] && $pos <= [dict get $decl initEnd]} {
	    lappend condText $text
	}
    }
    return [list $tree $condText]
}

proc ::tkx::extract::DeclsOfType {u type} {
    set out {}
    foreach d [dict get $u idx decls] {
	if {[BaseType [dict get $d type]] eq $type} { lappend out $d }
    }
    return $out
}

proc ::tkx::extract::Macro {u name {pos end}} {
    return [cpp::lookupIn [dict get $u macros] $name $pos]
}

# Integer value of an expanded expression (enum/macro constants only).
proc ::tkx::extract::IntValue {u e where} {
    set exp [cpp::expand [lindex $e 1] [list cpp::lookupIn [dict get $u macros]] \
	    end {} $where]
    set s ""
    foreach t $exp {
	lassign $t kind text
	switch -- $kind {
	    num {
		if {![regexp -nocase {^(0x[0-9a-f]+|[0-9]+)[ul]*$} $text -> d]} {
		    Fail $where "unsupported number $text"
		}
		append s " $d"
	    }
	    punct {
		if {$text ni {( ) | & << >> + - ~ *}} {
		    Fail $where "unsupported operator '$text' in constant expression"
		}
		append s " $text"
	    }
	    default { Fail $where "cannot evaluate constant expression (identifier '$text')" }
	}
    }
    if {[catch {expr $s} v]} { Fail $where "cannot evaluate '$s'" }
    return $v
}

# ---------------------------------------------------------------------
# Tier A: declarative tables
# ---------------------------------------------------------------------

proc ::tkx::extract::StringTables {u} {
    set out [dict create]
    foreach d [dict get $u idx decls] {
	if {![dict get $d array]} continue
	set bt [BaseType [dict get $d type]]
	if {$bt ne {char *}} continue
	lassign [InitTree $u $d] tree conds
	set values {}
	set terminated 0
	set ok 1
	foreach el [lindex $tree 1] {
	    if {[lindex $el 0] ne "e"} { set ok 0; break }
	    if {[cparse::isNull $el]} { set terminated 1; break }
	    if {![cparse::isString $el]} { set ok 0; break }
	    lappend values [cparse::strValue $el [dict get $u rel]]
	}
	if {!$ok} continue
	set key [dict get $d name]
	set scope [dict get $d scope]
	dict set out [list $scope $key] [dict create name $key scope $scope \
		values $values terminated $terminated \
		src "[dict get $u rel]:[dict get $d line]" conds $conds]
    }
    return $out
}

proc ::tkx::extract::Enums {u} {
    set out {}
    foreach e [dict get $u idx enums] {
	set members {}
	set next 0
	foreach m [dict get $e members] {
	    set v [dict get $m value]
	    if {[llength $v]} {
		if {[llength $v] == 1 && [string is integer -strict [lindex $v 0]]} {
		    set next [lindex $v 0]
		} else {
		    set next ""	;# symbolic; ordinals after this are unknown
		}
	    }
	    lappend members [list [dict get $m name] $next]
	    if {$next ne ""} { incr next }
	}
	lappend out [dict create tag [dict get $e tag] typedef [dict get $e typedef] \
		scope [dict get $e scope] members $members \
		src "[dict get $e file]:[dict get $e line]"]
    }
    return $out
}

proc ::tkx::extract::OptionTables {u} {
    set rel [dict get $u rel]
    set out [dict create]
    set decls [DeclsOfType $u Tk_OptionSpec]
    if {![llength $decls]} { return $out }
    lassign [Struct $u Tk_OptionSpec] fields fsrc
    foreach need {type optionName dbName dbClass defValue flags clientData typeMask} {
	if {$need ni $fields} {
	    Fail $fsrc "Tk_OptionSpec has no field '$need' (fields: $fields)"
	}
    }
    set typeEnum [OptionTypeEnum $u]
    set readonlyBit ""
    set ro [Macro $u READONLY_OPTION]
    foreach d $decls {
	if {![dict get $d array]} continue
	set name [dict get $d name]
	set where "$rel:[dict get $d line]"
	lassign [InitTree $u $d] tree conds
	set entries {}
	set chain ""
	set i 0
	foreach el [lindex $tree 1] {
	    incr i
	    if {[lindex $el 0] ne "g"} {
		Fail "$rel:[lindex $el 2]" "option table $name: element $i is not a brace group"
	    }
	    set kids [lindex $el 1]
	    if {[llength $kids] > [llength $fields]} {
		Fail "$rel:[lindex $el 2]" "option table $name: too many fields"
	    }
	    set f [dict create]
	    foreach fname $fields kid $kids {
		if {$fname eq ""} break
		dict set f $fname $kid
	    }
	    set eline [lindex $el 2]
	    set ewhere "$rel:$eline"
	    set tid [cparse::ident [dict get $f type]]
	    if {![string match TK_OPTION_* $tid] || [string range $tid 10 end] ni $typeEnum} {
		Fail $ewhere "option table $name: unsupported option type expression '[cparse::words [dict get $f type]]'"
	    }
	    set type [string range $tid 10 end]
	    if {$type eq "END"} {
		set cd [expr {[dict exists $f clientData] ? [dict get $f clientData] : {e {{num 0 0}} 0}}]
		if {![cparse::isNull $cd]} {
		    set chain [cparse::ident $cd]
		    if {$chain eq ""} {
			Fail $ewhere "option table $name: unsupported chain expression"
		    }
		}
		set endOrigin [cparse::origin [dict get $f type]]
		break
	    }
	    set rec [dict create type $type line $eline]
	    set rec [dict merge $rec [OptionEntry $u $f $type $ewhere $name]]
	    set org [cparse::origin [dict get $f type]]
	    if {$org ne ""} { dict set rec viaMacro $org }
	    if {[dict exists $f typeMask]} {
		set mask [IntValue $u [dict get $f typeMask] $ewhere]
	    } else { set mask 0 }
	    dict set rec typeMask $mask
	    lappend entries $rec
	}
	dict set out $name [dict create name $name scope [dict get $d scope] \
		src $where entries $entries chain $chain conds $conds]
    }
    return $out
}

proc ::tkx::extract::OptionTypeEnum {u} {
    foreach h [lsort [dict keys [dict get $u hidx]]] {
	foreach e [dict get $u hidx $h enums] {
	    if {[dict get $e typedef] eq "Tk_OptionType"} {
		set out {}
		foreach m [dict get $e members] {
		    lappend out [string range [dict get $m name] 10 end]
		}
		return $out
	    }
	}
    }
    Fail [dict get $u rel] "enum Tk_OptionType not found in scanned headers"
}

proc ::tkx::extract::OptionEntry {u f type where table} {
    set rel [dict get $u rel]
    set rec [dict create]
    foreach k {optionName dbName dbClass} {
	set e [dict get $f $k]
	if {[cparse::isNull $e]} { dict set rec $k "" ; continue }
	if {![cparse::isString $e]} {
	    Fail $where "option table $table: field $k is not a string literal"
	}
	dict set rec $k [cparse::strValue $e $rel]
    }
    if {[dict get $rec optionName] eq ""} {
	Fail $where "option table $table: option without a name"
    }
    set dv [dict get $f defValue]
    if {[cparse::isNull $dv]} {
	dict set rec default {}
	dict set rec hasDefault 0
    } elseif {[cparse::isString $dv]} {
	dict set rec default [cparse::strValue $dv $rel]
	dict set rec hasDefault 1
    } else {
	Fail $where "option [dict get $rec optionName]: unsupported default expression '[cparse::words $dv]'"
    }
    set org [cparse::origin $dv]
    if {$org ne ""} {
	dict set rec defaultMacro $org
	set md [Macro $u $org]
	if {$md ne {}} {
	    dict set rec defaultMacroSrc "[dict get $md file]:[dict get $md line]"
	}
    }
    # Flags: top-level '|' terms, interpreted symbolically.
    set flags {}
    set terms {}
    set cur {}
    set depth 0
    foreach t [lindex [dict get $f flags] 1] {
	set x [lindex $t 1]
	if {$x eq "("} { incr depth }
	if {$x eq ")"} { incr depth -1 }
	if {$x eq "|" && $depth == 0} { lappend terms $cur; set cur {}; continue }
	lappend cur $x
    }
    lappend terms $cur
    foreach term $terms {
	set w [lindex $term 0]
	if {$term eq {0}} continue
	if {[dict exists $::tkx::config::optionFlags $w]
		&& ([llength $term] == 1 || [lindex $term 1] eq "(")} {
	    lappend flags [dict get $::tkx::config::optionFlags $w]
	    continue
	}
	Fail $where "option [dict get $rec optionName]: unsupported flag term '$term'"
    }
    dict set rec flags [lsort -unique $flags]
    # clientData, interpreted by type.
    set cd [expr {[dict exists $f clientData] ? [dict get $f clientData] : {e {{num 0 0}} 0}}]
    switch -- $type {
	STRING_TABLE {
	    set id [cparse::ident $cd]
	    if {$id eq ""} {
		Fail $where "option [dict get $rec optionName]: STRING_TABLE without table identifier"
	    }
	    dict set rec stringTable $id
	}
	SYNONYM {
	    if {![cparse::isString $cd]} {
		Fail $where "option [dict get $rec optionName]: SYNONYM without target"
	    }
	    dict set rec synonymOf [cparse::strValue $cd $rel]
	}
	CUSTOM {
	    set w [cparse::words $cd]
	    if {[llength $w] != 2 || [lindex $w 0] ne "&"} {
		Fail $where "option [dict get $rec optionName]: unsupported custom option reference"
	    }
	    dict set rec customOption [lindex $w 1]
	}
	COLOR - BORDER {
	    if {[cparse::isString $cd]} {
		dict set rec monoDefault [cparse::strValue $cd $rel]
	    } elseif {![cparse::isNull $cd]} {
		Fail $where "option [dict get $rec optionName]: unsupported clientData"
	    }
	}
	default {
	    if {![cparse::isNull $cd]} {
		Fail $where "option [dict get $rec optionName]: unexpected clientData '[cparse::words $cd]' for type $type"
	    }
	}
    }
    return $rec
}

# Generic struct-array table reader: returns list of field dicts with raw
# expression elements (used for Ttk_Ensemble and TkCmd tables).
proc ::tkx::extract::StructArray {u d structName} {
    set rel [dict get $u rel]
    lassign [Struct $u $structName] fields
    lassign [InitTree $u $d] tree conds
    set rows {}
    foreach el [lindex $tree 1] {
	if {[lindex $el 0] ne "g"} {
	    Fail "$rel:[lindex $el 2]" "$structName table [dict get $d name]: element is not a brace group"
	}
	set row [dict create line [lindex $el 2]]
	foreach fname $fields kid [lindex $el 1] {
	    if {$fname eq ""} {
		Fail "$rel:[lindex $el 2]" "$structName table [dict get $d name]: too many fields"
	    }
	    if {$kid eq ""} { set kid {e {{num 0 0}} 0} }
	    dict set row $fname $kid
	}
	lappend rows $row
    }
    return [list $rows $fields $conds]
}

proc ::tkx::extract::Ensembles {u} {
    set rel [dict get $u rel]
    set out [dict create]
    foreach d [DeclsOfType $u Ttk_Ensemble] {
	lassign [StructArray $u $d Ttk_Ensemble] rows fields conds
	lassign $fields fName fCmd fEns
	set entries {}
	foreach row $rows {
	    set ne [dict get $row $fName]
	    if {[cparse::isNull $ne]} break
	    set name [cparse::strValue $ne $rel]
	    set cmd [dict get $row $fCmd]
	    set ens [dict get $row $fEns]
	    set rec [dict create name $name line [dict get $row line]]
	    if {![cparse::isNull $cmd]} {
		dict set rec func [cparse::ident $cmd]
	    }
	    if {![cparse::isNull $ens]} {
		dict set rec ensemble [cparse::ident $ens]
	    }
	    if {[dict exists $rec func] == [dict exists $rec ensemble]} {
		Fail "$rel:[dict get $row line]" "ensemble entry '$name' must have exactly one of command/ensemble"
	    }
	    lappend entries $rec
	}
	dict set out [dict get $d name] [dict create name [dict get $d name] \
		src "$rel:[dict get $d line]" entries $entries conds $conds]
    }
    return $out
}

proc ::tkx::extract::WidgetSpecs {u} {
    set rel [dict get $u rel]
    set out [dict create]
    set decls [DeclsOfType $u WidgetSpec]
    if {![llength $decls]} { return $out }
    set td [dict get [lindex [dict values [dict get $u hidx]] 0] typedefs]
    foreach h [lsort [dict keys [dict get $u hidx]]] {
	set td [dict get $u hidx $h typedefs]
	if {[dict exists $td WidgetSpec]} break
    }
    set sname [expr {[dict exists $td WidgetSpec] ? [dict get $td WidgetSpec] : "WidgetSpec"}]
    lassign [Struct $u $sname] fields
    foreach need {className optionSpecs commands} {
	if {$need ni $fields} { Fail $rel "WidgetSpec has no field $need" }
    }
    foreach d $decls {
	lassign [InitTree $u $d] tree conds
	set rec [dict create name [dict get $d name] src "$rel:[dict get $d line]"]
	foreach fname $fields kid [lindex $tree 1] {
	    if {$fname eq ""} { Fail "$rel:[dict get $d line]" "WidgetSpec: too many fields" }
	    if {$fname eq "className"} {
		dict set rec className [cparse::strValue $kid $rel]
	    } elseif {$fname in {optionSpecs commands}} {
		dict set rec $fname [cparse::ident $kid]
	    } elseif {$kid ne ""} {
		dict set rec hook.$fname [cparse::words $kid]
	    }
	}
	dict set out [dict get $d name] $rec
    }
    return $out
}

proc ::tkx::extract::TkCmds {u} {
    set rel [dict get $u rel]
    set out {}
    foreach d [DeclsOfType $u TkCmd] {
	lassign [StructArray $u $d TkCmd] rows fields
	lassign $fields fName fProc fFlags
	foreach row $rows {
	    set ne [dict get $row $fName]
	    if {[cparse::isNull $ne]} break
	    set proc [cparse::words [dict get $row $fProc]]
	    # Drop casts such as (Tcl_ObjCmdProc2 *)(void *)TkInitTkCmd.
	    set func [lindex $proc end]
	    lappend out [dict create command [cparse::strValue $ne $rel] \
		    func $func flags [cparse::words [dict get $row $fFlags]] \
		    src "$rel:[dict get $row line]"]
	}
    }
    return $out
}

# RegisterWidget(interp, "name", &Spec) calls inside function bodies.
proc ::tkx::extract::Registrations {u} {
    set rel [dict get $u rel]
    set toks [dict get $u toks]
    set out {}
    set n [llength $toks]
    for {set i 0} {$i < $n} {incr i} {
	if {[lindex $toks $i 1] ne "RegisterWidget" || [lindex $toks $i 0] ne "id"} continue
	if {[lindex $toks $i+1 1] ne "("} continue
	set close [cparse::match $toks [expr {$i+1}]]
	set args [lrange $toks $i+2 $close-1]
	set words {}
	foreach t $args { lappend words [lindex $t 1] }
	if {[llength $words] != 6 || [lindex $words 1] ne "," || [lindex $words 3] ne ","
		|| [lindex $words 4] ne "&" || [lindex $args 2 0] ne "str"} {
	    Fail "$rel:[lindex $toks $i 2]" "unsupported RegisterWidget call: $words"
	}
	lappend out [dict create command [clex::strvalue [lindex $words 2]] \
		spec [lindex $words 5] src "$rel:[lindex $toks $i 2]"]
	set i $close
    }
    return $out
}

# tkConfig.c: "case TK_OPTION_<T>:" ... first Tcl_GetIndexFromObj*(.., tbl, ..)
proc ::tkx::extract::BuiltinEnumBindings {u} {
    set rel [dict get $u rel]
    set toks [dict get $u toks]
    set out [dict create]
    set n [llength $toks]
    foreach type $::tkx::config::builtinEnumTypes {
	set found ""
	for {set i 0} {$i < $n} {incr i} {
	    if {[lindex $toks $i 1] eq "case" && [lindex $toks $i+1 1] eq "TK_OPTION_$type"
		    && [lindex $toks $i+2 1] eq ":"} {
		for {set j [expr {$i+3}]} {$j < $n} {incr j} {
		    set x [lindex $toks $j 1]
		    if {$x eq "case"} break
		    if {$x in {Tcl_GetIndexFromObj Tcl_GetIndexFromObjStruct}
			    && [lindex $toks $j+1 1] eq "("} {
			set close [cparse::match $toks [expr {$j+1}]]
			set args [SplitArgs [lrange $toks $j+2 $close-1]]
			set found [lindex $args 2 0 1]
			set line [lindex $toks $j 2]
			break
		    }
		}
		if {$found ne ""} break
	    }
	}
	if {$found eq ""} {
	    Fail $rel "cannot find the string table for built-in option type $type"
	}
	dict set out $type [dict create table $found src "$rel:$line"]
    }
    return $out
}

proc ::tkx::extract::SplitArgs {toks} {
    set args {}
    set cur {}
    set depth 0
    foreach t $toks {
	set x [lindex $t 1]
	if {$x in {( \[ \{}} { incr depth }
	if {$x in {) \] \}}} { incr depth -1 }
	if {$x eq "," && $depth == 0} { lappend args $cur; set cur {}; continue }
	lappend cur $t
    }
    if {[llength $cur] || [llength $args]} { lappend args $cur }
    return $args
}

# ---------------------------------------------------------------------
# Per-platform scan of all files, then cross-platform merge
# ---------------------------------------------------------------------

proc ::tkx::extract::DiscoverTtkFiles {} {
    variable tkRoot
    set files {}
    foreach path [lsort [glob -directory $tkRoot $::tkx::config::ttkGlob]] {
	set rel [string range $path [string length $tkRoot]+1 end]
	set has 0
	foreach t [clex::lexfile $path $rel] {
	    if {[lindex $t 0] eq "id" && [lindex $t 1] eq "RegisterWidget"} { set has 1; break }
	}
	if {$has || $rel in $::tkx::config::ttkSupport} { lappend files $rel }
    }
    return $files
}

proc ::tkx::extract::ScanPlatform {plat files} {
    set R [dict create stringTables {} optionTables {} ensembles {} \
	    widgetSpecs {} registrations {} tkcmds {} enums {}]
    foreach rel $files {
	set u [Unit $plat $rel]
	dict for {k v} [StringTables $u] {
	    dict set R stringTables [list $rel {*}$k] $v
	}
	dict for {k v} [OptionTables $u] { dict set R optionTables [list $rel $k] $v }
	dict for {k v} [Ensembles $u] { dict set R ensembles [list $rel $k] $v }
	dict for {k v} [WidgetSpecs $u] { dict set R widgetSpecs [list $rel $k] $v }
	foreach r [Registrations $u] { dict lappend R registrations $r }
	foreach c [TkCmds $u] { dict lappend R tkcmds $c }
	foreach e [Enums $u] { dict lappend R enums [dict merge $e [dict create file $rel]] }
	if {$rel eq "generic/tkConfig.c"} {
	    dict set R builtinEnums [BuiltinEnumBindings $u]
	}
    }
    return $R
}

# Merge per-platform results.  Identical records collapse to one; records
# that differ keep a per-platform map and are reported.
proc ::tkx::extract::MergeValue {byPlat what} {
    set vals [lsort -unique [dict values $byPlat]]
    if {[llength $vals] == 1} { return [lindex $vals 0] }
    return [dict create platformDependent 1 values $byPlat]
}

proc ::tkx::extract::MergeOptionTables {perPlat} {
    set plats [dict keys $perPlat]
    set keys {}
    foreach p $plats { lappend keys {*}[dict keys [dict get $perPlat $p optionTables]] }
    set out [dict create]
    foreach k [lsort -unique $keys] {
	set present {}
	foreach p $plats {
	    if {[dict exists $perPlat $p optionTables $k]} { lappend present $p }
	}
	set base [dict get $perPlat [lindex $present 0] optionTables $k]
	if {[llength $present] != [llength $plats]} {
	    Diag warning [dict get $base src] "option table [lindex $k 1] exists only on: $present"
	}
	# Entries are merged by option name, preserving table order.
	set order {}
	foreach p $present {
	    foreach e [dict get $perPlat $p optionTables $k entries] {
		set nm [dict get $e optionName]
		if {$nm ni $order} { lappend order $nm }
	    }
	}
	set entries {}
	foreach nm $order {
	    set byPlat [dict create]
	    foreach p $present {
		foreach e [dict get $perPlat $p optionTables $k entries] {
		    if {[dict get $e optionName] eq $nm} { dict set byPlat $p $e }
		}
	    }
	    set merged [dict get $byPlat [lindex [dict keys $byPlat] 0]]
	    dict set merged platforms [dict keys $byPlat]
	    foreach fld [lsort -unique [concat {*}[lmap e [dict values $byPlat] {dict keys $e}]]] {
		set fv [dict create]
		foreach {p e} $byPlat {
		    dict set fv $p [expr {[dict exists $e $fld] ? [dict get $e $fld] : ""}]
		}
		if {[llength [lsort -unique [dict values $fv]]] > 1} {
		    if {$fld in {default defaultMacroSrc hasDefault monoDefault}} {
			dict set merged $fld [dict create platformDependent 1 values $fv]
		    } elseif {$fld eq "line"} {
			dict set merged line [dict get $fv [lindex $present 0]]
		    } else {
			Diag warning "[lindex $k 0]:[dict get $merged line]" \
				"option $nm field $fld differs between platforms: $fv"
			dict set merged $fld [dict create platformDependent 1 values $fv]
		    }
		}
	    }
	    if {[llength [dict keys $byPlat]] != [llength $plats]} {
		Diag warning "[lindex $k 0]:[dict get $merged line]" \
			"option $nm present only on: [dict keys $byPlat]"
	    }
	    lappend entries $merged
	}
	dict set base entries $entries
	dict set base platforms $present
	dict set out $k $base
    }
    return $out
}

proc ::tkx::extract::MergeSimple {perPlat key} {
    set plats [dict keys $perPlat]
    set keys {}
    foreach p $plats { lappend keys {*}[dict keys [dict get $perPlat $p $key]] }
    set out [dict create]
    foreach k [lsort -unique $keys] {
	set byPlat [dict create]
	foreach p $plats {
	    if {[dict exists $perPlat $p $key $k]} {
		dict set byPlat $p [dict get $perPlat $p $key $k]
	    }
	}
	set vals [lsort -unique [dict values $byPlat]]
	set v [lindex $vals 0]
	if {[llength $vals] > 1} {
	    Diag warning [dict get $v src] "$key [lindex $k end] differs between platforms"
	    set v [dict create platformDependent 1 values $byPlat src [dict get $v src]]
	}
	dict set v platforms [dict keys $byPlat]
	dict set out $k $v
    }
    return $out
}

proc ::tkx::extract::MergeList {perPlat key} {
    set plats [dict keys $perPlat]
    set all {}
    foreach p $plats {
	foreach r [dict get $perPlat $p $key] { dict lappend all $r $p }
    }
    set out {}
    dict for {r ps} $all {
	if {[llength $ps] != [llength $plats]} {
	    Diag warning [dict get $r src] "$key entry present only on: $ps"
	}
	lappend out [dict merge $r [dict create platforms $ps]]
    }
    return $out
}

# ---------------------------------------------------------------------
# Source identity
# ---------------------------------------------------------------------

proc ::tkx::extract::Identity {} {
    variable tkRoot
    variable tclRoot
    set out [dict create]
    foreach {what root hdr macro} [list tk $tkRoot generic/tk.h TK_PATCH_LEVEL \
	    tcl $tclRoot generic/tcl.h TCL_PATCH_LEVEL] {
	set level ""
	foreach t [clex::lexfile [file join $root $hdr]] {
	    if {[lindex $t 0] eq "pp" && [lindex $t 1] eq "define"
		    && [lindex $t 3 0 1] eq $macro} {
		set level [clex::strvalue [lindex $t 3 1 1]]
	    }
	}
	set uuid ""
	if {[file exists [file join $root manifest.uuid]]} {
	    set f [open [file join $root manifest.uuid]]
	    set uuid [string trim [read $f]]
	    close $f
	}
	dict set out $what [dict create patchLevel $level manifest $uuid]
    }
    return $out
}

# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------

proc ::tkx::extract::run {tk tcl} {
    variable tkRoot [file normalize $tk]
    variable tclRoot [file normalize $tcl]
    variable diags {}
    variable units
    array unset units
    set files [concat [DiscoverTtkFiles] $::tkx::config::classicFiles]
    set perPlat [dict create]
    foreach plat [Platforms] {
	dict set perPlat $plat [ScanPlatform $plat $files]
    }
    set ir [dict create]
    dict set ir source [Identity]
    dict set ir platforms [Platforms]
    dict set ir files $files
    dict set ir optionTables [MergeOptionTables $perPlat]
    foreach key {stringTables ensembles widgetSpecs} {
	dict set ir $key [MergeSimple $perPlat $key]
    }
    foreach key {registrations tkcmds} {
	dict set ir $key [MergeList $perPlat $key]
    }
    set be [dict create]
    foreach p [Platforms] {
	dict set be $p [dict get $perPlat $p builtinEnums]
    }
    dict set ir builtinEnums [MergeValue $be builtinEnums]
    dict set ir enums [MergeEnums $perPlat]
    # Tier B evidence and resolution live in resolve.tcl.
    variable here
    source [file join $here resolve.tcl]
    set ir [::tkx::resolve::run $ir]
    dict set ir diagnostics [lsort -unique $diags]
    return $ir
}

proc ::tkx::extract::MergeEnums {perPlat} {
    set all [dict create]
    dict for {p R} $perPlat {
	foreach e [dict get $R enums] {
	    dict lappend all $e $p
	}
    }
    set out {}
    dict for {e ps} $all { lappend out [dict merge $e [dict create platforms $ps]] }
    return $out
}

# Access to units for Tier B analysis (unix configuration is the
# reference for function bodies; bodies are compared across platforms
# by resolve.tcl when it matters).
proc ::tkx::extract::unit {plat rel} { Unit $plat $rel }
proc ::tkx::extract::diag {level where msg} { Diag $level $where $msg }
proc ::tkx::extract::fail {where msg} { Fail $where $msg }

if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    array set opt {--tk-src "" --tcl-src "" --out ""}
    array set opt $argv
    set ir [::tkx::extract::run $opt(--tk-src) $opt(--tcl-src)]
    if {$opt(--out) ne ""} {
	set f [open $opt(--out) w]
	fconfigure $f -encoding utf-8 -translation lf
	puts $f $ir
	close $f
    } else {
	puts $ir
    }
}
