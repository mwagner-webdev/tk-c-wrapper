# cparse.tcl --
#
#	Constrained declaration indexer and initializer parser.
#
#	This is deliberately not a C parser.  It recognises the handful of
#	declaration shapes that carry Tk's widget interface:
#
#	  * initialised objects:    <type> NAME [ [...] ] = { ... } ;
#	  * function definitions:   ... NAME ( ... ) { ... }
#	  * enum definitions:       [typedef] enum [TAG] { ... } [NAME] ;
#	  * struct definitions:     [typedef] struct [TAG] { ... } [NAME] ;
#	  * struct typedefs:        typedef struct TAG NAME ;
#
#	at file scope, plus local initialised arrays and enums inside function
#	bodies.  Brace/paren/bracket nesting is tracked exactly on the token
#	stream produced by clex/cpp, so comments, strings and macros cannot
#	confuse it.  Constructs inside an initializer that it does not
#	understand (designated initializers, compound literals) raise errors.

namespace eval ::cparse {}

proc ::cparse::Error {msg} {
    return -code error -errorcode {CPARSE} "CPARSE $msg"
}

proc ::cparse::tx {toks i} { lindex $toks $i 1 }

# Find the index of the token matching the opener at index i.
proc ::cparse::match {toks i} {
    set open [lindex $toks $i 1]
    set close [dict get {( ) [ ] \{ \}} $open]
    set depth 0
    set n [llength $toks]
    for {set j $i} {$j < $n} {incr j} {
	set t [lindex $toks $j]
	if {[lindex $t 0] ne "punct"} continue
	set x [lindex $t 1]
	if {$x eq $open} { incr depth } elseif {$x eq $close} {
	    incr depth -1
	    if {$depth == 0} { return $j }
	}
    }
    Error "line [lindex $toks $i 2]: unbalanced '$open'"
}

# cparse::index --
#	Index a token list.  file is used for provenance only.
#	stmtEnd, if given, is a command prefix called as {*}$stmtEnd name pos
#	for identifiers at file scope; it returns 1 when the identifier is a
#	macro whose expansion terminates a statement (ends with ';' or '}'),
#	e.g. ttk's TTK_END_LAYOUT.  Such macros otherwise leave statement
#	boundaries invisible in the unexpanded token stream.
proc ::cparse::index {toks file {stmtEnd {}}} {
    set decls {}
    set funcs [dict create]
    set enums {}
    set structs [dict create]
    set typedefs [dict create]
    set n [llength $toks]
    set start 0
    for {set i 0} {$i < $n} {incr i} {
	set t [lindex $toks $i]
	set x [lindex $t 1]
	if {[lindex $t 0] eq "id" && [llength $stmtEnd]} {
	    if {[{*}$stmtEnd $x $i]} {
		# Skip a function-like macro's argument list too.
		if {[tx $toks $i+1] eq "("} { set i [match $toks [expr {$i+1}]] }
		set start [expr {$i+1}]
	    }
	    continue
	}
	if {[lindex $t 0] ne "punct"} continue
	if {$x eq "("} { set i [match $toks $i]; continue }
	if {$x eq "\["} { set i [match $toks $i]; continue }
	if {$x eq ";"} {
	    set stmt [lrange $toks $start $i-1]
	    # typedef struct TAG NAME ;
	    if {[llength $stmt] == 4 && [tx $stmt 0] eq "typedef"
		    && [tx $stmt 1] in {struct union}} {
		dict set typedefs [tx $stmt 3] [tx $stmt 2]
	    }
	    set start [expr {$i+1}]
	    continue
	}
	if {$x eq "\{"} {
	    set close [match $toks $i]
	    set stmt [lrange $toks $start $i-1]
	    set prev [tx $toks $i-1]
	    set line [lindex $toks $start 2]
	    if {$prev eq "="} {
		set d [DeclHead $stmt $file]
		dict set d scope ""
		dict set d initStart $i
		dict set d initEnd $close
		dict set d line $line
		dict set d cond [lindex $toks $i 3]
		lappend decls $d
		# Skip to the terminating ';'.
		set i $close
		continue
	    }
	    set words {}
	    foreach s $stmt { lappend words [lindex $s 1] }
	    if {"enum" in $words && "(" ni $words} {
		set e [ParseEnum $toks $start $i $close $file]
		dict set e scope ""
		lappend enums $e
		set i $close
		continue
	    }
	    if {("struct" in $words || "union" in $words) && "(" ni $words} {
		set tagIdx [lsearch -exact $words struct]
		if {$tagIdx < 0} { set tagIdx [lsearch -exact $words union] }
		set tag [lindex $words $tagIdx+1]
		set fields [ParseFields [lrange $toks $i+1 $close-1] $file]
		# Optional typedef name after the closing brace.
		set after [tx $toks $close+1]
		set entry [dict create fields $fields line $line file $file]
		if {$tag ne "" && $tag ne "\{"} { dict set structs $tag $entry }
		if {[lindex $words 0] eq "typedef" && $after ne ";"} {
		    dict set structs $after $entry
		}
		set i $close
		continue
	    }
	    if {$prev eq ")"} {
		# Function definition: NAME ( params ) { body }
		set depth 0
		for {set k [expr {$i-1}]} {$k >= $start} {incr k -1} {
		    set y [tx $toks $k]
		    if {$y eq ")"} { incr depth }
		    if {$y eq "("} { incr depth -1; if {$depth == 0} break }
		}
		set name [tx $toks $k-1]
		if {[lindex $toks $k-1 0] ne "id"} {
		    Error "$file:$line: cannot determine function name"
		}
		dict set funcs $name [dict create bodyStart $i bodyEnd $close \
			paramStart $k line [lindex $toks $k-1 2] file $file]
		# Local initialised arrays and enums.
		foreach ld [LocalDecls $toks $i $close $name $file] {
		    if {[dict get $ld what] eq "enum"} {
			lappend enums $ld
		    } else {
			lappend decls $ld
		    }
		}
		set i $close
		set start [expr {$i+1}]
		continue
	    }
	    # Unknown braced construct at file scope: skip it as a unit.
	    set i $close
	    continue
	}
    }
    return [dict create decls $decls funcs $funcs enums $enums \
	    structs $structs typedefs $typedefs]
}

