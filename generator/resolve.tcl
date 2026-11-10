# resolve.tcl --
#
#	Second extraction stage: turns the declarative records from
#	extract.tcl into resolved widget classes and adds Tier B evidence
#	gathered from function bodies.
#
#	  * ttk classes: RegisterWidget -> WidgetSpec -> option table chain
#	    and Ttk_Ensemble tree (all extracted).
#	  * classic frame family: bound through schema/overrides.tcl
#	    'classic' entries, each verified against the sources.
#	  * enumerations: STRING_TABLE options and the built-in RELIEF /
#	    JUSTIFY / ANCHOR types are resolved to their string tables.
#	  * subcommand evidence: usage strings, arity guards, argument
#	    conversions and result constructors (constrained patterns).
#	  * geometry managers: subcommand tables, per-subcommand handlers,
#	    option tables and option value conversions.

namespace eval ::tkx::resolve {
    variable ir
    variable here [file dirname [file normalize [info script]]]
    variable funcIndex	;# array: funcName -> {rel}
    variable evCache	;# array: funcName -> evidence
}

proc ::tkx::resolve::Diag {l w m} { ::tkx::extract::diag $l $w $m }
proc ::tkx::resolve::Fail {w m} { ::tkx::extract::fail $w $m }

# Reference platform for function-body analysis.  Bodies are compared
# with the other platforms; differences are reported.
proc ::tkx::resolve::RefUnit {rel} { ::tkx::extract::unit unix $rel }

proc ::tkx::resolve::run {irIn} {
    variable ir $irIn
    variable evCache
    array unset evCache
    variable here
    namespace eval ::tkx::schema {}
    source [file join $here .. schema overrides.tcl]
    IndexFunctions
    dict set ir enumTypes [ResolveBuiltinEnums]
    set classes [dict create]
    foreach r [dict get $ir registrations] {
	set c [TtkClass $r]
	dict set classes [dict get $c command] $c
    }
    dict for {cmd spec} $::tkx::schema::classic {
	dict set classes $cmd [ClassicClass $cmd $spec]
    }
    dict set ir classes $classes
    set geo [dict create]
    foreach mgr {grid pack} {
	dict set geo $mgr [GeometryManager $mgr]
    }
    dict set ir geometry $geo
    set subs [dict create]
    dict for {key spec} $::tkx::schema::subobjects {
	dict set subs $key [SubObject $key $spec]
    }
    dict set ir subobjects $subs
    return $ir
}

# Sub-object option table bound by an overlay entry, with verification.
proc ::tkx::resolve::SubObject {key spec} {
    variable ir
    lassign $key cmd sub
    set cls [dict get $ir classes $cmd]
    set rel [lindex [split [dict get $cls registeredAt] :] 0]
    set u [RefUnit $rel]
    set table [dict get $spec table]
    set field [dict get $spec field]
    # Tk_CreateOptionTable(interp, TABLE) stored into ...field
    set toks [dict get $u toks]
    set n [llength $toks]
    set ok 0
    for {set i 0} {$i < $n} {incr i} {
	if {[lindex $toks $i 1] eq "Tk_CreateOptionTable"} {
	    set close [cparse::match $toks [expr {$i+1}]]
	    set args [::tkx::extract::SplitArgs [lrange $toks $i+2 $close-1]]
	    if {[Words [lindex $args 1]] eq $table && [lindex $toks $i-1 1] eq "="
		    && [lindex $toks $i-2 1] eq $field} {
		set ok 1
		set createLine [lindex $toks $i 2]
	    }
	}
    }
    if {!$ok} { Fail $rel "overlay drift: no 'X.$field = Tk_CreateOptionTable(interp, $table)'" }
    # The subcommand's handler delegates to the configure function.
    set entry ""
    foreach c [dict get $cls commands] {
	if {[dict get $c path] eq [list $sub]} { set entry $c }
    }
    if {$entry eq ""} { Fail $rel "overlay drift: $cmd has no subcommand '$sub'" }
    set ev [dict get $entry evidence]
    set callees [expr {[dict exists $ev result callees] ? [dict get $ev result callees] :
	[expr {[dict exists $ev result delegated] ? [dict get $ev result delegated] : {}}]}]
    if {[dict get $spec configure] ni $callees} {
	Fail $rel "overlay drift: $cmd $sub does not delegate to [dict get $spec configure] ($callees)"
    }
    set cbody [FuncBody $u [dict get $spec configure]]
    if {$field ni [Words $cbody]} {
	Fail $rel "overlay drift: [dict get $spec configure] does not use $field"
    }
    lassign [FlattenOptions $rel $table 0] options
    return [dict create command $cmd subcommand $sub table $table \
	    key [dict get $spec key] options $options \
	    evidence "$rel:$createLine" handler [dict get $entry func]]
}

# ---------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------

proc ::tkx::resolve::IndexFunctions {} {
    variable ir
    variable funcIndex
    array unset funcIndex
    foreach rel [dict get $ir files] {
	set u [RefUnit $rel]
	foreach f [dict keys [dict get $u idx funcs]] {
	    lappend funcIndex($f) $rel
	}
    }
}

proc ::tkx::resolve::FuncUnit {name {preferRel ""}} {
    variable funcIndex
    if {![info exists funcIndex($name)]} { return "" }
    if {$preferRel ne "" && $preferRel in $funcIndex($name)} { return $preferRel }
    if {[llength $funcIndex($name)] > 1} {
	Fail $name "function $name defined in several scanned files: $funcIndex($name)"
    }
    return [lindex $funcIndex($name) 0]
}

