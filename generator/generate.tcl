# generate.tcl --
#
#	Generate the tkx C API from the extracted IR and the schema overlays.
#
#	Outputs (all deterministic, no timestamps or absolute paths):
#	    include/tkx_generated.h      public generated declarations
#	    src/tkx_generated.c          generated implementation + metadata
#	    tests/tkx_bridge_generated.c tcltest bridge adapters (one per fn)
#	    generated/api.json           every generated function + provenance
#	    generated/coverage.json      discovered/generated/excluded counts
#
#	Usage:
#	    tclsh generate.tcl --tk-src DIR --tcl-src DIR --out DIR
#
#	Approach labels used in api.json / coverage.json:
#	    extracted   declarative Tk tables only (Approach 1, tier A)
#	    inferred    constrained evidence from function bodies (Approach 1,
#	                tier B, with the conversion vocabulary)
#	    schema      a schema overlay supplied missing semantics (Approach 2)
#	    handwritten implemented in src/tkx_*.c (Approach 3), listed in
#	                docs/EXTRACTION.md with justification

set ::tkx_generator_dir [file dirname [file normalize [info script]]]
source [file join $::tkx_generator_dir extract.tcl]
source [file join $::tkx_generator_dir json.tcl]

namespace eval ::tkx::gen {
    # Classes for which C functions are emitted.  The kind numbers are part
    # of the ABI and must never be reused or renumbered.  'prefix' is the
    # C name prefix (tkx_<prefix>_...).  This is scope selection, not
    # widget metadata: everything else about a class is extracted.
    variable selection {
	toplevel      {kind 1 prefix toplevel}
	frame         {kind 2 prefix frame}
	ttk::frame    {kind 3 prefix ttk_frame}
	ttk::label    {kind 4 prefix ttk_label}
	ttk::button   {kind 5 prefix ttk_button}
	ttk::entry    {kind 6 prefix ttk_entry}
	ttk::treeview {kind 7 prefix ttk_treeview}
    }

    variable ir
    variable enums	;# dict EnumName -> {values src table}
    variable funcs	;# list of function records (see AddFunc)
    variable meta	;# dict kind -> option metadata rows
    variable cov	;# coverage dict
    variable diags
}

proc ::tkx::gen::Fail {msg} {
    return -code error -errorcode {TKX GEN} "GENERATE: $msg"
}

# ---------------------------------------------------------------------
# Names and enums
# ---------------------------------------------------------------------

