# all.tcl --
#
#	Run the tkx tcltest suite:
#	    tclsh tests/all.tcl ?tcltest options?
#	(normally through "make test", which sets the environment and uses
#	Xvfb when no DISPLAY is available).
#
#	Environment:
#	    TKX_BUILD    build directory holding libtkx / libtkxtest (.so, .dylib, .dll)
#	                 (default build/9.1.0)
#	    TKX_TK_SRC / TKX_TCL_SRC   Tk/Tcl source trees for generator tests
#	    TKX_GEN_DIR  directory of the generated files under test (default .)
#	    DISPLAY      (X11) tests that need a display are skipped without one
#	    TKX_NO_DISPLAY  1: skip the display tests on every platform
#
#	All test files run in this interpreter (-singleproc 1).  The exit
#	status is non-zero if any test failed.  Skipped tests are reported
#	with their constraints and are not counted as passed.

package require tcltest 2.5
namespace import tcltest::*

set here [file dirname [file normalize [info script]]]
configure -testdir $here -singleproc 1 -verbose {body error skip} {*}$argv

set ::tkx_total_failed 0
set ::tkx_total_skipped 0
set ::tkx_total_passed 0
set ::tkx_total_tests 0
proc ::tcltest::cleanupTestsHook {} {
    variable numTests
    # In singleproc mode the counters are cumulative; keep the latest.
    set ::tkx_total_failed $numTests(Failed)
    set ::tkx_total_skipped $numTests(Skipped)
    set ::tkx_total_passed $numTests(Passed)
    set ::tkx_total_tests $numTests(Total)
}

runAllTests

# Behavioural coverage of the generated functions (successful calls).
# Only meaningful when the display tests ran.
if {[namespace exists ::tkx] && [llength [info commands ::tkx::fn_calls]]
	&& [info exists ::tkx_display_available] && $::tkx_display_available} {
    set calls [::tkx::fn_calls]
    set all [::tkx::fnlist]
    set called 0
    foreach fn $all { if {[dict exists $calls $fn]} { incr called } }
    set build [expr {[info exists env(TKX_BUILD)] ? $env(TKX_BUILD) : "build/9.1.0"}]
    set out [file join [file dirname $here] $build behavior_coverage.txt]
    set f [open $out w]
    puts $f "generated_functions [llength $all]"
    puts $f "called_successfully $called"
    foreach fn [lsort $all] {
	puts $f "[expr {[dict exists $calls $fn] ? "CALLED" : "NOT-CALLED"}] $fn"
    }
    close $f
    puts "Generated functions called successfully by the tests: $called / [llength $all] (details: $out)"
}

# The final cleanupTests of runAllTests reports the totals; recompute the
# failure state from the per-file accumulation (the hook also runs for the
# final summary call, whose counts are zero after the reset).
puts "Summary: total $::tkx_total_tests, passed $::tkx_total_passed, skipped $::tkx_total_skipped, failed $::tkx_total_failed"
exit [expr {$::tkx_total_failed > 0 ? 1 : 0}]