# Find a table record by name: same file first, then any file scope table.
proc ::tkx::resolve::FindTable {kind name rel {scope ""}} {
    variable ir
    set tables [dict get $ir $kind]
    if {$kind eq "stringTables"} {
	if {[dict exists $tables [list $rel $scope $name]]} {
	    return [dict get $tables [list $rel $scope $name]]
	}
	if {[dict exists $tables [list $rel {} $name]]} {
	    return [dict get $tables [list $rel {} $name]]
	}
	set hits {}
	dict for {k v} $tables {
	    if {[lindex $k 2] eq $name && [lindex $k 1] eq ""} { lappend hits $v }
	}
    } else {
	if {[dict exists $tables [list $rel $name]]} {
	    return [dict get $tables [list $rel $name]]
	}
	set hits {}
	dict for {k v} $tables {
	    if {[lindex $k 1] eq $name} { lappend hits $v }
	}
    }
    if {[llength $hits] == 1} { return [lindex $hits 0] }
    if {[llength $hits] == 0} { Fail $rel "$kind entry '$name' not found" }
    Fail $rel "$kind entry '$name' is ambiguous"
}

proc ::tkx::resolve::ResolveBuiltinEnums {} {
    variable ir
    set out [dict create]
    set be [dict get $ir builtinEnums]
    if {[dict exists $be platformDependent]} {
	Fail generic/tkConfig.c "built-in enum bindings differ between platforms"
    }
    dict for {type b} $be {
	set rel [lindex [split [dict get $b src] :] 0]
	set tbl [FindTable stringTables [dict get $b table] $rel]
	dict set out $type [dict create table [dict get $b table] \
		values [dict get $tbl values] src [dict get $tbl src] \
		bindingSrc [dict get $b src]]
    }
    return $out
}

# ---------------------------------------------------------------------
# Option chains
# ---------------------------------------------------------------------

# Flatten an option table chain using Tk's lookup rule (tkConfig.c
# GetOption): the first table in the chain that defines a name wins.
proc ::tkx::resolve::FlattenOptions {rel tableName {classIsTtk 0}} {
    variable ir
    set seen [dict create]
    set out {}
    set via {}
    set visited {}
    while {$tableName ne ""} {
	if {$tableName in $visited} { Fail $rel "option table cycle at $tableName" }
	lappend visited $tableName
	set t [FindTable optionTables $tableName $rel]
	set trel [lindex [split [dict get $t src] :] 0]
	if {[llength [dict get $t conds]]} {
	    Diag warning [dict get $t src] "option table $tableName depends on build configuration: [dict get $t conds]"
	}
	foreach e [dict get $t entries] {
	    set nm [dict get $e optionName]
	    if {[dict exists $seen $nm]} {
		Diag note "$trel:[dict get $e line]" "option $nm shadowed by [dict get $seen $nm] (Tk uses the first definition)"
		continue
	    }
	    dict set seen $nm "$tableName"
	    dict set e table $tableName
	    dict set e src "$trel:[dict get $e line]"
	    dict set e inherited [expr {[llength $visited] > 1}]
	    dict set e readonly 0
	    if {$classIsTtk} {
		set ro [expr {[dict get $e typeMask] & [ReadonlyBit $trel]}]
		dict set e readonly [expr {$ro != 0}]
	    }
	    set e [ResolveEnumValues $e $trel]
	    lappend out $e
	}
	set tableName [dict get $t chain]
	set rel $trel
    }
    return [list $out $visited]
}

proc ::tkx::resolve::ReadonlyBit {rel} {
    set u [RefUnit $rel]
    set d [cpp::lookupIn [dict get $u macros] READONLY_OPTION end]
    if {$d eq {}} { Fail $rel "READONLY_OPTION is not defined" }
    set v [::tkx::extract::IntValue $u [list e [dict get $d body] 0] $rel]
    return $v
}

proc ::tkx::resolve::ResolveEnumValues {e rel} {
    variable ir
    set type [dict get $e type]
    if {$type eq "STRING_TABLE"} {
	set tbl [FindTable stringTables [dict get $e stringTable] $rel]
	dict set e enumValues [dict get $tbl values]
	dict set e enumSrc [dict get $tbl src]
    } elseif {[dict exists $ir enumTypes $type]} {
	dict set e enumValues [dict get $ir enumTypes $type values]
	dict set e enumSrc [dict get $ir enumTypes $type src]
	dict set e stringTable [dict get $ir enumTypes $type table]
    }
    return $e
}

# ---------------------------------------------------------------------
# ttk classes
# ---------------------------------------------------------------------

proc ::tkx::resolve::TtkClass {reg} {
    variable ir
    set rel [lindex [split [dict get $reg src] :] 0]
    set spec [FindTable widgetSpecs [dict get $reg spec] $rel]
    lassign [FlattenOptions $rel [dict get $spec optionSpecs] 1] options chain
    set commands [FlattenEnsemble $rel [dict get $spec commands] {}]
    return [dict create command [dict get $reg command] kind ttk \
	    className [dict get $spec className] \
	    registeredAt [dict get $reg src] widgetSpec [dict get $spec name] \
	    widgetSpecSrc [dict get $spec src] optionChain $chain \
	    options $options commands $commands binding extracted]
}