# DeclHead --
#	Analyse "<type tokens> NAME [ [...] ] =" and return
#	{name type array}.
proc ::cparse::DeclHead {stmt file} {
    if {[tx $stmt end] ne "="} {
	Error "$file: internal: DeclHead without '='"
    }
    set k [expr {[llength $stmt]-2}]
    set array 0
    if {[tx $stmt $k] eq "\]"} {
	set array 1
	while {$k >= 0 && [tx $stmt $k] ne "\["} { incr k -1 }
	incr k -1
    }
    set nameTok [lindex $stmt $k]
    if {[lindex $nameTok 0] ne "id"} {
	Error "$file:[lindex $nameTok 2]: unsupported declarator before initializer"
    }
    set type {}
    foreach s [lrange $stmt 0 $k-1] { lappend type [lindex $s 1] }
    return [dict create name [lindex $nameTok 1] type $type array $array what decl]
}

proc ::cparse::LocalDecls {toks bodyStart bodyEnd func file} {
    set out {}
    for {set i [expr {$bodyStart+1}]} {$i < $bodyEnd} {incr i} {
	set x [tx $toks $i]
	if {$x eq "enum" && [lindex $toks $i 0] eq "id"} {
	    set j [expr {$i+1}]
	    if {[lindex $toks $j 0] eq "id"} { incr j }
	    if {[tx $toks $j] eq "\{"} {
		set close [match $toks $j]
		set e [ParseEnum $toks $i $j $close $file]
		dict set e scope $func
		lappend out $e
		set i $close
	    }
	    continue
	}
	if {$x eq "=" && [tx $toks $i+1] eq "\{"} {
	    # Walk back to the start of the declaration.
	    set k [expr {$i-1}]
	    while {$k > $bodyStart && [tx $toks $k] ni {; \{ \}}} { incr k -1 }
	    set stmt [lrange $toks $k+1 $i]
	    set close [match $toks [expr {$i+1}]]
	    set d [DeclHead $stmt $file]
	    dict set d scope $func
	    dict set d initStart [expr {$i+1}]
	    dict set d initEnd $close
	    dict set d line [lindex $toks $k+1 2]
	    dict set d cond [lindex $toks $i 3]
	    lappend out $d
	    set i $close
	}
    }
    return $out
}

