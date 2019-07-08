#!/usr/bin/env tclsh
package require Tcl              8.5
package require turtles::hashing 0.1

namespace eval ::turtles {
	namespace export release_the_turtles on_proc_enter on_proc_define_add_trace
}

proc ::turtles::on_proc_enter {commandString op} {
	set time_enter [ clock microseconds ]
	# Retrieve the frame two levels down the call stack to avoid
	# confusing with the stack frame for ::turtles::on_proc_enter.
	set execFrame [info frame -2]
	if { [dict exists $execFrame proc] } {
		# Called from within procedure
		set callerName [dict get $execFrame proc]
	} else {
		# Called from top level
		set callerName ""
	}
	# Callee needs to be fully qualified for consistency.
	set calleeName [namespace which -command [dict get $execFrame cmd]]
	# Get hashes on FQFNs for caller and callee.
	set callerId [ ::turtles::hash $callerName ]
	set calleeId [ ::turtles::hash $calleeName ]
	# Record entry into proc.
	puts stderr "\[$time_enter\] ($op) $callerName ($callerId) -> $calleeName ($calleeId)"
}

proc ::turtles::on_proc_leave {commandString code result op} {
	set time_leave [ clock microseconds ]
	# Retrieve the frame two levels down the call stack to avoid
	# confusing with the stack frame for ::turtles::on_proc_leave.
	set execFrame [info frame -2]
	if { [dict exists $execFrame proc] } {
		# Called from within procedure
		set callerName [dict get $execFrame proc]
	} else {
		# Called from top level
		set callerName ""
	}
	# Callee needs to be fully qualified for consistency.
	set calleeName [namespace which -command [dict get $execFrame cmd]]
	# Get hashes on FQFNs for caller and callee.
	set callerId [ ::turtles::hash $callerName ]
	set calleeId [ ::turtles::hash $calleeName ]
	# Record exit from proc.
	puts stderr "\[$time_leave\] ($op) $callerName ($callerId) -> $calleeName ($calleeId)"
}

proc ::turtles::on_proc_define_add_trace {commandString code result op} {
	# Proc name needs to be fully qualified for consistency.
	set procName [namespace which -command [lindex [split $commandString { }] 1]]
	# Add handler for proc entry.
	if { [ catch { trace add execution $procName [list enter] ::turtles::on_proc_enter } err ] } {
		puts "Failed to add enter trace for $procName : $err"
	}
	# Add handler for proc exit.
	if { [ catch { trace add execution $procName [list leave] ::turtles::on_proc_leave } err ] } {
		puts "Failed to add leave trace for $procName : $err"
	}
}

proc ::turtles::release_the_turtles {} {
	trace add execution proc [list leave] ::turtles::on_proc_define_add_trace
}

package provide turtles          0.1