proc ::tkx::resolve::FlattenEnsemble {rel name prefix} {
    set ens [FindTable ensembles $name $rel]
    set erel [lindex [split [dict get $ens src] :] 0]
    set out {}
    foreach e [dict get $ens entries] {
	set path [list {*}$prefix [dict get $e name]]
	if {[dict exists $e ensemble]} {
	    lappend out {*}[FlattenEnsemble $erel [dict get $e ensemble] $path]
	    continue
	}
	set func [dict get $e func]
	set rec [dict create path $path func $func src "$erel:[dict get $e line]"]
	dict set rec evidence [CommandEvidence $func $erel [expr {[llength $path] + 1}]]
	lappend out $rec
    }
    return $out
}

# ---------------------------------------------------------------------
# Classic frame family (overlay-bound, verified)
# ---------------------------------------------------------------------

proc ::tkx::resolve::ClassicClass {cmd spec} {
    variable ir
    set rel [dict get $spec file]
    set u [RefUnit $rel]
    # 1. TkCmd table maps the command to the creator.
    set creator ""
    foreach c [dict get $ir tkcmds] {
	if {[dict get $c command] eq $cmd} {
	    set creator [dict get $c func]
	    set tkcmdSrc [dict get $c src]
	}
    }
    if {$creator ne [dict get $spec creator]} {
	Fail $rel "overlay drift: command '$cmd' is registered with '$creator', overlay says '[dict get $spec creator]'"
    }
    # 2. The creator body references the enum member.
    lassign [dict get $spec dispatch] - arrayName - enumName - member
    set body [FuncBody $u $creator]
    set ids {}
    set enumMembers [EnumMembers $u $enumName]
    foreach t $body {
	if {[lindex $t 0] eq "id" && [lindex $t 1] in $enumMembers} { lappend ids [lindex $t 1] }
    }
    if {[lsort -unique $ids] ne [list $member]} {
	Fail $rel "overlay drift: $creator references enum members '$ids', overlay expects $member"
    }
    set ordinal [lsearch -exact $enumMembers $member]
    # 3. Dispatch array element at that ordinal.
    set tableName [ArrayElement $u $arrayName $ordinal]
    set className [ArrayElement $u [dict get $spec classNames] $ordinal str]
    lassign [FlattenOptions $rel $tableName 0] options chain
    # 4. Create-only options: string literals in the widget command.
    set wbody [FuncBody $u [dict get $spec widgetCmd]]
    set lits {}
    foreach t $wbody {
	if {[lindex $t 0] eq "str"} { lappend lits [clex::strvalue [lindex $t 1]] }
    }
    set names {}
    foreach o $options { lappend names [dict get $o optionName] }
    foreach co [dict get $spec createOnly] {
	if {$co ni $lits} {
	    Fail $rel "overlay drift: create-only option $co not found in [dict get $spec widgetCmd]"
	}
	if {$co ni $names} {
	    Fail $rel "overlay drift: create-only option $co is not an option of $cmd"
	}
    }
    set out {}
    foreach o $options {
	dict set o createOnly [expr {[dict get $o optionName] in [dict get $spec createOnly]}]
	lappend out $o
    }
    # Subcommands: the string table the widget command matches objv[1] against.
    set sub [IndexTableFor $u [dict get $spec widgetCmd] {objv [ 1 ]}]
    set commands {}
    foreach s [dict get $sub values] {
	lappend commands [dict create path [list $s] func [dict get $spec widgetCmd] \
		src [dict get $sub src] evidence {}]
    }
    return [dict create command $cmd kind classic className $className \
	    registeredAt $tkcmdSrc creator $creator optionTable $tableName \
	    optionChain $chain options $out commands $commands \
	    binding [dict create overlay classic dispatch [dict get $spec dispatch] \
		verified 1]]
}

proc ::tkx::resolve::FuncBody {u name} {
    set funcs [dict get $u idx funcs]
    if {![dict exists $funcs $name]} { Fail [dict get $u rel] "function $name not found" }
    set f [dict get $funcs $name]
    return [lrange [dict get $u toks] [dict get $f bodyStart] [dict get $f bodyEnd]]
}

proc ::tkx::resolve::EnumMembers {u name} {
    foreach e [dict get $u idx enums] {
	if {[dict get $e tag] eq $name || [dict get $e typedef] eq $name} {
	    set out {}
	    foreach m [dict get $e members] {
		if {[llength [dict get $m value]]} {
		    Fail [dict get $u rel] "enum $name has explicit values; ordinal mapping unsupported"
		}
		lappend out [dict get $m name]
	    }
	    return $out
	}
    }
    Fail [dict get $u rel] "enum $name not found"
}

proc ::tkx::resolve::ArrayElement {u name ordinal {kind ident}} {
    foreach d [dict get $u idx decls] {
	if {[dict get $d name] ne $name || [dict get $d scope] ne ""} continue
	lassign [::tkx::extract::InitTree $u $d] tree
	set el [lindex $tree 1 $ordinal]
	if {$el eq ""} { Fail [dict get $u rel] "$name has no element $ordinal" }
	if {$kind eq "str"} { return [cparse::strValue $el [dict get $u rel]] }
	set id [cparse::ident $el]
	if {$id eq ""} { Fail [dict get $u rel] "$name\[$ordinal\] is not an identifier" }
	return $id
    }
    Fail [dict get $u rel] "array $name not found"
}

