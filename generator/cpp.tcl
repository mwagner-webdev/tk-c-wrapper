# cpp.tcl --
#
#	Restricted, deterministic C preprocessor used by the tkx extractor.
#
#	Supported:
#	  * #if/#ifdef/#ifndef/#elif/#else/#endif with integer expressions,
#	    defined X / defined(X), macro expansion inside expressions
#	  * #define (object-like and function-like, variadic, # and ##),
#	    #undef
#	  * #include "file" resolved inside the configured Tcl/Tk source
#	    trees (system includes <...> are skipped and recorded)
#	  * #error in an active region is reported as a diagnostic
#	  * #pragma, #line, #warning, #ident are ignored
#
#	The preprocessor runs once per *platform configuration* (unix, win,
#	macos).  A configuration is a set of predefined platform macros and an
#	include path.  Identifiers that are undefined in an #if expression
#	evaluate to 0 (as in C); when such an identifier is not one of the
#	known platform macros it is recorded as an *assumption* and every
#	token produced under that condition carries the assumption, so the
#	extractor can report build-configuration-dependent declarations
#	instead of silently treating them as unconditional.
#
#	Macro definitions are kept with their position in the main file's
#	output token stream, so that expansion at a given point uses the
#	definition that was in force there (C semantics for #define/#undef).

source [file join [file dirname [info script]] clex.tcl]

namespace eval ::cpp {
    # Per-run state lives in this array; runs are not reentrant.
    variable S
}

proc ::cpp::Error {msg} {
    return -code error -errorcode {CPP} "CPP $msg"
}

# cpp::run --
#	Preprocess one translation unit.
#	    main     absolute path of the .c file
#	    config   dict: name, predefined (dict name->value),
#		     incpath (list of abs dirs), known (list of platform
#		     macro names that are "known" in every configuration)
#	    root     absolute directory used to make paths relative
#	Returns a dict:
#	    tokens   active tokens of the main file {kind text line cond}
#	    headerTokens  dict relpath -> active tokens (headers)
#	    macros   dict name -> list of {pos def}
#	    conds    list of condition strings (index = cond id)
#	    diags    list of diagnostics
#	    includes list of relpaths included (in order)
proc ::cpp::run {main config root} {
    variable S
    array unset S
    set S(roots) {}
    if {[llength $root] == 1} { set root [list $root ""] }
    foreach {r prefix} $root {
	lappend S(roots) [file normalize $r] $prefix
    }
    set S(config) $config
    set S(known) [dict get $config known]
    set S(incpath) [dict get $config incpath]
    set S(macros) [dict create]
    set S(out) {}
    set S(headerTokens) [dict create]
    set S(diags) {}
    set S(includes) {}
    set S(conds) [list {}]	;# cond id 0 = unconditional
    set S(condIds) [dict create {} 0]
    set S(lexed) {}
    set S(stack) {}
    set S(curCond) ""
    set S(skips) {}
    set S(mainRel) ""
    set S(depth) 0
    set S(keep) [dict get $config keepHeaders]
    dict for {name value} [dict get $config predefined] {
	set toks [clex::tokenize $value "<predefined $name>"]
	DefineMacro $name [dict create kind obj params {} variadic 0 \
		body $toks file "<config>" line 0]
    }
    set S(mainRel) [Rel $main]
    ProcessFile $main 1
    if {[llength $S(stack)]} {
	Error "[Rel $main]: unterminated conditional at end of file"
    }
    FinalizeConds
    return [dict create tokens $S(out) headerTokens $S(headerTokens) \
	    macros $S(macros) conds $S(conds) skips $S(skips) diags $S(diags) \
	    includes $S(includes)]
}

# Paths in provenance are relative to a source root, optionally prefixed
# (root may be a list of {dir prefix} pairs, first match wins).
proc ::cpp::Rel {path} {
    variable S
    set p [file normalize $path]
    foreach {r prefix} $S(roots) {
	if {[string first "$r/" $p] == 0} {
	    return "$prefix[string range $p [string length $r]+1 end]"
	}
    }
    return [file tail $p]
}

proc ::cpp::Diag {level where msg} {
    variable S
    lappend S(diags) [list $level $where $msg]
}

proc ::cpp::DefineMacro {name def} {
    variable S
    dict set def cond [CondId]
    dict lappend S(macros) $name [list [llength $S(out)] $def]
}

