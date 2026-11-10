# common.tcl -- shared setup for the tkx test files.
#
# Loads the C test bridge (libtkxtest.so/.dylib/.dll, which links libtkx)
# and defines constraints:
#   display   a display is available (wrapper tests need Tk)
#   bridge    the compiled bridge could be loaded
#   tksrc     the pinned Tk/Tcl source trees are available
#   compat    running against a Tk other than the committed 9.1.0 API

package require tcltest 2.5
namespace import -force tcltest::*

set ::tkx_root [file dirname [file dirname [file normalize [info script]]]]
proc tkx_env {name default} {
    global env
    if {[info exists env($name)] && $env($name) ne ""} { return $env($name) }
    return $default
}
set ::tkx_build [file join $::tkx_root [tkx_env TKX_BUILD build/9.1.0]]
set ::tkx_tk_src [file join $::tkx_root [tkx_env TKX_TK_SRC deps/9.1.0/src/tk9.1.0]]
set ::tkx_tcl_src [file join $::tkx_root [tkx_env TKX_TCL_SRC deps/9.1.0/src/tcl9.1.0]]
set ::tkx_gen_dir [file join $::tkx_root [tkx_env TKX_GEN_DIR .]]

if {![info exists ::tkx_bridge_loaded]} {
    set ::tkx_bridge_loaded [expr {![catch {
	load [file join $::tkx_build libtkxtest[info sharedlibextension]] Tkxtest
    } ::tkx_bridge_error]}]
    if {!$::tkx_bridge_loaded} { puts stderr "tkx: test bridge not loaded: $::tkx_bridge_error" }
}
# A display: X11 needs DISPLAY; Windows and macOS (Aqua) use the desktop
# session.  TKX_NO_DISPLAY=1 forces the headless subset everywhere.
set ::tkx_display_available [expr {$::tkx_bridge_loaded && [tkx_env TKX_NO_DISPLAY 0] ne "1"
	&& ($::tcl_platform(platform) eq "windows" || $::tcl_platform(os) eq "Darwin"
	    || [tkx_env DISPLAY ""] ne "")}]
testConstraint bridge $::tkx_bridge_loaded
testConstraint display $::tkx_display_available
testConstraint tksrc [expr {[file isdirectory $::tkx_tk_src] && [file isdirectory $::tkx_tcl_src]}]
testConstraint tk91 [expr {$::tkx_bridge_loaded && [info exists ::tkx::tk_source_version]
	&& $::tkx::tk_source_version eq "9.1.0"}]

# Run a script; return the tkx status name from the error code, or OK.
proc tkx_status {script} {
    if {[catch {uplevel 1 $script} msg opts]} {
	set ec [dict get $opts -errorcode]
	if {[lindex $ec 0] eq "TKX"} { return [lindex $ec 1] }
	return "TCL: $msg"
    }
    return OK
}

# Start/stop the tkx application used by a test file.
proc tkx_start {args} {
    if {[catch {tkx::main_window}]} {
	tkx::app_init {*}$args
    }
    return [tkx::main_window]
}
proc tkx_stop {} {
    catch {tkx::app_shutdown}
}

proc tkx_settle {} {
    tkx::update_idletasks
    tkx::process_events
    tkx::update_idletasks
}

# Path of a widget (test hook) and evaluation in the app interpreter.
proc tkx_path {id} { tkx::path $id }
proc tkx_tk {args} { tkx::app_eval $args }

# The C compiler used by the ABI tests: $CC, else cc, else gcc.
proc tkx_cc {} {
    set cc [tkx_env CC ""]
    if {$cc ne "" && [auto_execok [lindex $cc 0]] ne ""} { return $cc }
    foreach c {cc gcc clang} { if {[auto_execok $c] ne ""} { return $c } }
    return ""
}