# The local string table passed to Tcl_GetIndexFromObj[Struct] together
# with the given objv expression (as a word list) inside function fname.
# If several tables are used with the same argument (grid/pack keep a
# copy without deprecated names), the largest is returned and the
# others are reported in 'variants'.
proc ::tkx::resolve::IndexTableFor {u fname argWords} {
    variable ir
    set body [FuncBody $u $fname]
    set rel [dict get $u rel]
    set found {}
    set n [llength $body]
    for {set i 0} {$i < $n} {incr i} {
	set x [lindex $body $i 1]
	if {$x ni {Tcl_GetIndexFromObj Tcl_GetIndexFromObjStruct}} continue
	if {[lindex $body $i+1 1] ne "("} continue
	set close [cparse::match $body [expr {$i+1}]]
	set args [::tkx::extract::SplitArgs [lrange $body $i+2 $close-1]]
	set a1 {}
	foreach t [lindex $args 1] { lappend a1 [lindex $t 1] }
	if {[join $a1 " "] eq [join $argWords " "]} {
	    set tn [lindex $args 2 0 1]
	    if {$tn ni $found} { lappend found $tn }
	}
	set i $close
    }
    if {![llength $found]} {
	Fail $rel "$fname: no Tcl_GetIndexFromObj call on [join $argWords {}]"
    }
    set tables {}
    foreach tn $found { lappend tables [FindTable stringTables $tn $rel $fname] }
    set tables [lsort -command {apply {{a b} {
	expr {[llength [dict get $b values]] - [llength [dict get $a values]]}}}} $tables]
    set main [lindex $tables 0]
    set variants {}
    foreach t [lrange $tables 1 end] {
	foreach v [dict get $t values] {
	    if {$v ni [dict get $main values]} {
		Fail $rel "$fname: index tables [dict get $main name] and [dict get $t name] are not nested"
	    }
	}
	lappend variants [dict get $t name] [dict get $t values]
    }
    dict set main variants $variants
    return $main
}

# ---------------------------------------------------------------------
# Tier B: subcommand evidence
# ---------------------------------------------------------------------

proc ::tkx::resolve::Words {toks} {
    set w {}
    foreach t $toks { lappend w [lindex $t 1] }
    return $w
}

# Callee chain around token index i (innermost first).
proc ::tkx::resolve::CallChain {body i} {
    set chain {}
    set pos $i
    while 1 {
	set depth 0
	set open -1
	for {set k [expr {$pos-1}]} {$k >= 0} {incr k -1} {
	    set x [lindex $body $k 1]
	    if {$x eq ")"} { incr depth }
	    if {$x eq "("} {
		if {$depth == 0} { set open $k; break }
		incr depth -1
	    }
	    if {$x in {; \{ \}}} break
	}
	if {$open < 0} break
	set callee [lindex $body $open-1]
	if {[lindex $callee 0] ne "id" || [lindex $callee 1] in {if while for switch return sizeof}} break
	# Argument position of pos inside this call.
	set argIdx 0
	set d 0
	for {set k [expr {$open+1}]} {$k < $pos} {incr k} {
	    set x [lindex $body $k 1]
	    if {$x in {( \[}} { incr d }
	    if {$x in {) \]}} { incr d -1 }
	    if {$x eq "," && $d == 0} { incr argIdx }
	}
	set close [cparse::match $body $open]
	lappend chain [list [lindex $callee 1] $argIdx $open $close]
	set pos [expr {$open-1}]
    }
    return $chain
}

# Semantic type for a callee chain (outermost known converter wins).
proc ::tkx::resolve::ConvType {body chain rel scope} {
    set conv $::tkx::config::conversions
    foreach c [lreverse $chain] {
	lassign $c fn argIdx open close
	# Position-specific entries (fn@argIndex) take precedence.
	if {[dict exists $conv $fn@$argIdx]} {
	    set t [dict get $conv $fn@$argIdx]
	} elseif {[dict exists $conv $fn]} {
	    set t [dict get $conv $fn]
	} else continue
	if {[string match enum@* $t]} {
	    set ai [string range $t 5 end]
	    set args [::tkx::extract::SplitArgs [lrange $body $open+1 $close-1]]
	    set tn [lindex $args $ai 0 1]
	    set tbl [FindTable stringTables $tn $rel $scope]
	    return [dict create type enum conv $fn table $tn values [dict get $tbl values] \
		    tableSrc [dict get $tbl src]]
	}
	return [dict create type $t conv $fn]
    }
    if {[llength $chain]} {
	return [dict create type unknown conv [lindex $chain 0 0]]
    }
    return [dict create type unknown conv ""]
}

# Conversion of an argument expression (a word list such as {objv [ 3 ]})
# considering *every* occurrence in the range [from, to): occurrences
# that only format an error message are ignored; if the remaining ones
# disagree, the argument is polymorphic (e.g. treeview move probes an
# argument as before|after and otherwise as an item) and its type is
# reported as unknown instead of picking one.
proc ::tkx::resolve::ArgConversion {body from to words rel func} {
    set types {}
    set first ""
    set m [llength $words]
    for {set i $from} {$i < $to} {incr i} {
	if {[join [Words [lrange $body $i [expr {$i+$m-1}]]] " "] ne [join $words " "]} continue
	set chain [CallChain $body $i]
	set fns {}
	foreach c $chain { lappend fns [lindex $c 0] }
	set errorFmt 0
	foreach fn $fns {
	    if {$fn in {Tcl_ObjPrintf Tcl_AppendResult Tcl_SetErrorCode Tcl_AppendStringsToObj
		Tcl_AppendObjToErrorInfo Tcl_SetObjResult Tcl_AppendPrintfToObj}} { set errorFmt 1 }
	}
	if {$errorFmt} continue
	set ct [ConvType $body $chain $rel $func]
	if {$first eq ""} { set first $ct }
	set key [list [dict get $ct type] [expr {[dict exists $ct table] ? [dict get $ct table] : ""}]]
	if {$key ni $types} { lappend types $key }
    }
    if {$first eq ""} {
	return [dict create type unknown conv "" note "only used in error messages"]
    }
    if {[llength $types] > 1} {
	return [dict create type unknown conv [dict get $first conv] \
		note "polymorphic argument (converted as: [join [lmap t $types {lindex $t 0}] {, }])"]
    }
    return $first
}