proc ::cpp::UndefMacro {name} {
    variable S
    if {[dict exists $S(macros) $name]} {
	dict lappend S(macros) $name [list [llength $S(out)] {}]
    }
}

# cpp::lookup --
#	Find the definition of a macro in force at output position pos
#	(pos = "end" means the current end of the stream).  Works both during
#	a run and afterwards on a saved macros dict.
proc ::cpp::lookupIn {macros name pos} {
    if {![dict exists $macros $name]} { return {} }
    set def {}
    foreach entry [dict get $macros $name] {
	lassign $entry p d
	if {$pos ne "end" && $p > $pos} { break }
	set def $d
    }
    return $def
}

# A frame's 'active' already includes its parent's state, so only the top
# frame matters.
proc ::cpp::Active {} {
    variable S
    if {![llength $S(stack)]} { return 1 }
    return [dict get [lindex $S(stack) end] active]
}

# Condition ids: a raw id identifies the list of enclosing conditional
# frames that have *candidate* assumptions.  After the run, candidates that
# the scanned source trees #define somewhere are dropped (such a name being
# undefined at that point is a fact of the include order, e.g. an include
# guard), and raw ids are remapped to final condition strings.
proc ::cpp::CondId {} {
    variable S
    if {$S(curCond) ne ""} { return $S(curCond) }
    set frames {}
    foreach fr $S(stack) {
	if {[llength [dict get $fr assumed]]} {
	    lappend frames [list [dict get $fr where] [dict get $fr text] \
		    [dict get $fr assumed]]
	}
    }
    if {![dict exists $S(condIds) $frames]} {
	dict set S(condIds) $frames [llength $S(conds)]
	lappend S(conds) $frames
    }
    set S(curCond) [dict get $S(condIds) $frames]
    return $S(curCond)
}

# Names #defined anywhere in a lexed file (cached per file).
proc ::cpp::DefinedNames {path} {
    variable definedCache
    if {[info exists definedCache($path)]} { return $definedCache($path) }
    set names {}
    foreach tok [clex::lexfile $path] {
	if {[lindex $tok 0] eq "pp" && [lindex $tok 1] eq "define"} {
	    lappend names [lindex $tok 3 0 1]
	}
    }
    set definedCache($path) $names
    return $names
}

proc ::cpp::FinalizeConds {} {
    variable S
    set inTree [dict create]
    foreach path $S(lexed) {
	foreach n [DefinedNames $path] { dict set inTree $n 1 }
    }
    set final [list ""]
    set finalIds [dict create "" 0]
    set remap {}
    foreach frames $S(conds) {
	set parts {}
	foreach fr $frames {
	    lassign $fr where text cands
	    set keep {}
	    foreach c $cands {
		if {![dict exists $inTree $c]} { lappend keep $c }
	    }
	    if {[llength $keep]} {
		lappend parts "$where: $text (assumes undefined: [join $keep {, }])"
	    }
	}
	set key [join $parts " && "]
	if {![dict exists $finalIds $key]} {
	    dict set finalIds $key [llength $final]
	    lappend final $key
	}
	lappend remap [dict get $finalIds $key]
    }
    set out {}
    foreach t $S(out) {
	lset t 3 [lindex $remap [lindex $t 3]]
	lappend out $t
    }
    set S(out) $out
    dict for {h toks} $S(headerTokens) {
	set nt {}
	foreach t $toks {
	    lset t 3 [lindex $remap [lindex $t 3]]
	    lappend nt $t
	}
	dict set S(headerTokens) $h $nt
    }
    set macros [dict create]
    dict for {name hist} $S(macros) {
	set nh {}
	foreach entry $hist {
	    lassign $entry p d
	    if {$d ne {}} { dict set d cond [lindex $remap [dict get $d cond]] }
	    lappend nh [list $p $d]
	}
	dict set macros $name $nh
    }
    set S(macros) $macros
    set S(conds) $final
    set skips {}
    foreach sk $S(skips) {
	lassign $sk pos where text cands
	set keep {}
	foreach c $cands {
	    if {![dict exists $inTree $c]} { lappend keep $c }
	}
	if {[llength $keep]} {
	    lappend skips [list $pos "$where: $text was false (assumes undefined: [join $keep {, }]); its content is not extracted"]
	}
    }
    set S(skips) $skips
}

# Directive-only view of a file (cached): headers that are not kept only
# need their directives.
proc ::cpp::Directives {path} {
    variable dirCache
    if {![info exists dirCache($path)]} {
	set dirCache($path) [lsearch -all -inline -index 0 -exact \
		[clex::lexfile $path] pp]
    }
    return $dirCache($path)
}