# ParseEnum --
#	Members of an enum whose '{' is at index open.
proc ::cparse::ParseEnum {toks start open close file} {
    set words {}
    foreach s [lrange $toks $start $open-1] { lappend words [lindex $s 1] }
    set ei [lsearch -exact $words enum]
    set tag [lindex $words $ei+1]
    set typedefName ""
    if {[lindex $words 0] eq "typedef" && [tx $toks $close+1] ne ";"} {
	set typedefName [tx $toks $close+1]
    }
    set members {}
    set cur {}
    set body [lrange $toks $open+1 $close-1]
    lappend body [list punct , 0]
    set depth 0
    foreach t $body {
	set x [lindex $t 1]
	if {$x eq "(" } { incr depth }
	if {$x eq ")" } { incr depth -1 }
	if {$x eq "," && $depth == 0} {
	    if {[llength $cur]} {
		set nm [lindex $cur 0]
		if {[lindex $nm 0] ne "id"} {
		    Error "$file:[lindex $nm 2]: malformed enum member"
		}
		set value {}
		if {[tx $cur 1] eq "="} {
		    foreach v [lrange $cur 2 end] { lappend value [lindex $v 1] }
		} elseif {[llength $cur] > 1} {
		    Error "$file:[lindex $nm 2]: malformed enum member"
		}
		lappend members [dict create name [lindex $nm 1] value $value \
			line [lindex $nm 2]]
	    }
	    set cur {}
	    continue
	}
	lappend cur $t
    }
    return [dict create what enum tag $tag typedef $typedefName \
	    members $members line [lindex $toks $start 2] file $file]
}

# ParseFields --
#	Field names of a struct body, in declaration order.
proc ::cparse::ParseFields {body file} {
    set fields {}
    set cur {}
    set n [llength $body]
    for {set i 0} {$i < $n} {incr i} {
	set t [lindex $body $i]
	set x [lindex $t 1]
	if {$x eq "\{" } {
	    # Nested struct/union member: skip its body.
	    set j [match $body $i]
	    set i $j
	    lappend cur [list punct NESTED [lindex $t 2]]
	    continue
	}
	if {$x eq "(" || $x eq "\["} {
	    set j [match $body $i]
	    lappend cur {*}[lrange $body $i $j]
	    set i $j
	    continue
	}
	if {$x eq ";"} {
	    lappend fields {*}[DeclaratorNames $cur $file]
	    set cur {}
	    continue
	}
	lappend cur $t
    }
    return $fields
}

proc ::cparse::DeclaratorNames {toks file} {
    # Split multiple declarators at top-level commas.
    set parts {}
    set cur {}
    set depth 0
    foreach t $toks {
	set x [lindex $t 1]
	if {$x in {( \[}} { incr depth }
	if {$x in {) \]}} { incr depth -1 }
	if {$x eq "," && $depth == 0} { lappend parts $cur; set cur {}; continue }
	lappend cur $t
    }
    lappend parts $cur
    set names {}
    foreach p $parts {
	# Function pointer: ( * NAME ) ( ... )
	set found ""
	set m [llength $p]
	for {set i 0} {$i < $m-2} {incr i} {
	    if {[tx $p $i] eq "(" && [tx $p $i+1] eq "*" && [lindex $p $i+2 0] eq "id"} {
		set found [tx $p $i+2]
		break
	    }
	}
	if {$found eq ""} {
	    # Last identifier outside brackets / before a bit-field colon.
	    set depth 0
	    foreach t $p {
		set x [lindex $t 1]
		if {$x in {( \[}} { incr depth; continue }
		if {$x in {) \]}} { incr depth -1; continue }
		if {$x eq ":" && $depth == 0} break
		if {$depth == 0 && [lindex $t 0] eq "id"} { set found $x }
	    }
	}
	if {$found eq ""} {
	    Error "$file:[lindex $p 0 2]: cannot determine struct member name"
	}
	lappend names $found
    }
    return $names
}