# Evaluate a guard condition over objc (other identifiers -> unknown).
proc ::tkx::resolve::GuardRejects {cond objcVal} {
    set e ""
    foreach t $cond {
	lassign $t kind x
	if {$kind eq "id"} {
	    if {$x ne "objc"} { return "?" }
	    append e " $objcVal"
	} elseif {$kind eq "num"} {
	    if {![string is integer -strict $x]} { return "?" }
	    append e " $x"
	} elseif {$x in {( ) < > <= >= == != && || ! + - % *}} {
	    append e " $x"
	} else { return "?" }
    }
    if {[catch {expr $e} v]} { return "?" }
    return [expr {$v ? 1 : 0}]
}

proc ::tkx::resolve::CommandEvidence {func preferRel lead} {
    variable evCache
    if {[info exists evCache($func)]} { return $evCache($func) }
    set rel [FuncUnit $func $preferRel]
    if {$rel eq ""} {
	set evCache($func) [dict create status unresolved reasons [list "function $func not found in scanned files"]]
	return $evCache($func)
    }
    set u [RefUnit $rel]
    set body [FuncBody $u $func]
    set fsrc "$rel:[dict get $u idx funcs $func line]"
    set reasons {}
    set n [llength $body]
    # --- usage strings and guards
    set usages {}
    set rejectSets {}
    set arityKnown 1
    for {set i 0} {$i < $n} {incr i} {
	if {[lindex $body $i 1] ne "Tcl_WrongNumArgs" || [lindex $body $i+1 1] ne "("} continue
	set close [cparse::match $body [expr {$i+1}]]
	set args [::tkx::extract::SplitArgs [lrange $body $i+2 $close-1]]
	set k [Words [lindex $args 1]]
	set uw [lindex $args 3]
	set usage [expr {[lindex $uw 0 0] eq "str" ? [clex::strvalue [lindex $uw 0 1]] : ""}]
	lappend usages [dict create lead $k usage $usage line [lindex $body $i 2]]
	# The enclosing "if (COND)" block is the guard.
	set depth 0
	set ob -1
	for {set j [expr {$i-1}]} {$j >= 0} {incr j -1} {
	    set x [lindex $body $j 1]
	    if {$x eq "\}"} { incr depth }
	    if {$x eq "\{"} { if {$depth == 0} { set ob $j; break }; incr depth -1 }
	}
	if {$ob > 0 && [lindex $body $ob-1 1] eq ")"} {
	    set d 0
	    for {set j [expr {$ob-1}]} {$j >= 0} {incr j -1} {
		set x [lindex $body $j 1]
		if {$x eq ")"} { incr d }
		if {$x eq "("} { incr d -1; if {$d == 0} break }
	    }
	    if {[lindex $body $j-1 1] eq "if" && [lindex $body $j-2 1] ne "else"} {
		lappend rejectSets [lrange $body $j+1 $ob-2]
		if {![info exists guardStart]} { set guardStart [expr {$j-1}] }
	    } else {
		set arityKnown 0
		lappend reasons "argument-count check is not a simple 'if (objc ...)' guard (line [lindex $body $i 2])"
	    }
	} else {
	    set arityKnown 0
	    lappend reasons "argument-count check is in an else branch (line [lindex $body $i 2])"
	}
	set i $close
    }
    # Arity is counted relative to the ensemble depth ('lead' = number of
    # words before the first argument).  Tcl_WrongNumArgs may use a
    # smaller count when its usage string repeats the subcommand name.
    foreach us $usages {
	set ul [dict get $us lead]
	if {[string is integer -strict $ul] && $ul > $lead} {
	    set arityKnown 0
	    lappend reasons "Tcl_WrongNumArgs lead $ul exceeds ensemble depth $lead"
	}
    }
    set accepted {}
    if {$arityKnown && [llength $rejectSets]} {
	for {set nn $lead} {$nn <= 12} {incr nn} {
	    set rej 0
	    foreach c $rejectSets {
		set r [GuardRejects $c $nn]
		if {$r eq "?"} { set arityKnown 0; set rej 1;
		    lappend reasons "guard depends on values other than objc"; break }
		if {$r} { set rej 1 }
	    }
	    if {!$rej} { lappend accepted $nn }
	}
    } elseif {![llength $rejectSets] && $arityKnown} {
	set arityKnown 0
	lappend reasons "no argument-count guard"
    }
    set arity {}
    if {$arityKnown} {
	if {![llength $accepted]} {
	    set arityKnown 0
	    lappend reasons "guard rejects every argument count"
	} else {
	    set mn [lindex $accepted 0]
	    set mx [lindex $accepted end]
	    if {[llength $accepted] != $mx - $mn + 1} {
		set arityKnown 0
		lappend reasons "accepted argument counts are not contiguous: $accepted"
	    } elseif {$mx == 12} {
		set arityKnown 0
		lappend reasons "variable number of arguments"
	    } else {
		set arity [list [expr {$mn - $lead}] [expr {$mx - $lead}]]
	    }
	}
    }
    # Any objc test *before* the first guard selects another form of the
    # command (e.g. "$w state" vs "$w state spec"): the guard alone does
    # not describe the accepted argument counts.
    if {$arityKnown && [info exists guardStart]} {
	for {set i 0} {$i < $guardStart} {incr i} {
	    set t [lindex $body $i]
	    if {[lindex $t 1] eq "objc" && [lindex $body $i+1 1] in {== != < > <= >=}} {
		set arityKnown 0
		set arity {}
		lappend reasons "several argument-count forms (objc tested at line [lindex $t 2] before the guard)"
		break
	    }
	}
    }
    # --- positional argument conversions
    set argInfo {}
    if {$arityKnown} {
	for {set a 0} {$a < [lindex $arity 1]} {incr a} {
	    set idx [expr {$lead + $a}]
	    set first -1
	    for {set i 0} {$i < $n} {incr i} {
		if {[lindex $body $i 1] eq "objv" && [lindex $body $i+1 1] eq "\["
			&& [lindex $body $i+2 1] eq $idx && [lindex $body $i+3 1] eq "\]"} {
		    set first $i
		    break
		}
	    }
	    if {$first < 0} {
		lappend argInfo [dict create index $a type unknown conv "" \
			note "objv\[$idx\] not referenced directly"]
		lappend reasons "argument $a: objv\[$idx\] not referenced directly"
		continue
	    }
	    set ct [ArgConversion $body $first $n [list objv \[ $idx \]] $rel $func]
	    dict set ct index $a
	    dict set ct line [lindex $body $first 2]
	    if {[dict get $ct type] eq "unknown"} {
		if {[dict exists $ct note]} {
		    lappend reasons "argument $a: [dict get $ct note]"
		} else {
		    lappend reasons "argument $a: no known conversion (passed to '[dict get $ct conv]')"
		}
	    }
	    lappend argInfo $ct
	}
    }
    # --- result
    set results {}
    set delegated {}
    for {set i 0} {$i < $n} {incr i} {
	set x [lindex $body $i 1]
	if {$x eq "Tcl_SetObjResult" && [lindex $body $i+1 1] eq "("} {
	    set close [cparse::match $body [expr {$i+1}]]
	    set args [::tkx::extract::SplitArgs [lrange $body $i+2 $close-1]]
	    set ctor [lindex $args 1 0 1]
	    # A field access ending in a known field (e.g. item->idObj).
	    set aw [Words [lindex $args 1]]
	    if {[llength $aw] >= 3 && [lindex $aw end-1] eq "->"
		    && [dict exists $::tkx::config::resultFields [lindex $aw end]]} {
		set ctor "field:[lindex $aw end]"
	    }
	    # A variable: use the constructor it was assigned from.
	    if {[llength [lindex $args 1]] == 1 && [lindex $args 1 0 0] eq "id"} {
		set assigned {}
		for {set j 0} {$j < $n} {incr j} {
		    if {[lindex $body $j 1] eq $ctor && [lindex $body $j+1 1] eq "="
			    && [lindex $body $j+2 0] eq "id" && [lindex $body $j+3 1] eq "("} {
			lappend assigned [lindex $body $j+2 1]
		    }
		}
		set assigned [lsort -unique $assigned]
		if {[llength $assigned] == 1} { set ctor [lindex $assigned 0] }
	    }
	    # Error path: a 'return TCL_ERROR' before the end of this block.
	    set err 0
	    set depth 0
	    for {set j $close} {$j < $n} {incr j} {
		set y [lindex $body $j 1]
		if {$y eq "\{"} { incr depth }
		if {$y eq "\}"} { if {$depth == 0} break; incr depth -1 }
		if {$y eq "return" && [lindex $body $j+1 1] eq "TCL_ERROR"} { set err 1; break }
		if {$y eq "goto"} { set err 1; break }
	    }
	    if {!$err} {
		lappend results [list $ctor [lindex $body $i 2]]
	    }
	    set i $close
	    continue
	}
	if {$x eq "return"} {
	    set y [lindex $body $i+1]
	    if {[lindex $y 0] eq "id" && [lindex $body $i+2 1] eq "("} {
		lappend delegated [lindex $y 1]
	    }
	}
    }
    set rtypes {}
    foreach r $results {
	set ctor [lindex $r 0]
	if {[string match field:* $ctor]} {
	    lappend rtypes [dict get $::tkx::config::resultFields [string range $ctor 6 end]]
	} elseif {[dict exists $::tkx::config::results $ctor]} {
	    lappend rtypes [dict get $::tkx::config::results $ctor]
	} else {
	    lappend rtypes "?$ctor"
	}
    }
    set rtypes [lsort -unique $rtypes]
    if {[llength $rtypes] == 0 && ![llength $delegated]} {
	set result [dict create kind none]
    } elseif {[llength $rtypes] == 0} {
	set result [dict create kind delegated callees [lsort -unique $delegated]]
	lappend reasons "result delegated to [join [lsort -unique $delegated] {, }]"
    } elseif {[llength $rtypes] == 1 && [string index [lindex $rtypes 0] 0] ne "?"
	    && ![llength $delegated]} {
	set result [dict create kind typed type [lindex $rtypes 0]]
    } else {
	set result [dict create kind unknown constructors $rtypes delegated [lsort -unique $delegated]]
	lappend reasons "result type not determined ($rtypes)"
    }
    # Does any argument reach a function that evaluates it as a script?
    # One level of data flow is followed: "V = f(objv[k])" makes every use
    # of V count too (ttkTreeview.c passes the tag-bind script through a
    # local variable).
    set takesScript 0
    set vars {}
    for {set i 0} {$i < $n} {incr i} {
	if {[lindex $body $i 1] ne "objv" || [lindex $body $i+1 1] ne "\["} continue
	set chain [CallChain $body $i]
	set ct [ConvType $body $chain $rel $func]
	if {[dict get $ct type] eq "script"} {
	    set takesScript 1
	    break
	}
	set start [expr {[llength $chain] ? [lindex $chain end 2] - 1 : $i}]
	if {[lindex $body $start-1 1] eq "=" && [lindex $body $start-2 0] eq "id"} {
	    lappend vars [lindex $body $start-2 1]
	}
    }
    if {!$takesScript} {
	for {set i 0} {$i < $n && !$takesScript} {incr i} {
	    set t [lindex $body $i]
	    if {[lindex $t 0] ne "id" || [lindex $t 1] ni $vars} continue
	    if {[lindex $body $i+1 1] eq "="} continue
	    set ct [ConvType $body [CallChain $body $i] $rel $func]
	    if {[dict get $ct type] eq "script"} { set takesScript 1 }
	}
    }
    set status [expr {[llength $reasons] ? "partial" : "complete"}]
    set ev [dict create func $func src $fsrc usages $usages lead $lead \
	    arity $arity args $argInfo result $result status $status \
	    reasons $reasons takesScript $takesScript]
    set evCache($func) $ev
    return $ev
}

