#!/usr/bin/env tclsh

## \file turtles.tcl
# turtles (Tcl Universal Recursive Trace Log Execution Scrutinizer) is a Tcl
# library package that provides a mechanism for instrumenting code for
# analysis with respect to call graphs, timing, and more.
#

package require Tcl                  8.5
package require turtles::hashing     0.1
package require turtles::persistence 0.1

## The package namespace.
namespace eval ::turtles {
	namespace export release_the_turtles on_proc_enter on_proc_define_add_trace
}

## Handler for proc entry.
#
# Note that this handler is triggered _before_ the proc has started execution.
# \param[in] commandString the command string to be executed
# \param[in] op the operation (in this case, \c enter).
proc ::turtles::on_proc_enter {commandString op} {
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
	set callerId [ ::turtles::hashing::hash_string $callerName ]
	set calleeId [ ::turtles::hashing::hash_string $calleeName ]
	set traceId 0
	# Set time of entry as close to function entry as possible to avoid adding overhead to accounting.
	set timeEnter [ clock microseconds ]
	# Record entry into proc.
	puts stderr "\[$timeEnter\] ($op) $callerName ($callerId) -> $calleeName ($calleeId)"
	::turtles::persistence::add_call $callerId $calleeId $traceId $timeEnter
}

## Handler for proc exit.
#
# Note that this handler is triggered _after_ the proc has finished execution.
# \param[in] commandString the executed command string
# \param[in] code the result code from the executed command
# \param[in] result the result string from the executed command
# \param[in] op the operation (in this case, \c leave).
proc ::turtles::on_proc_leave {commandString code result op} {
	# Set time of exit as close to function exit as possible to avoid adding overhead to accounting.
	set timeLeave [ clock microseconds ]
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
	set callerId [ ::turtles::hashing::hash_string $callerName ]
	set calleeId [ ::turtles::hashing::hash_string $calleeName ]
	set traceId 0
	# Record exit from proc.
	puts stderr "\[$timeLeave\] ($op) $callerName ($callerId) -> $calleeName ($calleeId)"
	::turtles::persistence::update_call $callerId $calleeId $traceId $timeLeave
}

## Handler for injecting entry and exit handlers.
#
# This is attached to the \c proc command by \c ::turtles::release_the_turtles.
#
# Invocations of the \c proc command trigger a binding of
# \c ::turtles::on_proc_enter and \c ::turtles::on_proc_leave
# to the defined proc.
# \param[in] commandString the executed command string
# \param[in] code the result code from the executed command
# \param[in] result the result string from the executed command
# \param[in] op the operation (in this case, \c leave).
proc ::turtles::on_proc_define_add_trace {commandString code result op} {
	# Proc name needs to be fully qualified for consistency.
	set procName [namespace which -command [lindex [split $commandString { }] 1]]
	set procId [::turtles::hashing::hash_string $procName]
	set timeDefined [clock microseconds]
	::turtles::persistence::add_proc_id $procId $procName $timeDefined
	lappend ::turtles::tracedProcs $procName
	# Add handler for proc entry.
	if { [ catch { trace add execution $procName [list enter] ::turtles::on_proc_enter } err ] } {
!		puts stderr "Failed to add enter trace for $procName : $err"
	}
	# Add handler for proc exit.
	if { [ catch { trace add execution $procName [list leave] ::turtles::on_proc_leave } err ] } {
		puts stderr "Failed to add leave trace for $procName : $err"
	}
}

## User-level convenience function for triggering automatic \c proc instrumentation.
#
# This function binds to the \c proc command so that any proc declared after invocation
# will have the entry and exit handlers bound to it.
proc ::turtles::release_the_turtles {} {
	::turtles::persistence::start "turtles-[clock microseconds].db"
	set ::turtles::tracedProcs [list]
	trace add execution proc [list leave] ::turtles::on_proc_define_add_trace
}

proc ::turtles::capture_the_turtles {} {
	trace remove execution proc [list leave] ::turtles::on_proc_define_add_trace
	foreach handledProc $::turtles::tracedProcs {
		trace remove execution $handledProc [list enter] ::turtles::on_proc_enter
		trace remove execution $handledProc [list leave] ::turtles::on_proc_leave
	}
	unset ::turtles::tracedProcs
	::turtles::persistence::stop
}

package provide turtles          0.1