proc ::cpp::ResolveInclude {name fromDir} {
    variable S
    set dirs $S(incpath)
    if {$fromDir ne ""} { set dirs [list $fromDir {*}$dirs] }
    foreach dir $dirs {
	set p [file join $dir $name]
	if {[file isfile $p]} { return [file normalize $p] }
    }
    return ""
}

proc ::cpp::ProcessFile {path isMain} {
    variable S
    incr S(depth)
    if {$S(depth) > 64} {
	Error "[Rel $path]: #include nesting too deep"
    }
    set rel [Rel $path]
    set toks [clex::lexfile $path $rel]
    if {$path ni $S(lexed)} { lappend S(lexed) $path }
    if {!$isMain && $rel ni $S(keep)} {
	set toks [Directives $path]
    }
    set dir [file dirname $path]
    set baseDepth [llength $S(stack)]
    set hdr {}
    foreach tok $toks {
	if {[lindex $tok 0] eq "pp"} {
	    Directive $tok $rel $dir
	    continue
	}
	if {![Active]} { continue }
	lassign $tok kind text line
	if {$isMain} {
	    lappend S(out) [list $kind $text $line [CondId]]
	} else {
	    lappend hdr [list $kind $text $line [CondId]]
	}
    }
    if {[llength $S(stack)] != $baseDepth} {
	Error "$rel: unbalanced #if/#endif"
    }
    if {!$isMain && [llength $hdr]} {
	# A header may be included more than once (guards permitting);
	# keep every active instance in order.
	dict lappend S(headerTokens) $rel {*}$hdr
    }
    incr S(depth) -1
}

proc ::cpp::Directive {tok rel dir} {
    variable S
    lassign $tok - name line args
    set where "$rel:$line"
    if {$name in {if ifdef ifndef elif else endif}} {
	set S(curCond) ""	;# the conditional stack changes below
    }
    switch -- $name {
	if - ifdef - ifndef {
	    set parentActive [Active]
	    set value 0
	    set assumed {}
	    set text ""
	    if {$parentActive} {
		switch -- $name {
		    ifdef - ifndef {
			set id [lindex $args 0]
			if {[lindex $id 0] ne "id" || [llength $args] != 1} {
			    Error "$where: malformed #$name"
			}
			set m [lindex $id 1]
			set isdef [expr {[lookupIn $S(macros) $m end] ne {}}]
			if {!$isdef && $m ni $S(known)} { lappend assumed $m }
			set value [expr {$name eq "ifdef" ? $isdef : !$isdef}]
			set text "#$name $m"
		    }
		    if {
			lassign [EvalCond $args $where] value assumed
			set text "#if [TokText $args]"
		    }
		}
	    }
	    lappend S(stack) [dict create active [expr {$parentActive && $value}] \
		    taken [expr {$parentActive && $value}] \
		    parentActive $parentActive assumed $assumed text $text \
		    where $where sawElse 0]
	    NoteSkip $rel
	}
	elif {
	    if {![llength $S(stack)]} { Error "$where: #elif without #if" }
	    set fr [lindex $S(stack) end]
	    if {[dict get $fr sawElse]} { Error "$where: #elif after #else" }
	    if {[dict get $fr parentActive] && ![dict get $fr taken]} {
		lassign [EvalCond $args $where] value assumed
		dict set fr active $value
		dict set fr taken $value
		dict set fr text "#elif [TokText $args]"
		dict set fr where $where
		dict lappend fr assumed {*}$assumed
	    } else {
		dict set fr active 0
	    }
	    lset S(stack) end $fr
	    NoteSkip $rel
	}
	else {
	    if {![llength $S(stack)]} { Error "$where: #else without #if" }
	    set fr [lindex $S(stack) end]
	    if {[dict get $fr sawElse]} { Error "$where: duplicate #else" }
	    dict set fr sawElse 1
	    dict set fr active [expr {[dict get $fr parentActive] && ![dict get $fr taken]}]
	    if {[dict get $fr active]} {
		dict set fr text "#else of [dict get $fr text]"
	    }
	    lset S(stack) end $fr
	    NoteSkip $rel
	}
	endif {
	    if {![llength $S(stack)]} { Error "$where: #endif without #if" }
	    set S(stack) [lrange $S(stack) 0 end-1]
	}
	default {
	    if {![Active]} { return }
	    switch -- $name {
		define { Define $args $where }
		undef {
		    set id [lindex $args 0]
		    if {[lindex $id 0] ne "id"} { Error "$where: malformed #undef" }
		    UndefMacro [lindex $id 1]
		}
		include - import {
		    set a [lindex $args 0]
		    set inc ""
		    if {[lindex $a 0] eq "str"} {
			set inc [clex::strvalue [lindex $a 1] $where]
			set p [ResolveInclude $inc $dir]
		    } elseif {[lindex $a 1] eq "<"} {
			# <...>: searched only on the include path (like -I);
			# headers outside the source trees are system headers
			# and are skipped.
			foreach t [lrange $args 1 end] {
			    if {[lindex $t 1] eq ">"} break
			    append inc [lindex $t 1]
			}
			set p [ResolveInclude $inc ""]
		    } else {
			Error "$where: computed #include is not supported"
		    }
		    if {$p ne "" && $name eq "import" && [Rel $p] in $S(includes)} {
			# Objective-C #import: include at most once.
		    } elseif {$p ne ""} {
			lappend S(includes) [Rel $p]
			ProcessFile $p 0
		    } elseif {[lindex $a 0] eq "str"} {
			Diag note $where "include \"$inc\" not found in source trees (skipped)"
		    }
		}
		error {
		    Diag error $where "#error [TokText $args]"
		}
		pragma - line - warning - ident - "" {}
		default {
		    Error "$where: unsupported directive #$name"
		}
	    }
	}
    }
}