# ---------------------------------------------------------------------
# Tier B: geometry managers
# ---------------------------------------------------------------------

proc ::tkx::resolve::GeometryManager {mgr} {
    variable ir
    set func ""
    foreach c [dict get $ir tkcmds] {
	if {[dict get $c command] eq $mgr} { set func [dict get $c func]; set src [dict get $c src] }
    }
    if {$func eq ""} { Fail generic/tkWindow.c "geometry manager command $mgr not registered" }
    set rel [FuncUnit $func]
    set u [RefUnit $rel]
    set sub [IndexTableFor $u $func {objv [ 1 ]}]
    set deprecated {}
    foreach {vn vals} [dict get $sub variants] {
	foreach v [dict get $sub values] {
	    if {$v ni $vals} { lappend deprecated $v }
	}
    }
    set body [FuncBody $u $func]
    set members [LocalEnumFor $u $func [llength [dict get $sub values]]]
    set subs {}
    foreach name [dict get $sub values] m $members {
	set handler [CaseHandler $body $m]
	set rec [dict create name $name enumMember $m handler $handler \
		deprecated [expr {$name in $deprecated}]]
	# Usage strings: from the handler, or from the inline case block.
	set usages {}
	if {$handler ne ""} {
	    set ev [CommandEvidence $handler $rel 2]
	    if {[dict exists $ev usages]} {
		foreach us [dict get $ev usages] { lappend usages [dict get $us usage] }
	    }
	} else {
	    foreach blk [MemberBlocks $body $m] {
		lassign $blk s e
		for {set i $s} {$i <= $e} {incr i} {
		    if {[lindex $body $i 1] eq "Tcl_WrongNumArgs"} {
			set close [cparse::match $body [expr {$i+1}]]
			set args [::tkx::extract::SplitArgs [lrange $body $i+2 $close-1]]
			set uw [lindex $args 3]
			if {[lindex $uw 0 0] eq "str"} {
			    lappend usages [clex::strvalue [lindex $uw 0 1]]
			}
		    }
		}
	    }
	}
	dict set rec usages [lsort -unique $usages]
	lappend subs $rec
    }
    # Option tables of the configure-style handlers.
    set handlers {}
    foreach s $subs {
	set h [dict get $s handler]
	if {$h eq "" || [dict exists $handlers $h]} continue
	set hrel [FuncUnit $h $rel]
	if {$hrel eq ""} continue
	set hu [RefUnit $hrel]
	if {[catch {IndexTableFor $hu $h {objv [ i ]}} tbl]} continue
	set hmembers [LocalEnumFor $hu $h [llength [dict get $tbl values]]]
	set hbody [FuncBody $hu $h]
	set opts {}
	foreach o [dict get $tbl values] m $hmembers {
	    set ev [OptionValueEvidence $hbody $m $hrel $h]
	    lappend opts [dict merge [dict create name $o enumMember $m] $ev]
	}
	dict set handlers $h [dict create table [dict get $tbl name] \
		src [dict get $tbl src] options $opts]
    }
    # String literals produced by each subcommand (handler body, or the
    # inline case block): tells which options "info" reports.
    foreach i [lsearch -all -exact [lmap s $subs {dict get $s name}] info] {
	set s [lindex $subs $i]
	set lits {}
	if {[dict get $s handler] ne ""} {
	    set hu [RefUnit [FuncUnit [dict get $s handler] $rel]]
	    set toks [FuncBody $hu [dict get $s handler]]
	} else {
	    set toks {}
	    foreach blk [MemberBlocks $body [dict get $s enumMember]] {
		lappend toks {*}[lrange $body {*}$blk]
	    }
	}
	foreach t $toks {
	    if {[lindex $t 0] eq "str"} { lappend lits [clex::strvalue [lindex $t 1]] }
	}
	dict set s literals [lsort -unique $lits]
	lset subs $i $s
    }
    return [dict create command $mgr func $func src $src \
	    subcommandTable [dict get $sub name] subcommandSrc [dict get $sub src] \
	    subcommands $subs handlers $handlers]
}