proc ::tkx::gen::CIdent {s} {
    set s [string map {- _ : _ . _ # _ " " _} $s]
    regsub -all {[^A-Za-z0-9_]} $s _ s
    regsub -all {_+} $s _ s
    return [string trim $s _]
}

proc ::tkx::gen::EnumNameFromTable {table} {
    set n $table
    regsub {^(ttk|tk)(?=[A-Z])} $n {} n
    regsub {(Strings|Names)$} $n {} n
    return "Tkx[string toupper [string index $n 0]][string range $n 1 end]"
}

# Register an enum (by name) and return its type string "enum:NAME".
proc ::tkx::gen::Enum {name values src table} {
    variable enums
    if {[dict exists $enums $name]} {
	if {[dict get $enums $name values] ne $values} {
	    Fail "enum $name used with different values: [dict get $enums $name values] vs $values"
	}
	return "enum:$name"
    }
    dict set enums $name [dict create values $values src $src table $table]
    return "enum:$name"
}

proc ::tkx::gen::EnumConst {ename value} {
    set base [string toupper [CIdent [string range $ename 3 end]]]
    # TkxSelectMode -> SELECTMODE; keep word boundaries of CamelCase
    regsub -all {([a-z0-9])([A-Z])} [string range $ename 3 end] {\1_\2} words
    set base [string toupper $words]
    return "TKX_${base}_[string toupper [CIdent $value]]"
}

# ---------------------------------------------------------------------
# Value types
# ---------------------------------------------------------------------
#   string int bool double pixels index window list sticky padding box
#   enum:NAME  plus string-like aliases: color font cursor bitmap statespec
#   item column tag  and itemlist (list)

proc ::tkx::gen::StringLike {vt} {
    expr {$vt in {string color font cursor bitmap statespec item column tag}}
}

proc ::tkx::gen::MetaType {vt} {
    switch -glob -- $vt {
	string - statespec - item - column - tag { return TKX_TYPE_STRING }
	color { return TKX_TYPE_COLOR }
	font { return TKX_TYPE_FONT }
	cursor { return TKX_TYPE_CURSOR }
	bitmap { return TKX_TYPE_BITMAP }
	int { return TKX_TYPE_INT }
	bool { return TKX_TYPE_BOOL }
	double { return TKX_TYPE_DOUBLE }
	pixels { return TKX_TYPE_PIXELS }
	index { return TKX_TYPE_INDEX }
	window { return TKX_TYPE_WINDOW }
	list - itemlist { return TKX_TYPE_LIST }
	enum:* { return TKX_TYPE_ENUM }
	callback { return TKX_TYPE_CALLBACK }
	default { return TKX_TYPE_OPAQUE }
    }
}

# C parameter declaration(s) for an input value.
proc ::tkx::gen::ParamDecl {vt name {optional 0}} {
    if {[StringLike $vt]} { return "const char *$name" }
    switch -glob -- $vt {
	int - bool - pixels - index {
	    return [expr {$optional ? "const int *$name" : "int $name"}]
	}
	double { return [expr {$optional ? "const double *$name" : "double $name"}] }
	window { return [expr {$optional ? "const TkxId *$name" : "TkxId $name"}] }
	list - itemlist { return "const char *const *$name, size_t ${name}_count" }
	sticky { return [expr {$optional ? "const unsigned *$name" : "unsigned $name"}] }
	padding { return "int ${name}_before, int ${name}_after" }
	enum:* {
	    set e [string range $vt 5 end]
	    return [expr {$optional ? "const $e *$name" : "$e $name"}]
	}
	default { Fail "no parameter mapping for type $vt" }
    }
}

# C expression building a Tcl_Obj from a parameter.
proc ::tkx::gen::ObjExpr {vt name {optional 0} {nullOk 0}} {
    set v [expr {$optional && ![StringLike $vt] && $vt ni {list itemlist padding} ? "*$name" : $name}]
    if {[StringLike $vt]} { return "tkx__str($v)" }
    switch -glob -- $vt {
	int - pixels { return "tkx__int($v)" }
	bool { return "tkx__bool($v)" }
	index { return "tkx__index($v)" }
	double { return "tkx__double($v)" }
	window { return "tkx__window($v)" }
	list - itemlist { return "tkx__strlist($name, ${name}_count)" }
	sticky { return "tkx__sticky($v)" }
	padding { return "tkx__padding(${name}_before, ${name}_after)" }
	enum:* {
	    set e [string range $vt 5 end]
	    return "tkx__enum(tkx__enum_$e, [llength [EnumValues $e]], (int)($v), $nullOk)"
	}
    }
    Fail "no object mapping for type $vt"
}

proc ::tkx::gen::EnumValues {e} {
    variable enums
    dict get $enums $e values
}

# Out-parameter declaration(s) for a result value.
proc ::tkx::gen::OutDecl {vt} {
    if {[StringLike $vt]} { return "char **out" }
    switch -glob -- $vt {
	int - bool - pixels - index { return "int *out" }
	double { return "double *out" }
	window { return "TkxId *out" }
	list - itemlist { return "TkxStringList *out" }
	sticky { return "unsigned *out" }
	padding { return "int *before, int *after" }
	box { return "TkxBox *out" }
	enum:* { return "[string range $vt 5 end] *out" }
    }
    Fail "no result mapping for type $vt"
}

proc ::tkx::gen::OutNames {vt} {
    if {$vt eq "padding"} { return {before after} }
    return {out}
}

# C statements converting Tcl_Obj *v into the out parameter(s).
proc ::tkx::gen::ConvStmt {vt} {
    if {[StringLike $vt]} { return "st = tkx__to_string(v, out);" }
    switch -glob -- $vt {
	int - index { return "st = tkx__to_int(v, out);" }
	pixels { return "st = tkx__to_pixels(w, v, out);" }
	bool { return "st = tkx__to_bool(v, out);" }
	double { return "st = tkx__to_double(v, out);" }
	window { return "st = tkx__to_window(v, out);" }
	list - itemlist { return "st = tkx__to_strlist(v, out);" }
	sticky { return "st = tkx__to_sticky(v, out);" }
	padding { return "st = tkx__to_padding(w, v, before, after);" }
	box { return "st = tkx__to_box(v, out);" }
	enum:* {
	    set e [string range $vt 5 end]
	    return "\{ int tmp = 0; st = tkx__to_enum(v, tkx__enum_$e, [llength [EnumValues $e]], &tmp); if (st == TKX_OK) *out = ($e)tmp; \}"
	}
    }
    Fail "no conversion for type $vt"
}

# Value type of an extracted option record (or "" if not mappable).
proc ::tkx::gen::OptionVT {o} {
    set type [dict get $o type]
    switch -- $type {
	BOOLEAN { return bool }
	INT { return int }
	DOUBLE { return double }
	STRING { return string }
	COLOR - BORDER { return color }
	FONT { return font }
	CURSOR { return cursor }
	BITMAP { return bitmap }
	PIXELS { return pixels }
	WINDOW { return window }
	INDEX { return index }
	STRING_TABLE - RELIEF - JUSTIFY - ANCHOR {
	    set tbl [dict get $o stringTable]
	    return [Enum [EnumNameFromTable $tbl] [dict get $o enumValues] \
		    [dict get $o enumSrc] $tbl]
	}
	default { return "" }
    }
}

proc ::tkx::gen::OverlayFor {table cmd name} {
    foreach key [list [list $cmd $name] [list * $name]] {
	if {[dict exists $table $key]} { return [dict get $table $key] }
    }
    return {}
}

proc ::tkx::gen::CheckEvidence {ov o where} {
    if {![dict exists $ov evidence]} return
    dict for {k v} [dict get $ov evidence] {
	set actual [expr {[dict exists $o $k] ? [dict get $o $k] : ""}]
	if {$actual ne $v} {
	    Fail "overlay drift at $where: expected $k '$v', extracted '$actual'"
	}
    }
}

# ---------------------------------------------------------------------
# Option classification (used for every discovered class)
# ---------------------------------------------------------------------
# Returns dict: status (generated|readonly|callback|alias|excluded|
# internal|unsupported), vt, approach, why, script (0/1)
proc ::tkx::gen::ClassifyOption {cmd o {ovTable options} {subKey ""}} {
    set name [dict get $o optionName]
    set r [dict create status "" vt "" approach extracted why "" script 0]
    if {![string match -* $name]} {
	return [dict merge $r {status internal why "option name without '-' is internal to Tk"}]
    }
    if {[dict get $o type] eq "SYNONYM"} {
	return [dict merge $r [dict create status alias why "synonym of [dict get $o synonymOf]"]]
    }
    if {$subKey eq ""} {
	set ov [OverlayFor $::tkx::schema::options $cmd $name]
	if {$ov eq {}} { set ov [OverlayFor $::tkx::schema::optionsExtra $cmd $name] }
    } else {
	set key [list {*}$subKey $name]
	set ov [expr {[dict exists $::tkx::schema::subobjectOptions $key] ? [dict get $::tkx::schema::subobjectOptions $key] : {}}]
    }
    if {$ov ne {}} {
	CheckEvidence $ov $o "$cmd $subKey $name"
	set treat [dict get $ov treat]
	dict set r why [dict get $ov why]
	switch -- $treat {
	    excluded {
		set script [expr {[string match *script* [string tolower [dict get $ov why]]]
			|| [string match *Variable* [dict get $o dbClass]]}]
		return [dict merge $r [dict create status excluded approach schema script $script]]
	    }
	    callback {
		return [dict merge $r [dict create status callback vt callback approach schema script 1]]
	    }
	    type {
		dict set r vt [dict get $ov type]
		if {[dict exists $ov literal]} { dict set r literal [dict get $ov literal] }
		dict set r approach schema
	    }
	}
    }
    if {[dict get $r vt] eq ""} {
	if {[dict get $o type] eq "CUSTOM"} {
	    return [dict merge $r [dict create status unsupported \
		    why "TK_OPTION_CUSTOM ([dict get $o customOption]): value semantics are defined by custom C code"]]
	}
	set vt [OptionVT $o]
	if {$vt eq ""} {
	    return [dict merge $r [dict create status unsupported why "option type [dict get $o type] has no C mapping"]]
	}
	dict set r vt $vt
    }
    set ro [expr {[dict exists $o readonly] && [dict get $o readonly]}]
    set co [expr {[dict exists $o createOnly] && [dict get $o createOnly]}]
    dict set r status [expr {$ro || $co ? "readonly" : "generated"}]
    return $r
}

# ---------------------------------------------------------------------
# Function records
# ---------------------------------------------------------------------
# A function record:
#   name      C name
#   kind      setter|getter|command|create|callback|geometry...
#   target    kind mask expression ("" for none)
#   params    {{name vt optional} ...}
#   words     Tcl word template (list of {lit X} | {path} | {param NAME}
#             | {flag -x NAME} | {cmd X})
#   result    vt or "none"
#   approach  extracted|inferred|schema
#   prov      provenance list
#   doc       one-line description
#   class     owning class command or manager
#   nullOk    for enum params (option setters)

proc ::tkx::gen::AddFunc {rec} {
    variable funcs
    foreach f $funcs {
	if {[dict get $f name] eq [dict get $rec name]} {
	    Fail "duplicate generated function [dict get $rec name]"
	}
    }
    lappend funcs $rec
}

proc ::tkx::gen::OptionFunctions {cmd prefix kindMask o cls {sub ""} {subKey ""}} {
    variable cov
    set c [ClassifyOption $cmd $o [expr {$sub eq "" ? "options" : "subobjectOptions"}] $subKey]
    set name [dict get $o optionName]
    set id [CIdent [string range $name 1 end]]
    set st [dict get $c status]
    set prov [list [dict get $o src]]
    if {[dict exists $o defaultMacroSrc] && [dict get $o defaultMacroSrc] ne ""} {
	lappend prov "default: [dict get $o defaultMacroSrc]"
    }
    set nullOk [expr {"nullOk" in [dict get $o flags]}]
    set vt [dict get $c vt]
    set base "tkx_${prefix}"
    set lead {}
    # Widget options: "$w configure -opt value" / "$w cget -opt".
    # Sub-object options: "$w item $id -opt value" / "$w item $id -opt".
    set setWords [list [list lit configure]]
    set getWords [list [list lit cget]]
    if {$sub ne ""} {
	lassign [dict get $::tkx::gen::ir subobjects $subKey key] kname ktype
	set base "tkx_${prefix}_${sub}"
	set lead [list [list $kname $ktype 0]]
	set setWords [list [list lit $sub] [list param $kname]]
	set getWords $setWords
    }
    switch -- $st {
	generated - readonly {
	    if {$st eq "generated"} {
		AddFunc [dict create name "${base}_set_$id" kind setter class $cmd \
			target $kindMask params [concat $lead [list [list value $vt 0]]] \
			words [concat $setWords [list [list lit $name] [list param value]]] \
			result none approach [dict get $c approach] prov $prov nullOk $nullOk \
			literal [expr {[dict exists $c literal] ? [dict get $c literal] : ""}] \
			option $name sub $sub \
			doc "Set the $name option ([dict get $o type])."]
	    }
	    AddFunc [dict create name "${base}_get_$id" kind getter class $cmd \
		    target $kindMask params $lead \
		    words [concat $getWords [list [list lit $name]]] \
		    result $vt approach [dict get $c approach] prov $prov nullOk $nullOk \
		    option $name sub $sub \
		    doc "Get the $name option ([dict get $o type])."]
	    if {$nullOk && $st eq "generated" && ![StringLike $vt] && $vt ni {list}} {
		AddFunc [dict create name "${base}_unset_$id" kind unset class $cmd \
			target $kindMask params $lead \
			words [concat $setWords [list [list lit $name] [list lit ""]]] \
			result none approach [dict get $c approach] prov $prov nullOk 1 \
			option $name sub $sub \
			doc "Set $name to the empty value (use the theme/default)."]
	    }
	}
	callback {
	    AddFunc [dict create name "${base}_set_$id" kind callback class $cmd \
		    target $kindMask params {} words {} result callback \
		    approach schema prov $prov option $name sub $sub \
		    doc "Register a C callback for $name (replaces any previous one; fn NULL clears)."]
	}
    }
    return $c
}

proc ::tkx::gen::TypeFromEvidence {a} {
    set t [dict get $a type]
    switch -- $t {
	index - string - item - column - tag - statespec - int - double - window - itemlist {
	    return $t
	}
	boolean { return bool }
	enum {
	    return [Enum [EnumNameFromTable [dict get $a table]] [dict get $a values] \
		    [dict get $a tableSrc] [dict get $a table]]
	}
	default { return "" }
    }
}

proc ::tkx::gen::ResultFromEvidence {r} {
    switch -- [dict get $r kind] {
	none { return none }
	typed {
	    set t [dict get $r type]
	    if {$t eq "boolean"} { return bool }
	    if {$t in {string int double box list statespec item}} { return $t }
	}
    }
    return ""
}

# Subcommand functions of a selected class.
proc ::tkx::gen::CommandFunctions {cmd prefix kindMask cls} {
    set out {}
    set overlays $::tkx::schema::commands
    set done {}
    # Overlay entries first (they override evidence).
    foreach key [lsort [dict keys $overlays]] {
	lassign $key ocmd opath
	if {$ocmd ne "*" && $ocmd ne $cmd} continue
	set spec [dict get $overlays $key]
	set path [expr {[dict exists $spec path] ? [dict get $spec path] : [lindex [split $opath #] 0]}]
	set entry ""
	foreach c [dict get $cls commands] {
	    if {[join [dict get $c path] " "] eq $path} { set entry $c }
	}
	if {$entry eq ""} {
	    if {$ocmd eq "*"} continue
	    Fail "overlay drift: $cmd has no subcommand '$path'"
	}
	set ev [dict get $entry evidence]
	set want [dict get $spec evidence]
	if {[dict exists $want usage]} {
	    set have {}
	    foreach us [dict get $ev usages] { lappend have [dict get $us usage] }
	    if {[dict get $want usage] ni $have} {
		Fail "overlay drift: $cmd $path usage '[dict get $want usage]' not among extracted usages {$have}"
	    }
	}
	set fname [expr {[dict exists $spec name] ? [dict get $spec name] : [CIdent [string map {" " _} $path]]}]
	set params {}
	foreach p [dict get $spec params] {
	    lassign $p pn pt popt
	    lappend params [list $pn [ResolveVT $pt] [expr {$popt eq "optional"}]]
	}
	set words {}
	foreach w [split $path " "] { lappend words [list lit $w] }
	if {[dict exists $spec words]} {
	    foreach w [dict get $spec words] {
		if {[llength $w] == 2} {
		    lappend words [list flag [lindex $w 0] [lindex $w 1]]
		} elseif {[string index $w 0] eq "="} {
		    lappend words [list lit [string range $w 1 end]]
		} else { lappend words [list param $w] }
	    }
	} else {
	    foreach p $params { lappend words [list param [lindex $p 0]] }
	}
	AddFunc [dict create name "tkx_${prefix}_$fname" kind command class $cmd \
		target $kindMask params $params words $words \
		result [ResolveVT [dict get $spec result]] approach schema \
		prov [list [dict get $entry src] [dict get $ev src]] \
		doc "Tk: \$w $path ([dict get $spec why])"]
	lappend done $path
    }
    # Complete evidence: generated directly.
    foreach c [dict get $cls commands] {
	set path [join [dict get $c path] " "]
	if {$path in $done || $path in {cget configure}} continue
	set ev [dict get $c evidence]
	if {$ev eq {} || [dict get $ev status] ne "complete"} continue
	lassign [dict get $ev arity] mn mx
	set params {}
	set ok 1
	set usage [expr {[llength [dict get $ev usages]] ? [dict get [lindex [dict get $ev usages] 0] usage] : ""}]
	set unames [regsub -all {[?]} $usage ""]
	set i 0
	foreach a [dict get $ev args] {
	    set vt [TypeFromEvidence $a]
	    if {$vt eq ""} { set ok 0; break }
	    set pn [CIdent [lindex $unames $i]]
	    if {$pn eq "" || $pn in {value out w widget}} { set pn "arg$i" }
	    lappend params [list $pn $vt [expr {$i >= $mn}]]
	    incr i
	}
	set rt [ResultFromEvidence [dict get $ev result]]
	if {!$ok || $rt eq ""} continue
	set words {}
	foreach w [dict get $c path] { lappend words [list lit $w] }
	foreach p $params { lappend words [list param [lindex $p 0]] }
	AddFunc [dict create name "tkx_${prefix}_[CIdent [join [dict get $c path] _]]" \
		kind command class $cmd target $kindMask params $params words $words \
		result $rt approach inferred prov [list [dict get $c src] [dict get $ev src]] \
		doc "Tk: \$w $path $usage"]
    }
}

proc ::tkx::gen::ResolveVT {t} {
    variable ir
    if {$t eq "boolean"} { return bool }
    if {[string match enum:* $t]} {
	set bt [string range $t 5 end]
	set e [dict get $ir enumTypes $bt]
	return [Enum [EnumNameFromTable [dict get $e table]] [dict get $e values] \
		[dict get $e src] [dict get $e table]]
    }
    return $t
}

# ---------------------------------------------------------------------
# Geometry managers
# ---------------------------------------------------------------------

proc ::tkx::gen::GeometryFunctions {mgr} {
    variable ir
    set g [dict get $ir geometry $mgr]
    set spec [dict get $::tkx::schema::geometry $mgr]
    set subs [dict create]
    foreach s [dict get $g subcommands] { dict set subs [dict get $s name] $s }
    set any 0   ;# any widget kind
    # Per-window configure options -> set/get functions.
    set cfg [dict get $subs [dict get $spec configure]]
    set handler [dict get $cfg handler]
    set h [dict get $g handlers $handler]
    set infoSub [dict get $spec info]
    if {![dict exists $subs $infoSub]} { Fail "overlay drift: $mgr has no '$infoSub' subcommand" }
    foreach o [dict get $h options] {
	set name [dict get $o name]
	set id [CIdent [string range $name 1 end]]
	set vt [GeoVT $mgr $o]
	if {$vt eq ""} {
	    lappend ::tkx::gen::geoSkipped [list $mgr $name "value type not inferred"]
	    continue
	}
	AddFunc [dict create name "tkx_${mgr}_set_$id" kind geometry class $mgr \
		target 0 params [list [list value $vt 0]] \
		words [list [list cmd "::$mgr"] [list lit configure] [list path] [list lit $name] [list param value]] \
		result none approach inferred \
		prov [list [dict get $h src] [dict get $o src]] option $name \
		doc "Tk: $mgr configure \$w $name value ([dict get $o conv])"]
	AddFunc [dict create name "tkx_${mgr}_get_$id" kind geometry-info class $mgr \
		target 0 params {} \
		words [list [list cmd "::$mgr"] [list lit $infoSub] [list path]] \
		infoKey $name result $vt approach inferred \
		prov [list [dict get $h src] [dict get $o src]] option $name \
		doc "Value of $name from '$mgr $infoSub \$w' (TKX_ERR_EMPTY if not managed by $mgr)."]
    }
    # Row/column slot options.
    foreach slot [dict get $spec slots] {
	set ss [dict get $subs $slot]
	set sh [dict get $g handlers [dict get $ss handler]]
	set sname [string map {configure ""} $slot]
	foreach o [dict get $sh options] {
	    set name [dict get $o name]
	    set id [CIdent [string range $name 1 end]]
	    set vt [GeoVT $mgr $o]
	    if {$vt eq ""} continue
	    AddFunc [dict create name "tkx_${mgr}_${slot}_$id" kind geometry class $mgr \
		    target 0 params [list [list index int 0] [list value $vt 0]] \
		    words [list [list cmd "::$mgr"] [list lit $slot] [list path] [list param index] [list lit $name] [list param value]] \
		    result none approach inferred \
		    prov [list [dict get $sh src] [dict get $o src]] option $name \
		    doc "Tk: $mgr $slot \$container index $name value"]
	    AddFunc [dict create name "tkx_${mgr}_${slot}_get_$id" kind geometry class $mgr \
		    target 0 params [list [list index int 0]] \
		    words [list [list cmd "::$mgr"] [list lit $slot] [list path] [list param index] [list lit $name]] \
		    result $vt approach inferred \
		    prov [list [dict get $sh src] [dict get $o src]] option $name \
		    doc "Tk: $mgr $slot \$container index $name"]
	}
    }
    # Other subcommands (schema signatures, names verified).
    foreach fname [lsort [dict keys [dict get $spec commands]]] {
	set cs [dict get $spec commands $fname]
	set sub [dict get $cs sub]
	if {![dict exists $subs $sub]} { Fail "overlay drift: $mgr has no subcommand '$sub'" }
	set u [dict get $cs usage]
	if {$u ne "" && $u ni [dict get $subs $sub usages]} {
	    Fail "overlay drift: $mgr $sub usage '$u' not among [dict get $subs $sub usages]"
	}
	set params {}
	set words [list [list cmd "::$mgr"] [list lit $sub] [list path]]
	foreach p [dict get $cs params] {
	    lassign $p pn pt
	    lappend params [list $pn [ResolveVT $pt] 0]
	    lappend words [list param $pn]
	}
	AddFunc [dict create name "tkx_${mgr}_$fname" kind geometry class $mgr \
		target 0 params $params words $words result [ResolveVT [dict get $cs result]] \
		approach schema prov [list [dict get $g subcommandSrc]] \
		doc "Tk: $mgr $sub \$w ... ([dict get $cs why])"]
    }
    # Composites.
    dict for {fname cs} [dict get $spec composite] {
	set params {}
	set words [list [list cmd "::$mgr"] [list lit configure] [list path]]
	foreach {opt pn} [dict get $cs options] {
	    set o ""
	    foreach x [dict get $h options] { if {[dict get $x name] eq $opt} { set o $x } }
	    if {$o eq ""} { Fail "overlay drift: $mgr configure has no option $opt" }
	    lappend params [list $pn [GeoVT $mgr $o] 0]
	    lappend words [list lit $opt] [list param $pn]
	}
	AddFunc [dict create name "tkx_$fname" kind geometry class $mgr target 0 \
		params $params words $words result none approach schema \
		prov [list [dict get $h src]] doc "Tk: $mgr configure \$w ... ([dict get $cs why])"]
    }
}

proc ::tkx::gen::GeoVT {mgr o} {
    set t [dict get $o type]
    switch -- $t {
	int - pixels - window - padding - sticky { return $t }
	boolean { return bool }
	string { return string }
	anchor { return [ResolveVT enum:ANCHOR] }
	enum {
	    if {[dict exists $o table]} {
		return [Enum [EnumNameFromTable [dict get $o table]] [dict get $o values] \
			[dict get $o tableSrc] [dict get $o table]]
	    }
	    set nm "Tkx[string totitle $mgr][string totitle [string range [dict get $o name] 1 end]]"
	    return [Enum $nm [dict get $o values] [dict get $o src] ""]
	}
    }
    return ""
}

# ---------------------------------------------------------------------
# C emission
# ---------------------------------------------------------------------

proc ::tkx::gen::Header {what} {
    variable ir
    set tk [dict get $ir source tk]
    set tcl [dict get $ir source tcl]
    return "/*
 * $what
 *
 * GENERATED FILE -- DO NOT EDIT.
 * Generated by generator/generate.tcl from the Tk source tree.
 *   Tk  [dict get $tk patchLevel] (manifest [dict get $tk manifest])
 *   Tcl [dict get $tcl patchLevel] (manifest [dict get $tcl manifest])
 * Regenerate with:  make generate    Verify with:  make check-generated
 */
"
}

proc ::tkx::gen::Proto {f} {
    set ps {}
    if {[dict get $f kind] eq "create"} {
	return "TKX_API TkxId [dict get $f name](TkxId parent)"
    }
    if {[dict get $f kind] eq "callback"} {
	return "TKX_API TkxId [dict get $f name](TkxId widget, TkxCommandFn fn, void *user_data, TkxFreeFn free_fn)"
    }
    lappend ps "TkxId widget"
    foreach p [dict get $f params] {
	lassign $p pn pt popt
	lappend ps [ParamDecl $pt $pn $popt]
    }
    if {[dict get $f result] ne "none"} {
	lappend ps [OutDecl [dict get $f result]]
    }
    return "TKX_API TkxStatus [dict get $f name]([join $ps {, }])"
}

proc ::tkx::gen::EmitHeader {} {
    variable funcs
    variable enums
    variable ir
    variable selection
    set h [Header "tkx_generated.h -- generated widget API"]
    append h "#ifndef TKX_GENERATED_H\n#define TKX_GENERATED_H\n\n"
    append h "#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n"
    append h "#define TKX_TK_SOURCE_VERSION \"[dict get $ir source tk patchLevel]\"\n\n"
    append h "/* Widget kinds (stable ABI numbers). */\n"
    dict for {cmd s} $selection {
	append h "#define TKX_KIND_[string toupper [dict get $s prefix]] [dict get $s kind]\n"
    }
    append h "\n/* Enumerations extracted from Tk string tables. */\n"
    foreach e [lsort [dict keys $enums]] {
	set ed [dict get $enums $e]
	append h "/* [dict get $ed src][expr {[dict get $ed table] ne "" ? " ([dict get $ed table])" : ""}] */\n"
	append h "typedef enum $e \{\n"
	append h "    [EnumConst $e UNSET] = -1,   /* empty value; only for options that allow it */\n"
	set i 0
	foreach v [dict get $ed values] {
	    append h "    [EnumConst $e $v] = $i,   /* \"$v\" */\n"
	    incr i
	}
	append h "\} $e;\n\n"
    }
    set cur ""
    foreach f $funcs {
	set grp [dict get $f class]
	if {$grp ne $cur} {
	    append h "/* ---- $grp ---- */\n\n"
	    set cur $grp
	}
	append h "/* [dict get $f doc]\n * \[[dict get $f approach]\] [join [dict get $f prov] {; }] */\n"
	append h "[Proto $f];\n\n"
    }
    append h "#ifdef __cplusplus\n}\n#endif\n\n#endif /* TKX_GENERATED_H */\n"
    return $h
}

proc ::tkx::gen::CStr {s} {
    set out "\""
    foreach ch [split $s ""] {
	scan $ch %c c
	if {$ch eq "\""} { append out "\\\"" } elseif {$ch eq "\\"} { append out "\\\\" } elseif {$c < 32 || $c > 126} {
	    foreach b [split [encoding convertto utf-8 $ch] ""] {
		scan $b %c bv
		append out [format "\\%03o" $bv]
	    }
	} else { append out $ch }
    }
    return "$out\""
}

proc ::tkx::gen::Body {f} {
    set kind [dict get $f kind]
    set name [dict get $f name]
    set target [dict get $f target]
    set b "\{\n    TkxWidget *w;\n    TkxStatus st;\n"
    if {$kind eq "create"} {
	return "\{\n    return tkx__create([dict get $f kindConst], [CStr [dict get $f class]], parent, 0, NULL);\n\}\n"
    }
    if {$kind eq "callback"} {
	return "\{\n    TkxWidget *w;\n    if (tkx__widget(widget, $target, &w) != TKX_OK) return TKX_NULL_ID;\n    return tkx__callback_option(w, [CStr [dict get $f option]], fn, user_data, free_fn);\n\}\n"
    }
    set result [dict get $f result]
    # Argument checks.
    set checks ""
    set pointerParams {}
    foreach p [dict get $f params] {
	lassign $p pn pt popt
	if {!$popt && ([StringLike $pt])} {
	    append checks "    if ($pn == NULL) return tkx__arg_error(\"$pn\");\n"
	}
	if {$pt in {list itemlist} && !$popt} {
	    append checks "    if ($pn == NULL && ${pn}_count != 0) return tkx__arg_error(\"$pn\");\n"
	}
    }
    if {$result ne "none"} {
	foreach on [OutNames $result] {
	    append checks "    if ($on == NULL) return tkx__arg_error(\"$on\");\n"
	}
    }
    # Positional optional params must be trailing.
    set seenOpt ""
    foreach w [dict get $f words] {
	if {[lindex $w 0] ne "param"} continue
	set p [ParamByName $f [lindex $w 1]]
	if {[lindex $p 2]} {
	    if {$seenOpt ne ""} {
		append checks "    if ($seenOpt == NULL && [lindex $p 0] != NULL) return tkx__arg_error(\"[lindex $p 0] given without $seenOpt\");\n"
	    }
	    set seenOpt [lindex $p 0]
	}
    }
    append b "    Tcl_Obj *objv\[[expr {[llength [dict get $f words]] * 2 + 2}]\];\n    int objc = 0;\n"
    if {$result ne "none"} { append b "    Tcl_Obj *v = NULL;\n" }
    append b "    st = tkx__widget(widget, $target, &w);\n    if (st != TKX_OK) return st;\n"
    append b $checks
    # Build words.
    set usesPath 0
    foreach wd [dict get $f words] {
	switch -- [lindex $wd 0] {
	    cmd { append b "    objv\[objc++\] = tkx__str([CStr [lindex $wd 1]]);\n" }
	    path { append b "    objv\[objc++\] = w->path;\n"; set usesPath 1 }
	    lit { append b "    objv\[objc++\] = tkx__str([CStr [lindex $wd 1]]);\n" }
	    param {
		set p [ParamByName $f [lindex $wd 1]]
		lassign $p pn pt popt
		set nullOk [expr {[dict exists $f nullOk] ? [dict get $f nullOk] : 0}]
		set expr [ObjExpr $pt $pn $popt $nullOk]
		if {$pt in {list itemlist} && [dict exists $f literal] && [dict get $f literal] ne ""} {
		    set expr "tkx__strlist_lit($pn, ${pn}_count, [CStr [dict get $f literal]])"
		}
		if {$popt} {
		    append b "    if ($pn != NULL) \{\n        if ((objv\[objc\] = $expr) == NULL) goto argfail;\n        objc++;\n    \}\n"
		} else {
		    append b "    if ((objv\[objc\] = $expr) == NULL) goto argfail;\n    objc++;\n"
		}
	    }
	    flag {
		lassign $wd - flg pn
		set p [ParamByName $f $pn]
		set expr [ObjExpr [lindex $p 1] $pn [lindex $p 2] 0]
		append b "    if ($pn != NULL) \{\n        objv\[objc++\] = tkx__str([CStr $flg]);\n        if ((objv\[objc\] = $expr) == NULL) goto argfail;\n        objc++;\n    \}\n"
	    }
	}
    }
    set isWidgetCall [expr {[lindex [dict get $f words] 0 0] ni {cmd}}]
    set resv [expr {$result ne "none" ? "&v" : "NULL"}]
    if {$isWidgetCall} {
	append b "    st = tkx__widget_call(w, objc, objv, $resv);\n"
    } else {
	append b "    st = tkx__invoke(objc, objv, $resv);\n"
    }
    if {$result ne "none"} {
	append b "    if (st != TKX_OK) return st;\n"
	if {[dict exists $f infoKey]} {
	    append b "    \{\n        Tcl_Obj *d = v;\n        st = tkx__dict_get(d, [CStr [dict get $f infoKey]], &v);\n        Tcl_DecrRefCount(d);\n        if (st != TKX_OK) return st;\n    \}\n"
	}
	append b "    [ConvStmt $result]\n    Tcl_DecrRefCount(v);\n    return st;\n"
    } else {
	append b "    return st;\n"
    }
    append b "argfail:\n    tkx__discard(objc, objv);\n    return tkx_last_error();\n\}\n"
    return $b
}

proc ::tkx::gen::ParamByName {f n} {
    foreach p [dict get $f params] { if {[lindex $p 0] eq $n} { return $p } }
    Fail "[dict get $f name]: no parameter $n"
}

proc ::tkx::gen::EmitSource {} {
    variable funcs
    variable enums
    variable meta
    variable selection
    variable ir
    set c [Header "tkx_generated.c -- generated widget API implementation"]
    append c "#include \"tkx_internal.h\"\n\n"
    append c "/* Enumeration string tables (copied from the Tk sources). */\n"
    foreach e [lsort [dict keys $enums]] {
	set vals {}
	foreach v [dict get $enums $e values] { lappend vals [CStr $v] }
	append c "static const char *const tkx__enum_$e\[\] = \{[join $vals {, }]\};\n"
    }
    append c "\n/* Class metadata for the generic property interface. */\n"
    dict for {cmd s} $selection {
	set k [dict get $s kind]
	set rows {}
	foreach m [dict get $meta $cmd] {
	    lassign $m name dbn dbc type flags alias enum src
	    set ev [expr {$enum eq "" ? "NULL, 0" : "tkx__enum_$enum, [llength [EnumValues $enum]]"}]
	    lappend rows "    \{[CStr $name], [CStr $dbn], [CStr $dbc], $type, $flags, [expr {$alias eq "" ? "NULL" : [CStr $alias]}], $ev, [CStr $src]\}"
	}
	append c "static const TkxOptionInfo tkx__options_[dict get $s prefix]\[\] = \{\n[join $rows ",\n"]\n\};\n"
	set order {}
	set refused [dict create]
	foreach sc [dict get $ir classes $cmd commands] {
	    set p [lindex [dict get $sc path] 0]
	    if {$p ni $order} { lappend order $p; dict set refused $p 0 }
	    set ev [dict get $sc evidence]
	    if {$p in {cget configure}
		    || ($ev ne {} && [dict exists $ev takesScript] && [dict get $ev takesScript])} {
		dict set refused $p 1
	    }
	}
	# Sub-object subcommands whose option table has script-valued options.
	foreach key [dict keys [dict get $ir subobjects]] {
	    if {[lindex $key 0] ne $cmd} continue
	    foreach o [dict get $ir subobjects $key options] {
		set cl [ClassifyOption $cmd $o subobjectOptions $key]
		if {[dict get $cl script]} { dict set refused [lindex $key 1] 1 }
	    }
	}
	set subs {}
	foreach p $order { lappend subs "\{[CStr $p], [dict get $refused $p]\}" }
	append c "static const TkxSubcommandInfo tkx__subcommands_[dict get $s prefix]\[\] = \{[join $subs {, }]\};\n\n"
    }
    append c "const TkxClassInfo tkx__classes\[\] = \{\n"
    set rows {}
    dict for {cmd s} $selection {
	set p [dict get $s prefix]
	lappend rows "    \{[dict get $s kind], [CStr $cmd], tkx__options_$p, (int)(sizeof(tkx__options_$p)/sizeof(tkx__options_$p\[0\])), tkx__subcommands_$p, (int)(sizeof(tkx__subcommands_$p)/sizeof(tkx__subcommands_$p\[0\]))\}"
    }
    append c "[join $rows ",\n"]\n\};\nconst int tkx__class_count = [dict size $selection];\n\n"
    foreach f $funcs {
	set proto [string map {"TKX_API " ""} [Proto $f]]
	append c "$proto\n[Body $f]\n"
    }
    return $c
}

# ---------------------------------------------------------------------
# Test bridge adapters
# ---------------------------------------------------------------------

proc ::tkx::gen::BridgeArg {pt pn popt idx} {
    # Returns {decls conversion callArgs}
    set src "objv\[$idx\]"
    if {[StringLike $pt]} {
	if {$popt} {
	    return [list "    const char *$pn = NULL;\n" "    if (objc > $idx && !tkxb_is_omitted($src)) $pn = Tcl_GetString($src);\n" $pn]
	}
	return [list "    const char *$pn;\n" "    $pn = Tcl_GetString($src);\n" $pn]
    }
    switch -glob -- $pt {
	int - bool - pixels - index - double - window - sticky {
	    set ct [dict get {int int bool int pixels int index int double double window TkxId sticky unsigned} $pt]
	    set fn [dict get {int tkxb_get_int bool tkxb_get_bool pixels tkxb_get_int index tkxb_get_index double tkxb_get_double window tkxb_get_id sticky tkxb_get_sticky} $pt]
	    if {$popt} {
		return [list "    $ct ${pn}_v = 0; const $ct *$pn = NULL;\n" \
		    "    if (objc > $idx && !tkxb_is_omitted($src)) \{ if (${fn}(ip, $src, &${pn}_v) != TCL_OK) return TCL_ERROR; $pn = &${pn}_v; \}\n" $pn]
	    }
	    return [list "    $ct $pn;\n" "    if (${fn}(ip, $src, &$pn) != TCL_OK) return TCL_ERROR;\n" $pn]
	}
	list - itemlist {
	    return [list "    TkxbStrv $pn = \{0\};\n" \
		"    if (objc > $idx && !tkxb_is_omitted($src) && tkxb_get_strv(ip, $src, &$pn) != TCL_OK) return TCL_ERROR;\n" \
		"(const char *const *)$pn.items, $pn.count"]
	}
	padding {
	    return [list "    int ${pn}_a, ${pn}_b;\n" "    if (tkxb_get_pair(ip, $src, &${pn}_a, &${pn}_b) != TCL_OK) return TCL_ERROR;\n" "${pn}_a, ${pn}_b"]
	}
	enum:* {
	    set e [string range $pt 5 end]
	    set n [llength [EnumValues $e]]
	    if {$popt} {
		return [list "    int ${pn}_i = 0; $e ${pn}_v; const $e *$pn = NULL;\n" \
		    "    if (objc > $idx && !tkxb_is_omitted($src)) \{ if (tkxb_get_enum(ip, $src, tkxb_enum_$e, $n, &${pn}_i) != TCL_OK) return TCL_ERROR; ${pn}_v = ($e)${pn}_i; $pn = &${pn}_v; \}\n" $pn]
	    }
	    return [list "    int ${pn}_i;\n" "    if (tkxb_get_enum(ip, $src, tkxb_enum_$e, $n, &${pn}_i) != TCL_OK) return TCL_ERROR;\n" "($e)${pn}_i"]
	}
    }
    Fail "bridge: no adapter for $pt"
}

proc ::tkx::gen::BridgeResult {rt} {
    # Returns {decls callArgs setResult cleanup}
    if {[StringLike $rt]} {
	return [list "    char *out = NULL;\n" "&out" "    Tcl_SetObjResult(ip, Tcl_NewStringObj(out, -1));\n" "    tkx_free(out);\n"]
    }
    switch -glob -- $rt {
	int - bool - pixels - index {
	    return [list "    int out = 0;\n" "&out" "    Tcl_SetObjResult(ip, Tcl_NewWideIntObj(out));\n" ""]
	}
	double { return [list "    double out = 0;\n" "&out" "    Tcl_SetObjResult(ip, Tcl_NewDoubleObj(out));\n" ""] }
	window { return [list "    TkxId out = 0;\n" "&out" "    Tcl_SetObjResult(ip, Tcl_NewWideIntObj((Tcl_WideInt)out));\n" ""] }
	sticky { return [list "    unsigned out = 0;\n" "&out" "    Tcl_SetObjResult(ip, Tcl_NewWideIntObj(out));\n" ""] }
	list - itemlist {
	    return [list "    TkxStringList out = \{0, NULL\};\n" "&out" "    tkxb_set_strlist(ip, &out);\n" "    tkx_string_list_free(&out);\n"]
	}
	box { return [list "    TkxBox out;\n" "&out" "    tkxb_set_box(ip, &out);\n" ""] }
	padding { return [list "    int before = 0, after = 0;\n" "&before, &after" "    tkxb_set_pair(ip, before, after);\n" ""] }
	callback { return [list "" "" "" ""] }
	enum:* {
	    set e [string range $rt 5 end]
	    return [list "    $e out = ($e)0;\n" "&out" "    tkxb_set_enum(ip, tkxb_enum_$e, [llength [EnumValues $e]], (int)out);\n" ""]
	}
    }
    Fail "bridge: no result adapter for $rt"
}

proc ::tkx::gen::EmitBridge {} {
    variable funcs
    variable enums
    set c [Header "tkx_bridge_generated.c -- tcltest adapters for every generated function"]
    append c "#include \"test_bridge.h\"\n\n"
    foreach e [lsort [dict keys $enums]] {
	set vals {}
	foreach v [dict get $enums $e values] { lappend vals [CStr $v] }
	append c "static const char *const tkxb_enum_$e\[\] = \{[join $vals {, }]\};\n"
    }
    append c "\n"
    set rows {}
    foreach f $funcs {
	set name [dict get $f name]
	set kind [dict get $f kind]
	set decls ""
	set conv ""
	set args {}
	set idx 1
	set nreq 1
	if {$kind eq "create"} {
	    append c "static int b_${name}(Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv\[\])\n\{\n"
	    append c "    TkxId parent = 0, id;\n    if (objc < 1 || tkxb_get_id(ip, objv\[0\], &parent) != TCL_OK) return TCL_ERROR;\n"
	    append c "    id = ${name}(parent);\n    if (id == TKX_NULL_ID) return tkxb_status(ip, tkx_last_error());\n"
	    append c "    Tcl_SetObjResult(ip, Tcl_NewWideIntObj((Tcl_WideInt)id));\n    return TCL_OK;\n\}\n\n"
	    lappend rows [list $name 1 [BridgeInfo $f]]
	    continue
	}
	if {$kind eq "callback"} {
	    append c "static int b_${name}(Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv\[\])\n\{\n"
	    append c "    TkxId wid, cb;\n    if (objc < 1 || tkxb_get_id(ip, objv\[0\], &wid) != TCL_OK) return TCL_ERROR;\n"
	    append c "    cb = tkxb_register_command(ip, wid, objc > 1 ? objv\[1\] : NULL, $name);\n"
	    append c "    if (cb == TKX_NULL_ID && objc > 1) return tkxb_status(ip, tkx_last_error());\n"
	    append c "    Tcl_SetObjResult(ip, Tcl_NewWideIntObj((Tcl_WideInt)cb));\n    return TCL_OK;\n\}\n\n"
	    lappend rows [list $name 1 [BridgeInfo $f]]
	    continue
	}
	foreach p [dict get $f params] {
	    lassign $p pn pt popt
	    lassign [BridgeArg $pt $pn $popt $idx] d cv ca
	    append decls $d
	    append conv $cv
	    lappend args $ca
	    if {!$popt} { set nreq [expr {$idx + 1}] }
	    incr idx
	}
	set rt [dict get $f result]
	set rdecl ""; set rarg ""; set rset ""; set rclean ""
	if {$rt ne "none"} {
	    lassign [BridgeResult $rt] rdecl rarg rset rclean
	    lappend args $rarg
	}
	append c "static int b_${name}(Tcl_Interp *ip, Tcl_Size objc, Tcl_Obj *const objv\[\])\n\{\n"
	append c "    TkxId wid;\n    TkxStatus st;\n$decls$rdecl"
	append c "    if (objc < $nreq) \{ Tcl_SetObjResult(ip, Tcl_NewStringObj(\"wrong # args\", -1)); return TCL_ERROR; \}\n"
	append c "    if (tkxb_get_id(ip, objv\[0\], &wid) != TCL_OK) return TCL_ERROR;\n$conv"
	append c "    st = ${name}([join [concat wid $args] {, }]);\n"
	foreach p [dict get $f params] {
	    if {[lindex $p 1] in {list itemlist}} { append c "    tkxb_free_strv(&[lindex $p 0]);\n" }
	}
	append c "    if (st != TKX_OK) return tkxb_status(ip, st);\n$rset$rclean    return TCL_OK;\n\}\n\n"
	lappend rows [list $name [expr {[llength [dict get $f params]] + 1}] [BridgeInfo $f]]
    }
    append c "const TkxbEnum tkxb_enums\[\] = \{\n"
    foreach e [lsort [dict keys $enums]] {
	append c "    \{\"$e\", tkxb_enum_$e, [llength [EnumValues $e]]\},\n"
    }
    append c "    \{NULL, NULL, 0\}\n\};\n\n"
    append c "const TkxbFunc tkxb_generated\[\] = \{\n"
    foreach r [lsort -index 0 $rows] {
	append c "    \{\"[lindex $r 0]\", b_[lindex $r 0], [CStr [lindex $r 2]]\},\n"
    }
    append c "    \{NULL, NULL, NULL\}\n\};\n"
    return $c
}

# Machine-readable description of a function for data-driven tests.
proc ::tkx::gen::BridgeInfo {f} {
    set params {}
    foreach p [dict get $f params] { lappend params $p }
    return [list kind [dict get $f kind] group [dict get $f class] \
	    option [expr {[dict exists $f option] ? [dict get $f option] : ""}] \
	    sub [expr {[dict exists $f sub] ? [dict get $f sub] : ""}] \
	    result [dict get $f result] params $params \
	    approach [dict get $f approach]]
}

# ---------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------

proc ::tkx::gen::Build {irIn} {
    variable ir $irIn
    variable enums [dict create]
    variable funcs {}
    variable meta [dict create]
    variable cov [dict create]
    variable selection
    set ::tkx::gen::geoSkipped {}
    # Make sure the overlays are loaded (resolve.tcl sourced them).
    set classes [dict get $ir classes]
    # Coverage over every discovered class.
    set classCov [dict create]
    set savedEnums $enums   ;# classification of unselected classes must not emit enums
    foreach cmd [lsort [dict keys $classes]] {
	set cls [dict get $classes $cmd]
	set counts [dict create]
	set optRows {}
	foreach o [dict get $cls options] {
	    set c [ClassifyOption $cmd $o]
	    dict incr counts [dict get $c status]
	    lappend optRows [::tkx::json::obj [list name [::tkx::json::s [dict get $o optionName]] \
		    type [::tkx::json::s [dict get $o type]] status [::tkx::json::s [dict get $c status]] \
		    approach [::tkx::json::s [dict get $c approach]] source [::tkx::json::s [dict get $o src]] \
		    why [::tkx::json::s [dict get $c why]]]]
	}
	set evc [dict create]
	set cmdRows {}
	foreach sc [dict get $cls commands] {
	    set ev [dict get $sc evidence]
	    set stt [expr {$ev eq {} ? "classic-table" : [dict get $ev status]}]
	    if {[join [dict get $sc path]] in {cget configure}} { set stt option-mechanism }
	    dict incr evc $stt
	    lappend cmdRows [::tkx::json::obj [list path [::tkx::json::s [join [dict get $sc path]]] \
		    evidence [::tkx::json::s $stt] source [::tkx::json::s [dict get $sc src]] \
		    reasons [::tkx::json::strs [expr {$ev eq {} ? {} : [dict get $ev reasons]}]]]]
	}
	dict set classCov $cmd [dict create counts $counts evidence $evc optRows $optRows cmdRows $cmdRows \
		total [llength [dict get $cls options]] commands [llength [dict get $cls commands]] \
		kind [dict get $cls kind]]
    }
    set enums $savedEnums
    # Functions for selected classes.
    dict for {cmd s} $selection {
	if {![dict exists $classes $cmd]} { Fail "selected class $cmd was not discovered" }
	set cls [dict get $classes $cmd]
	set prefix [dict get $s prefix]
	set kconst "TKX_KIND_[string toupper $prefix]"
	set mask "TKX__KINDBIT($kconst)"
	AddFunc [dict create name "tkx_${prefix}_create" kind create class $cmd kindConst $kconst \
		target "" params {} words {} result none approach [expr {[dict get $cls kind] eq "ttk" ? "extracted" : "schema"}] \
		prov [list [dict get $cls registeredAt]] doc "Create a $cmd widget (Tk class [dict get $cls className]); parent TKX_NULL_ID means the main window."]
	set rows {}
	foreach o [dict get $cls options] {
	    set c [OptionFunctions $cmd $prefix $mask $o $cls]
	    set flags {}
	    if {"nullOk" in [dict get $o flags]} { lappend flags TKX_OPT_NULL_OK }
	    if {[dict get $c status] eq "readonly"} { lappend flags TKX_OPT_READONLY }
	    if {[dict get $c status] eq "alias"} { lappend flags TKX_OPT_ALIAS }
	    if {[dict get $c script]} { lappend flags TKX_OPT_SCRIPT }
	    if {[dict get $c status] ni {generated readonly callback}} { lappend flags TKX_OPT_NO_ACCESSOR }
	    set vt [dict get $c vt]
	    if {$vt eq "" && [dict get $c status] eq "alias"} {
		foreach o2 [dict get $cls options] {
		    if {[dict get $o2 optionName] eq [dict get $o synonymOf]} {
			set vt [dict get [ClassifyOption $cmd $o2] vt]
		    }
		}
	    }
	    set mt [expr {$vt eq "" ? (([dict get $o type] eq "STRING") ? "TKX_TYPE_STRING" : "TKX_TYPE_OPAQUE") : [MetaType $vt]}]
	    set en [expr {[string match enum:* $vt] ? [string range $vt 5 end] : ""}]
	    lappend rows [list [dict get $o optionName] [dict get $o dbName] [dict get $o dbClass] \
		    $mt [expr {[llength $flags] ? [join $flags |] : 0}] \
		    [expr {[dict exists $o synonymOf] ? [dict get $o synonymOf] : ""}] $en [dict get $o src]]
	}
	dict set meta $cmd $rows
	CommandFunctions $cmd $prefix $mask $cls
	# Sub-object option accessors.
	foreach key [lsort [dict keys [dict get $ir subobjects]]] {
	    if {[lindex $key 0] ne $cmd} continue
	    set so [dict get $ir subobjects $key]
	    foreach o [dict get $so options] {
		OptionFunctions $cmd $prefix $mask $o $cls [lindex $key 1] $key
	    }
	}
    }
    foreach mgr {grid pack} { GeometryFunctions $mgr }
    set cov $classCov
}

proc ::tkx::gen::ApiJson {} {
    variable funcs
    variable ir
    set rows {}
    foreach f $funcs {
	set ps {}
	foreach p [dict get $f params] {
	    lassign $p pn pt popt
	    lappend ps [::tkx::json::obj [list name [::tkx::json::s $pn] type [::tkx::json::s $pt] optional [::tkx::json::b $popt]]]
	}
	lappend rows [::tkx::json::obj [list name [::tkx::json::s [dict get $f name]] \
		group [::tkx::json::s [dict get $f class]] kind [::tkx::json::s [dict get $f kind]] \
		approach [::tkx::json::s [dict get $f approach]] params [list arr $ps] \
		result [::tkx::json::s [dict get $f result]] provenance [::tkx::json::strs [dict get $f prov]] \
		doc [::tkx::json::s [dict get $f doc]]]]
    }
    return [::tkx::json::write [::tkx::json::obj [list \
	    source [::tkx::json::obj [list tk [::tkx::json::s [dict get $ir source tk patchLevel]] \
		tkManifest [::tkx::json::s [dict get $ir source tk manifest]] \
		tcl [::tkx::json::s [dict get $ir source tcl patchLevel]]]] \
	    functions [list arr $rows]]]]
}

proc ::tkx::gen::CoverageJson {} {
    variable cov
    variable funcs
    variable ir
    variable selection
    set classes {}
    foreach cmd [lsort [dict keys $cov]] {
	set c [dict get $cov $cmd]
	set counts {}
	foreach k [lsort [dict keys [dict get $c counts]]] { lappend counts $k [::tkx::json::n [dict get $c counts $k]] }
	set ev {}
	foreach k [lsort [dict keys [dict get $c evidence]]] { lappend ev $k [::tkx::json::n [dict get $c evidence $k]] }
	lappend classes $cmd [::tkx::json::obj [list kind [::tkx::json::s [dict get $c kind]] \
		selected [::tkx::json::b [dict exists $selection $cmd]] \
		optionsDiscovered [::tkx::json::n [dict get $c total]] optionStatus [::tkx::json::obj $counts] \
		subcommandsDiscovered [::tkx::json::n [dict get $c commands]] subcommandEvidence [::tkx::json::obj $ev] \
		options [list arr [dict get $c optRows]] subcommands [list arr [dict get $c cmdRows]]]]
    }
    set byApproach [dict create]
    set byGroup [dict create]
    foreach f $funcs {
	dict incr byApproach [dict get $f approach]
	dict incr byGroup [dict get $f class]
    }
    set ba {}
    foreach k [lsort [dict keys $byApproach]] { lappend ba $k [::tkx::json::n [dict get $byApproach $k]] }
    set bg {}
    foreach k [lsort [dict keys $byGroup]] { lappend bg $k [::tkx::json::n [dict get $byGroup $k]] }
    set geo {}
    foreach mgr {grid pack} {
	set g [dict get $ir geometry $mgr]
	set subs {}
	foreach s [dict get $g subcommands] {
	    lappend subs [::tkx::json::obj [list name [::tkx::json::s [dict get $s name]] handler [::tkx::json::s [dict get $s handler]] deprecated [::tkx::json::b [dict get $s deprecated]]]]
	}
	set hs {}
	dict for {h hv} [dict get $g handlers] {
	    set os {}
	    foreach o [dict get $hv options] {
		lappend os [::tkx::json::obj [list name [::tkx::json::s [dict get $o name]] type [::tkx::json::s [dict get $o type]] conversion [::tkx::json::s [dict get $o conv]] source [::tkx::json::s [dict get $o src]]]]
	    }
	    lappend hs $h [list arr $os]
	}
	lappend geo $mgr [::tkx::json::obj [list subcommands [list arr $subs] optionHandlers [::tkx::json::obj $hs]]]
    }
    set diags {}
    foreach d [dict get $ir diagnostics] {
	lassign $d l w m
	if {$l eq "note"} continue
	lappend diags [::tkx::json::obj [list level [::tkx::json::s $l] where [::tkx::json::s $w] message [::tkx::json::s $m]]]
    }
    return [::tkx::json::write [::tkx::json::obj [list \
	    source [::tkx::json::obj [list tk [::tkx::json::s [dict get $ir source tk patchLevel]] tcl [::tkx::json::s [dict get $ir source tcl patchLevel]]]] \
	    generatedFunctions [::tkx::json::n [llength $funcs]] \
	    functionsByApproach [::tkx::json::obj $ba] functionsByGroup [::tkx::json::obj $bg] \
	    classes [::tkx::json::obj $classes] geometry [::tkx::json::obj $geo] \
	    diagnostics [list arr $diags]]]]
}

proc ::tkx::gen::WriteFile {path content} {
    file mkdir [file dirname $path]
    set f [open $path w]
    fconfigure $f -encoding utf-8 -translation lf
    puts -nonewline $f $content
    close $f
}

proc ::tkx::gen::run {tk tcl out} {
    set ir [::tkx::extract::run $tk $tcl]
    Build $ir
    WriteFile [file join $out include tkx_generated.h] [EmitHeader]
    WriteFile [file join $out src tkx_generated.c] [EmitSource]
    WriteFile [file join $out tests tkx_bridge_generated.c] [EmitBridge]
    WriteFile [file join $out generated api.json] "[ApiJson]\n"
    WriteFile [file join $out generated coverage.json] "[CoverageJson]\n"
    return [llength $::tkx::gen::funcs]
}

if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    array set opt {--tk-src "" --tcl-src "" --out ""}
    array set opt $argv
    foreach k {--tk-src --tcl-src --out} {
	if {$opt($k) eq ""} { puts stderr "usage: generate.tcl --tk-src DIR --tcl-src DIR --out DIR"; exit 2 }
    }
    if {[catch {::tkx::gen::run $opt(--tk-src) $opt(--tcl-src) $opt(--out)} n]} {
	puts stderr $n
	exit 1
    }
    puts "generated $n functions"
}