proc ::cpp::TokText {toks} {
    set parts {}
    foreach t $toks { lappend parts [lindex $t 1] }
    return [join $parts " "]
}

proc ::cpp::Define {args where} {
    set first [lindex $args 0]
    if {[lindex $first 0] ne "id"} { Error "$where: malformed #define" }
    set name [lindex $first 1]
    set rest [lrange $args 1 end]
    set params {}
    set variadic 0
    set kind obj
    set second [lindex $rest 0]
    if {[llength $second] && [lindex $second 1] eq "(" && ![lindex $second 3]} {
	set kind func
	set i 1
	set expectParam 1
	while 1 {
	    set t [lindex $rest $i]
	    if {![llength $t]} { Error "$where: unterminated macro parameter list" }
	    incr i
	    set tx [lindex $t 1]
	    if {$tx eq ")"} { break }
	    if {$tx eq ","} { set expectParam 1; continue }
	    if {$tx eq "..."} { set variadic 1; continue }
	    if {[lindex $t 0] eq "id" && $expectParam} {
		lappend params $tx
		set expectParam 0
		continue
	    }
	    Error "$where: malformed macro parameter list"
	}
	set rest [lrange $rest $i end]
    }
    set body {}
    foreach t $rest { lappend body [lrange $t 0 2] }
    variable S
    DefineMacro $name [dict create kind $kind params $params \
	    variadic $variadic body $body file [lindex [split $where :] 0] \
	    line [lindex [split $where :] end]]
}