# cparse::parseInit --
#	Parse a brace-enclosed initializer (tokens start with '{' and end
#	with the matching '}') into a tree:
#	    {g {child ...} line}     brace group
#	    {e {tok ...} line}       expression (token list)
proc ::cparse::parseInit {toks file} {
    if {[tx $toks 0] ne "\{" || [tx $toks end] ne "\}"} {
	Error "$file: initializer is not a brace group"
    }
    lassign [ParseGroup $toks 0 $file] tree next
    if {$next != [llength $toks]} {
	Error "$file:[lindex $toks $next 2]: trailing tokens after initializer"
    }
    return $tree
}

proc ::cparse::ParseGroup {toks i file} {
    set line [lindex $toks $i 2]
    set children {}
    set close [match $toks $i]
    set j [expr {$i+1}]
    set cur {}
    while {$j < $close} {
	set t [lindex $toks $j]
	set x [lindex $t 1]
	if {[lindex $t 0] eq "punct"} {
	    if {$x eq "\{"} {
		if {[llength $cur]} {
		    Error "$file:[lindex $t 2]: unsupported construct (brace inside expression)"
		}
		lassign [ParseGroup $toks $j $file] g j
		lappend children $g
		set after [tx $toks $j]
		if {$after eq ","} { incr j } elseif {$j != $close} {
		    Error "$file:[lindex $toks $j 2]: expected ',' after brace group"
		}
		continue
	    }
	    if {$x in {( \[}} {
		set k [match $toks $j]
		lappend cur {*}[lrange $toks $j $k]
		set j [expr {$k+1}]
		continue
	    }
	    if {$x eq ","} {
		lappend children [Expr $cur $file]
		set cur {}
		incr j
		continue
	    }
	    if {$x eq "." && [llength $cur] == 0} {
		Error "$file:[lindex $t 2]: designated initializers are not supported"
	    }
	}
	lappend cur $t
	incr j
    }
    if {[llength $cur]} { lappend children [Expr $cur $file] }
    return [list [list g $children $line] [expr {$close+1}]]
}

proc ::cparse::Expr {toks file} {
    if {![llength $toks]} {
	Error "$file: empty initializer element"
    }
    if {[tx $toks 0] eq "\[" } {
	Error "$file:[lindex $toks 0 2]: designated array initializers are not supported"
    }
    return [list e $toks [lindex $toks 0 2]]
}

# Helpers to interpret expression elements -------------------------------

# Is the expression a null pointer constant (NULL or 0)?
proc ::cparse::isNull {e} {
    set toks [lindex $e 1]
    set words {}
    foreach t $toks { lappend words [lindex $t 1] }
    return [expr {$words in {NULL 0 {( void * ) 0} {( ( void * ) 0 )}}}]
}

# String literal value of an expression made of adjacent literals.
proc ::cparse::strValue {e file} {
    set out ""
    foreach t [lindex $e 1] {
	if {[lindex $t 0] ne "str"} {
	    return -code error -errorcode {CPARSE NOTSTRING} \
		    "CPARSE $file:[lindex $t 2]: expected a string literal, found '[lindex $t 1]'"
	}
	append out [clex::strvalue [lindex $t 1] "$file:[lindex $t 2]"]
    }
    return $out
}

proc ::cparse::isString {e} {
    foreach t [lindex $e 1] {
	if {[lindex $t 0] ne "str"} { return 0 }
    }
    return [expr {[llength [lindex $e 1]] > 0}]
}

proc ::cparse::words {e} {
    set w {}
    foreach t [lindex $e 1] { lappend w [lindex $t 1] }
    return $w
}

# Single identifier?
proc ::cparse::ident {e} {
    set toks [lindex $e 1]
    if {[llength $toks] == 1 && [lindex $toks 0 0] eq "id"} {
	return [lindex $toks 0 1]
    }
    return ""
}

# The macro (if any) that produced an expression (origin of first token).
proc ::cparse::origin {e} {
    return [lindex $e 1 0 3]
}
