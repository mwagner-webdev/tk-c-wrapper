# clex.tcl --
#
#	A small, deterministic C lexer for the tkx source extractor.
#
#	It is not a full C front end.  It recognises exactly the lexical
#	classes that appear in Tk's sources (comments, string/char literals,
#	identifiers, preprocessing numbers, punctuators, newlines and
#	backslash-newline continuations) and groups preprocessor directives
#	into single tokens.  Anything it cannot classify is reported as an
#	error instead of being skipped.
#
#	Token representation (a Tcl list):
#	    {kind text line}
#	kind is one of: id num str chr punct
#	Directive tokens are:
#	    {pp name line argTokens}
#	where argTokens is a list of ordinary tokens following the directive
#	name on the same logical line.

namespace eval ::clex {
    namespace export tokenize lexfile

    # One alternation, no capturing groups.  Tcl AREs choose the longest
    # alternative at a given position, so "//" beats "/" and "..." beats ".".
    # All quantifiers are greedy (mixing greedy and non-greedy quantifiers
    # changes the preference of the whole RE in Tcl).
    variable RE [join {
	{/\*(?:[^*]|\*+[^*/])*\*+/}
	{//[^\n]*}
	{"(?:[^"\\\n]|\\.)*"}
	{'(?:[^'\\\n]|\\.)*'}
	{[A-Za-z_][A-Za-z0-9_]*}
	{\.?[0-9](?:[eEpP][-+]|[0-9A-Za-z_.])*}
	{\\\r?\n}
	{\n}
	{[ \t\r\f\v]+}
	{\.\.\.|<<=|>>=|->|\+\+|--|<<|>>|<=|>=|==|!=|&&|\|\||##|[-+*/%&|^]=}
	{[-+*/%=&|^!~<>?:;,.()\[\]{}#@]}
	{.}
    } |]

    # Cache: file path -> token list (lexing is pure, so this is safe).
    variable cache [dict create]
}

# clex::lexfile --
#	Read a file (UTF-8, as Tk's sources are) and tokenize it, with caching.
proc ::clex::lexfile {path {label ""}} {
    variable cache
    if {[dict exists $cache $path]} {
	return [dict get $cache $path]
    }
    if {$label eq ""} { set label $path }
    set f [open $path r]
    fconfigure $f -encoding utf-8 -translation lf -profile strict
    set src [read $f]
    close $f
    set toks [tokenize $src $label]
    dict set cache $path $toks
    return $toks
}

# clex::tokenize --
#	Convert C source text into a token list (see header comment).
#	Errors are raised as  CLEX <file>:<line>: <message>.
proc ::clex::tokenize {src {label "<string>"}} {
    variable RE
    set out {}
    set line 1
    set bol 1		;# at beginning of logical line (only ws/comments so far)
    set inpp 0		;# collecting a directive
    set ppname ""
    set ppline 0
    set ppargs {}
    set ppHaveName 0
    set ws 1		;# whitespace (or line start) precedes the current token
    foreach range [regexp -all -inline -indices -- $RE $src] {
	lassign $range s e
	set text [string range $src $s $e]
	set c [string index $text 0]
	set tokline $line
	if {[string range $text 0 1] in {/* //}} {
	    # Comment: acts as whitespace; count embedded newlines.
	    incr line [regexp -all {\n} $text]
	    set ws 1
	    continue
	}
	if {$text eq "\\\n" || $text eq "\\\r\n"} {
	    # Line continuation: whitespace, does not end a directive.
	    incr line
	    set ws 1
	    continue
	}
	if {$text eq "\n"} {
	    incr line
	    if {$inpp} {
		lappend out [list pp $ppname $ppline $ppargs]
		set inpp 0
	    }
	    set bol 1
	    set ws 1
	    continue
	}
	if {[string is space -strict $text]} {
	    set ws 1
	    continue
	}
	set prevws $ws
	set ws 0
	if {$c eq "\""} {
	    set kind str
	    incr line [regexp -all {\n} $text]
	} elseif {$c eq "'"} {
	    set kind chr
	} elseif {[string match {[A-Za-z_]*} $text]} {
	    set kind id
	} elseif {[regexp {^\.?[0-9]} $text]} {
	    set kind num
	} elseif {[regexp {^(?:\.\.\.|<<=|>>=|->|\+\+|--|<<|>>|<=|>=|==|!=|&&|\|\||##|[-+*/%&|^]=|[-+*/%=&|^!~<>?:;,.()\[\]{}#@])$} $text]} {
	    set kind punct
	} else {
	    # An unterminated literal or a character C does not allow here.
	    if {$c eq "\"" || $c eq "'"} {
		return -code error "CLEX $label:$tokline: unterminated literal"
	    }
	    scan $c %c cp
	    return -code error [format "CLEX %s:%d: unexpected character U+%04X" \
		    $label $tokline $cp]
	}
	if {$bol && $kind eq "punct" && $text eq "#"} {
	    set inpp 1
	    set ppHaveName 0
	    set ppname ""
	    set ppline $tokline
	    set ppargs {}
	    set bol 0
	    continue
	}
	set bol 0
	if {$inpp} {
	    if {!$ppHaveName} {
		set ppHaveName 1
		if {$kind eq "id"} {
		    set ppname $text
		    continue
		}
		# "# 123" line markers or null directives: keep as name "".
	    }
	    lappend ppargs [list $kind $text $tokline $prevws]
	    continue
	}
	lappend out [list $kind $text $tokline]
    }
    if {$inpp} {
	lappend out [list pp $ppname $ppline $ppargs]
    }
    return $out
}

# clex::strvalue --
#	Decode a C string literal token text (including quotes) into its
#	value.  Only the escapes that occur in Tk's sources plus the standard
#	single-character escapes are accepted; anything else is an error.
proc ::clex::strvalue {text {where ""}} {
    if {![regexp {^"(.*)"$} $text -> body]} {
	return -code error "CLEX $where: not a string literal: $text"
    }
    set out ""
    set n [string length $body]
    for {set i 0} {$i < $n} {incr i} {
	set ch [string index $body $i]
	if {$ch ne "\\"} {
	    append out $ch
	    continue
	}
	incr i
	set ch [string index $body $i]
	switch -- $ch {
	    n { append out \n }
	    t { append out \t }
	    r { append out \r }
	    0 { append out \0 }
	    a { append out \a }
	    b { append out \b }
	    f { append out \f }
	    v { append out \v }
	    \\ { append out \\ }
	    \" { append out \" }
	    ' { append out ' }
	    ? { append out ? }
	    \n { }
	    x {
		if {![regexp -start [expr {$i+1}] {\A[0-9A-Fa-f]+} $body hex]} {
		    return -code error "CLEX $where: bad \\x escape"
		}
		append out [format %c [expr {"0x$hex"}]]
		incr i [string length $hex]
	    }
	    u - U {
		set len [expr {$ch eq "u" ? 4 : 8}]
		set hex [string range $body [expr {$i+1}] [expr {$i+$len}]]
		if {![regexp {^[0-9A-Fa-f]+$} $hex] || [string length $hex] != $len} {
		    return -code error "CLEX $where: bad \\$ch escape"
		}
		append out [format %c [expr {"0x$hex"}]]
		incr i $len
	    }
	    default {
		return -code error "CLEX $where: unsupported escape \\$ch in string literal"
	    }
	}
    }
    return $out
}