# cpp::EvalCond --
#	Evaluate an #if/#elif expression.  Returns {value assumedList}.
proc ::cpp::EvalCond {toks where} {
    variable S
    set assumed {}
    # 1. Replace defined X / defined(X).
    set t2 {}
    set n [llength $toks]
    for {set i 0} {$i < $n} {incr i} {
	set t [lindex $toks $i]
	if {[lindex $t 0] eq "id" && [lindex $t 1] eq "defined"} {
	    set nx [lindex $toks [incr i]]
	    set paren 0
	    if {[lindex $nx 1] eq "("} {
		set paren 1
		set nx [lindex $toks [incr i]]
	    }
	    if {[lindex $nx 0] ne "id"} { Error "$where: malformed defined()" }
	    if {$paren} {
		if {[lindex [lindex $toks [incr i]] 1] ne ")"} {
		    Error "$where: malformed defined()"
		}
	    }
	    set m [lindex $nx 1]
	    set isdef [expr {[lookupIn $S(macros) $m end] ne {}}]
	    if {!$isdef && $m ni $S(known)} { lappend assumed $m }
	    lappend t2 [list num $isdef [lindex $t 2]]
	    continue
	}
	lappend t2 [lrange $t 0 2]
    }
    # 2. Macro-expand the rest.
    set exp [expand $t2 [list ::cpp::lookupIn $S(macros)] end {} $where]
    # 3. Translate to a Tcl expression (whitelisted tokens only).
    set e ""
    set n [llength $exp]
    for {set i 0} {$i < $n} {incr i} {
	lassign [lindex $exp $i] kind text
	switch -- $kind {
	    id {
		if {$text ni $S(known) && $text ni $assumed} { lappend assumed $text }
		# An undefined function-like name: treat the call as 0.
		if {[lindex [lindex $exp $i+1] 1] eq "("} {
		    set depth 0
		    for {incr i} {$i < $n} {incr i} {
			set tx [lindex [lindex $exp $i] 1]
			if {$tx eq "("} { incr depth }
			if {$tx eq ")"} { incr depth -1; if {!$depth} break }
		    }
		}
		append e " 0"
	    }
	    num {
		if {![regexp -nocase {^(0x[0-9a-f]+|[0-9]+)[ul]*$} $text -> digits]} {
		    Error "$where: unsupported number '$text' in #if"
		}
		if {[regexp {^0[0-7]+$} $digits]} { set digits "0o[string range $digits 1 end]" }
		append e " $digits"
	    }
	    chr {
		set v [clex::strvalue "\"[string range $text 1 end-1]\"" $where]
		scan $v %c code
		append e " $code"
	    }
	    punct {
		if {$text ni {( ) ! ~ * / % + - << >> < > <= >= == != & ^ | && || ? :}} {
		    Error "$where: unsupported operator '$text' in #if"
		}
		append e " $text"
	    }
	    default { Error "$where: unsupported token '$text' in #if" }
	}
    }
    if {[catch {expr $e} v]} {
	Error "$where: cannot evaluate #if expression '[TokText $toks]': $v"
    }
    return [list [expr {$v != 0}] $assumed]
}

# cpp::expand --
#	Macro-expand a token list.
#	    toks     tokens {kind text line ?origin?}
#	    lookup   command prefix: invoked as {*}$lookup name pos
#	    pos      position whose definitions apply ("end" during a run)
#	    protect  identifiers that must never be expanded
#	    where    location for error messages
#	    hide     macro names not to expand (rescanning rule)
#	Tokens produced by a top-level macro invocation carry the name of that
#	macro as 4th element (origin) for provenance.
proc ::cpp::expand {toks lookup pos protect where {hide {}} {depth 0}} {
    if {$depth > 200} { Error "$where: macro expansion too deep" }
    set out {}
    set n [llength $toks]
    for {set i 0} {$i < $n} {incr i} {
	set t [lindex $toks $i]
	lassign $t kind text line origin
	if {$kind ne "id" || $text in $protect || $text in $hide} {
	    lappend out $t
	    continue
	}
	set def [{*}$lookup $text $pos]
	if {$def eq {}} {
	    lappend out $t
	    continue
	}
	set org [expr {$origin ne "" ? $origin : $text}]
	if {[dict get $def kind] eq "obj"} {
	    set body {}
	    foreach b [dict get $def body] {
		lappend body [list [lindex $b 0] [lindex $b 1] $line $org]
	    }
	    set body [Paste $body $where]
	    set res [expand $body $lookup $pos $protect $where \
		    [list {*}$hide $text] [expr {$depth+1}]]
	    CheckTail $res $toks [expr {$i+1}] $lookup $pos $protect $hide $where
	    lappend out {*}$res
	    continue
	}
	# Function-like: needs a following '('.
	if {[lindex [lindex $toks $i+1] 1] ne "("} {
	    lappend out $t
	    continue
	}
	set args {}
	set cur {}
	set level 0
	set j [expr {$i+2}]
	set closed 0
	for {} {$j < $n} {incr j} {
	    set a [lindex $toks $j]
	    set tx [lindex $a 1]
	    if {[lindex $a 0] eq "punct"} {
		if {$tx eq "(" } { incr level }
		if {$tx eq ")"} {
		    if {$level == 0} { set closed 1; break }
		    incr level -1
		}
		if {$tx eq "," && $level == 0} {
		    lappend args $cur
		    set cur {}
		    continue
		}
	    }
	    lappend cur $a
	}
	if {!$closed} { Error "$where: unterminated invocation of macro $text" }
	lappend args $cur
	set params [dict get $def params]
	set np [llength $params]
	if {$np == 0 && !([dict get $def variadic]) && [llength $args] == 1 && [llength [lindex $args 0]] == 0} {
	    set args {}
	}
	if {[dict get $def variadic]} {
	    if {[llength $args] < $np} {
		Error "$where: too few arguments to macro $text"
	    }
	    set va [lrange $args $np end]
	    set vtoks {}
	    set first 1
	    foreach a $va {
		if {!$first} { lappend vtoks [list punct , $line] }
		lappend vtoks {*}$a
		set first 0
	    }
	    set args [list {*}[lrange $args 0 $np-1] $vtoks]
	    lappend params __VA_ARGS__
	} elseif {[llength $args] != $np} {
	    Error "$where: macro $text expects $np arguments, got [llength $args]"
	}
	set amap [dict create]
	foreach p $params a $args { dict set amap $p $a }
	set body [dict get $def body]
	set sub {}
	set nb [llength $body]
	for {set k 0} {$k < $nb} {incr k} {
	    lassign [lindex $body $k] bk btx
	    if {$bk eq "punct" && $btx eq "#" && [dict exists $amap [lindex [lindex $body $k+1] 1]]} {
		set p [lindex [lindex $body [incr k]] 1]
		set s [TokText [dict get $amap $p]]
		lappend sub [list str "\"[string map {\\ \\\\ \" \\\"} $s]\"" $line $org]
		continue
	    }
	    if {$bk eq "id" && [dict exists $amap $btx]} {
		set raw [dict get $amap $btx]
		set prevPaste [expr {$k > 0 && [lindex [lindex $body $k-1] 1] eq "##"}]
		set nextPaste [expr {[lindex [lindex $body $k+1] 1] eq "##"}]
		if {$prevPaste || $nextPaste} {
		    set ex $raw
		} else {
		    set ex [expand $raw $lookup $pos $protect $where $hide [expr {$depth+1}]]
		}
		foreach x $ex { lappend sub [list [lindex $x 0] [lindex $x 1] $line $org] }
		continue
	    }
	    lappend sub [list $bk $btx $line $org]
	}
	set sub [Paste $sub $where]
	set res [expand $sub $lookup $pos $protect $where [list {*}$hide $text] [expr {$depth+1}]]
	CheckTail $res $toks [expr {$j+1}] $lookup $pos $protect $hide $where
	lappend out {*}$res
	set i $j
    }
    return $out
}

