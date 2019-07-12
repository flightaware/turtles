#!/usr/bin/env tclsh

## \file turtles.tcl
# turtles (Tcl Universal Recursive Trace Log Execution Scrutinizer) is a Tcl
# library package that provides a mechanism for instrumenting code for
# analysis with respect to call graphs, timing, and more.
#

package require Tcl                  8.5 8.6
package require struct               1.3
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
	set calleeCmd [string trimleft [dict get $execFrame cmd] \{]
	regsub {^(\S+)\s+.*$} $calleeCmd {\1} rawCalleeName
	set calleeName [uplevel namespace which -command $rawCalleeName]
	# Get hashes on FQFNs for caller and callee.
	set callerId [ ::turtles::hashing::hash_string $callerName ]
	set calleeId [ ::turtles::hashing::hash_string $calleeName ]
	# Set time of entry as close to function entry as possible to avoid adding overhead to accounting.
	set timeEnter [ clock microseconds ]
	# Set the unique trace ID for this exact call point.
	# The trace ID is a hash of the caller, callee, and time of entry.
	# This is pushed onto a stack so that the corresponding leave handler must pop this.
	set traceId [ ::turtles::hashing::hash_int_list [list $callerId $calleeId $timeEnter] ]
	::turtles::traceIds push $traceId
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
	set traceId [::turtles::traceIds pop ]
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
	set calleeCmd [string trimleft [dict get $execFrame cmd] \{]
	regsub {^(\S+)\s+.*$} $calleeCmd {\1} rawCalleeName
	set calleeName [uplevel namespace which -command $rawCalleeName]
	# Get hashes on FQFNs for caller and callee.
	set callerId [ ::turtles::hashing::hash_string $callerName ]
	set calleeId [ ::turtles::hashing::hash_string $calleeName ]
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
	set isProcDef [regsub {^proc\s+(\S+).*$} $commandString {\1} rawProcName]
	# Proceed only if the command string is a proc def.
	if { $isProcDef } {
		# Attempt name resolution.
		set procName [uplevel namespace which -command $rawProcName]
		# Proceed only if we can resolve the proc name.
		if { $procName ne {} } {
			# Calculate the proc ID hash and set the time defined.
			set procId [::turtles::hashing::hash_string $procName]
			set timeDefined [clock microseconds]
			# Add the proc ID hash to the lookup table and the list of traced procs.
			::turtles::persistence::add_proc_id $procId $procName $timeDefined
			lappend ::turtles::tracedProcs $procName
			# Add handler for proc entry.
			if { [ catch { trace add execution $procName [list enter] ::turtles::on_proc_enter } err ] } {
				puts stderr "Failed to add enter trace for '$procName' [info commands $procName] \{$commandString\}: $err"
			}
			# Add handler for proc exit.
			if { [ catch { trace add execution $procName [list leave] ::turtles::on_proc_leave } err ] } {
				puts stderr "Failed to add leave trace for '$procName' [info commands $procName] \{$commandString\}: $err"
			}
		}
	}
}

## User-level convenience function for triggering automatic \c proc instrumentation.
#
# This function binds to the \c proc command so that any proc declared after invocation
# will have the entry and exit handlers bound to it.
proc ::turtles::release_the_turtles {} {
	# Start the persistence mechanism now so it's ready once the hooks are added.
	::turtles::persistence::start "turtles-[clock microseconds].db"

	# Bootstrap the proc IDs for the ::turtles namespace and its children
	# so that the standard views make sense.
	foreach procName [ concat \
						   [info procs ::turtles::*] \
						   [info procs ::turtles::hashing::*] \
						   [info procs ::turtles::persistence::*] ] {
		# Calculate the proc ID hash and set the time defined.
		set procId [::turtles::hashing::hash_string $procName]
		set timeDefined [clock microseconds]
		# Add the proc ID hash to the lookup table and the list of traced procs.
		::turtles::persistence::add_proc_id $procId $procName $timeDefined
	}

	# Initialize an empty list of procs being traced.
	set ::turtles::tracedProcs [list]
	# Create a stack for keeping track of trace IDs during execution.
	::struct::stack ::turtles::traceIds
	trace add execution proc [list leave] ::turtles::on_proc_define_add_trace
}

## User-level convenience function for ending automatic \c proc instrumentation
# as initiated by \c ::turtles::release_the_turtles.
#
# NB: This function removes all the trace hooks before stopping the persistence mechanism.
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