# Local enum in a function whose member count matches a string table.
proc ::tkx::resolve::LocalEnumFor {u func count} {
    set cands {}
    foreach e [dict get $u idx enums] {
	if {[dict get $e scope] ne $func} continue
	if {[llength [dict get $e members]] == $count} { lappend cands $e }
    }
    if {[llength $cands] != 1} {
	Fail [dict get $u rel] "$func: cannot pair string table with a local enum ([llength $cands] candidates)"
    }
    set out {}
    foreach m [dict get [lindex $cands 0] members] {
	if {[llength [dict get $m value]]} {
	    Fail [dict get $u rel] "$func: enum with explicit values"
	}
	lappend out [dict get $m name]
    }
    return $out
}

# Token ranges handling enum member m: "case m:" blocks and
# "if (index == m)" blocks.
proc ::tkx::resolve::MemberBlocks {body m} {
    set n [llength $body]
    set out {}
    for {set i 0} {$i < $n} {incr i} {
	set x [lindex $body $i 1]
	if {$x eq "case" && [lindex $body $i+1 1] eq $m && [lindex $body $i+2 1] eq ":"} {
	    # Until the next case/default at the same depth, or the end of the switch.
	    set depth 0
	    for {set j [expr {$i+3}]} {$j < $n} {incr j} {
		set y [lindex $body $j 1]
		if {$y eq "\{"} { incr depth }
		if {$y eq "\}"} { if {$depth == 0} break; incr depth -1 }
		if {$depth == 0 && $y in {case default} && [lindex $body $j+1 1] ne $m} {
		    # fallthrough labels (case A: case B:) stay in the block
		    if {$y eq "case" && [lindex $body $j+2 1] eq ":" && $j == $i+3} continue
		    break
		}
	    }
	    lappend out [list [expr {$i+3}] [expr {$j-1}]]
	}
	if {$x eq "==" && [lindex $body $i+1 1] eq $m} {
	    # The brace block after the condition.
	    for {set j [expr {$i+2}]} {$j < $n && [lindex $body $j 1] ne "\{"} {incr j} {}
	    set close [cparse::match $body $j]
	    lappend out [list $j $close]
	}
    }
    return $out
}

