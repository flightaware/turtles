#!/usr/bin/env tclsh
package provide turtles 0.1
package require Tcl     8.5

namespace eval ::turtles {
	namespace export release_the_turtles on_proc_enter on_proc_define_add_trace
}

proc ::turtles::on_proc_enter {commandString op} {
	puts stderr "\[[clock microseconds]\] ($op) [format {%s} $commandString]"
}

proc ::turtles::on_proc_define_add_trace {commandString code result op} {
	set procName [lindex [split $commandString { }] 1]
	catch { trace add execution $procName [list enter] turtles::on_proc_enter }
}

proc ::turtles::release_the_turtles {} {
	trace add execution proc [list leave] ::turtles::on_proc_define_add_trace
}
