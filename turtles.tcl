#!/usr/bin/env tclsh

## \file turtles.tcl
# turtles (Tcl Universal Recursive Trace Log Execution Scrutinizer) is a Tcl
# library package that provides a mechanism for instrumenting code for
# analysis with respect to call graphs, timing, and more.
#

package require Tcl                  8.5 8.6
lappend auto_path "/usr/local/opt/tclx/lib"
package require Tclx
package require Thread
package require turtles::hashing     0.1
package require turtles::persistence::mt 0.1
package require turtles::persistence::ev 0.1

## The package namespace.
namespace eval ::turtles {
	namespace export release_the_turtles capture_the_turtles
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
	# Avoid unnecessary recursive descent.
	if { [ regexp {^::turtles::} $callerName ] } { return }
	# Callee needs to be fully qualified for consistency.
	set calleeCmd [dict get $execFrame cmd]
	regsub {^([{][*][}])?(\S+)\s+.*$} $calleeCmd {\2} rawCalleeName
	set calleeName [uplevel namespace which -command [uplevel subst $rawCalleeName]]
	# Get hashes on FQFNs for caller and callee.
	set callerId [ ::turtles::hashing::hash_string $callerName ]
	set calleeId [ ::turtles::hashing::hash_string $calleeName ]
	regsub {tid} [ thread::id ] {} threadId
	set srcLine  [ dict get $execFrame line]
	set stackLvl [ uplevel { info level } ]
	# Set the unique trace ID for this exact call point.
	# The trace ID is a hash of the current thread, stack level, caller, source line, and callee.
	set traceId [ ::turtles::hashing::hash_int_list [list $threadId $stackLvl $callerId $srcLine $calleeId] ]
	# Set time of entry as close to function entry as possible to avoid adding overhead to accounting.
	set timeEnter [ clock microseconds ]
	# Record entry into proc.
	if { [info exists ::turtles::debug] } {
		puts stderr "\[$timeEnter:$op:$traceId\] $callerName ($callerId) -> $calleeName ($calleeId) \{$rawCalleeName\}"
	}
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
	# Avoid unnecessary recursive descent.
	if { [ regexp {^::turtles::} $callerName ] } { return }
	# Callee needs to be fully qualified for consistency.
	set calleeCmd [dict get $execFrame cmd]
	regsub {^([{][*][}])?(\S+)\s+.*$} $calleeCmd {\2} rawCalleeName
	set calleeName [uplevel namespace which -command [uplevel subst $rawCalleeName]]
	# Get hashes on FQFNs for caller and callee.
	set callerId [ ::turtles::hashing::hash_string $callerName ]
	set calleeId [ ::turtles::hashing::hash_string $calleeName ]
	regsub {tid} [ thread::id ] {} threadId
	set srcLine  [ dict get $execFrame line]
	set stackLvl [ uplevel { info level } ]
	# The trace ID is a hash of the current thread, stack level, caller, source line, and callee.
	set traceId [ ::turtles::hashing::hash_int_list [list $threadId $stackLvl $callerId $srcLine $calleeId] ]
	# Record exit from proc.
	if { [info exists ::turtles::debug] } {
		puts stderr "\[$timeLeave:$op:$traceId\] $callerName ($callerId) -> $calleeName ($calleeId) \{$rawCalleeName\}"
	}
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
			::turtles::add_proc_trace $procName
			if [info exists ::turtles::debug] {
				puts "on_proc_define_add_trace: $procName"
			}
		}
	}
}

## Helper doing the actual work of adding a proc trace for a given proc.
#
# This is called by the handler \c ::turtles::on_proc_define_add_trace.
# It does the actual work of setting up the proc entry and exit handlers.
#
# \param[in] procName the name of the proc to instrument
proc ::turtles::add_proc_trace {procName} {
	# Calculate the proc ID hash and set the time defined.
	set procId [::turtles::hashing::hash_string $procName]
	set timeDefined [clock microseconds]
	# Add the proc ID hash to the lookup table and the list of traced procs.
	::turtles::persistence::add_proc_id $procId $procName $timeDefined
	lappend ::turtles::tracedProcs $procName
	# Add handler for proc entry.
	if { [ catch { trace add execution $procName [list enter] ::turtles::on_proc_enter } err ] } {
		puts stderr "Failed to add enter trace for '$procName' [info commands $procName] \{$commandString\}: $err"
	} else {
		# Add handler for proc exit iff the handler for entry was successfully installed.
		if { [ catch { trace add execution $procName [list leave] ::turtles::on_proc_leave } err ] } {
			puts stderr "Failed to add leave trace for '$procName' [info commands $procName] \{$commandString\}: $err"
		}
	}
}

## User-level convenience function for triggering automatic \c proc instrumentation.
#
# This function binds to the \c proc command so that any proc declared after invocation
# will have the entry and exit handlers bound to it.
#
# The necessary arguments to \c ::turtles::persistence::start are exposed here as pass-through arguments.
#
# \param[in] commitMode the mode for persistence (\c staged | \c direct) [default: \c staged]
# \param[in] intervalMillis the number of milliseconds between stage transfers [default: 30000]
# \param[in] dbPath the path where the finalized persistence is stored as a sqlite DB [default: ./]
# \param[in] dbPrefix the filename prefix of the finalized persistence is stored as a sqlite DB. The PID and .db extension are appended [default: turtles]
# \param[in] mode the scheduling mode (\c mt | \c ev)
proc ::turtles::release_the_turtles {{commitMode staged} {intervalMillis 30000} {dbPath {./}} {dbPrefix {turtles}} {mode mt}} {

	# Initialize the ghost namespace based on the given or implicit mode parameter.
	namespace eval ::turtles::persistence {
		namespace import ::turtles::persistence::[uplevel { subst {$mode} }]::*
		namespace export *
	}

	proc ::turtles::pre_fork {commandString op} {
		::turtles::persistence::stop
	}

	eval [subst {
		proc ::turtles::post_fork {commandString result code op} {
			::turtles::persistence::start $commitMode $intervalMillis $dbPath $dbPrefix
		}
	}]

	# Add guards for forking.
	trace add execution {fork} [list enter] ::turtles::pre_fork
	trace add execution {fork} [list leave] ::turtles::post_fork


	# Start the persistence mechanism now so it's ready once the hooks are added. Sinks before sources!
	::turtles::persistence::start $commitMode $intervalMillis $dbPath $dbPrefix

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
	# Add a trigger for the proc command to add a handler for the newly defined proc.
	trace add execution {proc} [list leave] ::turtles::on_proc_define_add_trace
}

## User-level convenience function for ending automatic \c proc instrumentation
# as initiated by \c ::turtles::release_the_turtles.
#
# NB: This function removes all the trace hooks before stopping the persistence mechanism.
proc ::turtles::capture_the_turtles {} {
	# Remove the trace hooks.
	trace remove execution {proc} [list leave] ::turtles::on_proc_define_add_trace
	trace remove execution {fork} [list enter] ::turtles::pre_fork
	trace remove execution {fork} [list leave] ::turtles::post_fork

	foreach handledProc $::turtles::tracedProcs {
		trace remove execution $handledProc [list enter] ::turtles::on_proc_enter
		trace remove execution $handledProc [list leave] ::turtles::on_proc_leave
	}
	# Undefine the list of traced procs.
	unset ::turtles::tracedProcs
	# Empty the ghost namespace of all functionality.
	::turtles::persistence::stop
	namespace eval ::turtles::persistence {
		namespace forget *
	}
}

package provide turtles          0.1