# The handler of a subcommand is the first call in its block that is
# given the argument vector (objv or objv+k) and is not a Tcl/Tk API or
# vocabulary function.  "" means the subcommand is implemented inline.
proc ::tkx::resolve::CaseHandler {body m} {
    foreach blk [MemberBlocks $body $m] {
	lassign $blk s e
	for {set i $s} {$i <= $e} {incr i} {
	    set t [lindex $body $i]
	    if {[lindex $t 0] ne "id" || [lindex $body $i+1 1] ne "("} continue
	    set fn [lindex $t 1]
	    if {$fn in {if while for switch return sizeof}} continue
	    set close [cparse::match $body [expr {$i+1}]]
	    set args [::tkx::extract::SplitArgs [lrange $body $i+2 $close-1]]
	    set passesArgv 0
	    foreach a $args {
		set w [Words $a]
		if {[lindex $w 0] eq "objv" && ([llength $w] == 1 || [lindex $w 1] eq "+")} {
		    set passesArgv 1
		}
	    }
	    if {!$passesArgv} continue
	    if {[string match Tcl_* $fn] || [string match Tk_* $fn]
		    || [dict exists $::tkx::config::conversions $fn]} continue
	    return $fn
	}
    }
    return ""
}

# Value conversion for an option handled in the blocks for member m.
# The value is objv[i+1].
proc ::tkx::resolve::OptionValueEvidence {body m rel func} {
    foreach blk [MemberBlocks $body $m] {
	lassign $blk s e
	for {set i $s} {$i <= $e} {incr i} {
	    if {[lindex $body $i 1] eq "objv" && [join [Words [lrange $body $i+1 $i+5]] " "] eq "\[ i + 1 \]"} {
		set ct [ArgConversion $body $i [expr {$e+1}] [list objv \[ i + 1 \]] $rel $func]
		dict set ct line [lindex $body $i 2]
		# String compared against literals: an enumeration.
		if {[dict get $ct type] eq "string"} {
		    set lits [StrcmpLiterals $body $i $e]
		    if {[llength $lits] >= 2} {
			dict set ct type enum
			dict set ct values $lits
			dict set ct conv "[dict get $ct conv]+strcmp"
		    }
		}
		dict set ct src "$rel:[lindex $body $i 2]"
		return $ct
	    }
	}
    }
    return [dict create type unknown conv "" src "" note "value not parsed in a recognised block"]
}

proc ::tkx::resolve::StrcmpLiterals {body from to} {
    # V = Tcl_GetString(objv[i+1]); ... strcmp(V, "lit") ...
    set var ""
    for {set k [expr {$from-1}]} {$k > $from-6} {incr k -1} {
	if {[lindex $body $k 1] eq "="} { set var [lindex $body $k-1 1]; break }
    }
    if {$var eq ""} { return {} }
    set lits {}
    for {set i $from} {$i <= $to} {incr i} {
	if {[lindex $body $i 1] eq "strcmp" && [lindex $body $i+2 1] eq $var
		&& [lindex $body $i+4 0] eq "str"} {
	    lappend lits [clex::strvalue [lindex $body $i+4 1]]
	}
    }
    return $lits
}