# A macro expansion that ends in the name of a function-like macro which
# is followed by '(' in the surrounding text would need full C rescanning
# semantics; Tk's tables do not do this, so refuse instead of guessing.
proc ::cpp::CheckTail {res toks next lookup pos protect hide where} {
    set last [lindex $res end]
    if {[lindex $last 0] ne "id"} return
    if {[lindex [lindex $toks $next] 1] ne "("} return
    set nm [lindex $last 1]
    if {$nm in $protect || $nm in $hide} return
    set def [{*}$lookup $nm $pos]
    if {$def ne {} && [dict get $def kind] eq "func"} {
	Error "$where: unsupported macro rescanning across expansion boundary ($nm)"
    }
}

proc ::cpp::Paste {toks where} {
    set out {}
    set n [llength $toks]
    for {set i 0} {$i < $n} {incr i} {
	set t [lindex $toks $i]
	if {[lindex $t 1] eq "##" && [lindex $t 0] eq "punct"} {
	    set left [lindex $out end]
	    set right [lindex $toks [incr i]]
	    if {![llength $left] || ![llength $right]} {
		Error "$where: ## at edge of macro body"
	    }
	    set txt "[lindex $left 1][lindex $right 1]"
	    set lt [clex::tokenize $txt "<paste>"]
	    if {[llength $lt] != 1} {
		Error "$where: token pasting produced an invalid token '$txt'"
	    }
	    lset out end [list [lindex $lt 0 0] $txt [lindex $left 2] [lindex $left 3]]
	    continue
	}
	lappend out $t
    }
    return $out
}

# A region of the main file skipped because an #if/#elif/#else evaluated
# false *using assumptions* is recorded by output position, so tables that
# straddle it can report that content was left out under an assumption.
proc ::cpp::NoteSkip {rel} {
    variable S
    if {$rel ne $S(mainRel)} return
    set fr [lindex $S(stack) end]
    if {[dict get $fr active] || ![dict get $fr parentActive]} return
    if {![llength [dict get $fr assumed]]} return
    lappend S(skips) [list [llength $S(out)] [dict get $fr where] [dict get $fr text]  [dict get $fr assumed]]
}
