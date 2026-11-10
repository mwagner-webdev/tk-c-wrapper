# check.tcl --
#
#	Check mode: regenerate everything into a scratch directory and fail
#	if any generated file differs from the committed one.
#
#	Usage:
#	    tclsh check.tcl --tk-src DIR --tcl-src DIR ?--repo DIR? ?--scratch DIR?
#
#	Exit status: 0 = committed files are up to date, 1 = drift (the
#	differing files and the first differing line of each are printed),
#	2 = usage error, 3 = generation failed.

set here [file dirname [file normalize [info script]]]
source [file join $here generate.tcl]

namespace eval ::tkx::check {
    variable files {
	include/tkx_generated.h
	src/tkx_generated.c
	tests/tkx_bridge_generated.c
	generated/api.json
	generated/coverage.json
    }
}

proc ::tkx::check::ReadFile {path} {
    set f [open $path r]
    fconfigure $f -encoding utf-8 -translation lf
    set s [read $f]
    close $f
    return $s
}

# Returns a list of {file message} for every difference.
proc ::tkx::check::Compare {repo scratch} {
    variable files
    set problems {}
    foreach rel $files {
	set a [file join $repo $rel]
	set b [file join $scratch $rel]
	if {![file exists $a]} {
	    lappend problems [list $rel "missing in repository"]
	    continue
	}
	set sa [ReadFile $a]
	set sb [ReadFile $b]
	if {$sa eq $sb} continue
	set la [split $sa \n]
	set lb [split $sb \n]
	set n [expr {max([llength $la], [llength $lb])}]
	for {set i 0} {$i < $n} {incr i} {
	    if {[lindex $la $i] ne [lindex $lb $i]} {
		lappend problems [list $rel "line [expr {$i+1}]:\n  committed: [lindex $la $i]\n  generated: [lindex $lb $i]"]
		break
	    }
	}
    }
    return $problems
}

proc ::tkx::check::run {tk tcl repo scratch} {
    file delete -force $scratch
    file mkdir $scratch
    ::tkx::gen::run $tk $tcl $scratch
    return [Compare $repo $scratch]
}

if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    array set opt [list --tk-src "" --tcl-src "" --repo [file dirname $here] \
	    --scratch [file join [file dirname $here] build check]]
    array set opt $argv
    if {$opt(--tk-src) eq "" || $opt(--tcl-src) eq ""} {
	puts stderr "usage: check.tcl --tk-src DIR --tcl-src DIR ?--repo DIR? ?--scratch DIR?"
	exit 2
    }
    if {[catch {::tkx::check::run $opt(--tk-src) $opt(--tcl-src) $opt(--repo) $opt(--scratch)} problems]} {
	puts stderr "generation failed: $problems"
	exit 3
    }
    if {[llength $problems]} {
	puts stderr "generated files differ from the committed ones (run 'make generate' and review):"
	foreach p $problems { puts stderr "  [lindex $p 0]: [lindex $p 1]" }
	exit 1
    }
    puts "generated files are up to date"
}
