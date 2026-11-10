# json.tcl --
#
#	Minimal deterministic JSON writer for the generator's reports.
#	Values are described with explicit type tags so output never depends
#	on Tcl's internal value representation:
#	    {obj {key value ...}}   object (keys emitted in the given order)
#	    {arr {value ...}}       array
#	    {str text}              string
#	    {num n}                 number
#	    {bool 0|1}              boolean
#	    null                    null

namespace eval ::tkx::json {}

proc ::tkx::json::quote {s} {
    set out "\""
    foreach ch [split $s ""] {
	scan $ch %c c
	if {$ch eq "\""} { append out "\\\"" } elseif {$ch eq "\\"} {
	    append out "\\\\"
	} elseif {$c == 10} { append out "\\n" } elseif {$c == 9} {
	    append out "\\t"
	} elseif {$c == 13} { append out "\\r" } elseif {$c < 32} {
	    append out [format "\\u%04x" $c]
	} else { append out $ch }
    }
    append out "\""
}

proc ::tkx::json::write {v {indent ""}} {
    set tag [lindex $v 0]
    switch -- $tag {
	null { return null }
	str { return [quote [lindex $v 1]] }
	num { return [lindex $v 1] }
	bool { return [expr {[lindex $v 1] ? "true" : "false"}] }
	arr {
	    set items [lindex $v 1]
	    if {![llength $items]} { return {[]} }
	    set in "$indent  "
	    set parts {}
	    foreach it $items { lappend parts "$in[write $it $in]" }
	    return "\[\n[join $parts ",\n"]\n$indent\]"
	}
	obj {
	    set kv [lindex $v 1]
	    if {![llength $kv]} { return "{}" }
	    set in "$indent  "
	    set parts {}
	    foreach {k val} $kv { lappend parts "$in[quote $k]: [write $val $in]" }
	    return "\{\n[join $parts ",\n"]\n$indent\}"
	}
	default { error "json: bad value tag '$tag'" }
    }
}

# Convenience constructors.
proc ::tkx::json::s {x} { list str $x }
proc ::tkx::json::n {x} { list num $x }
proc ::tkx::json::b {x} { list bool [expr {$x ? 1 : 0}] }
proc ::tkx::json::strs {xs} {
    set out {}
    foreach x $xs { lappend out [list str $x] }
    list arr $out
}

proc ::tkx::json::obj {kv} { list obj $kv }
