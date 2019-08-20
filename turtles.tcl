#!/usr/bin/env tclsh

## \file turtles.tcl
# turtles (Tcl Universal Recursive Trace Log Execution Scrutinizer) is a Tcl
# library package that provides a mechanism for instrumenting code for
# analysis with respect to call graphs, timing, and more.
#

package require Tcl                  8.5 8.6
package require Tclx
package require Thread
package require cmdline
package require turtles::hashing         0.1
package require turtles::options         0.1
package require turtles::persistence::mt 0.1
package require turtles::persistence::ev 0.1

## The main user-facing package namespace.
#
# Most users of this library will want to employ the following paradigm:
# \code{.tcl}
# package require turtles
# ::turtles::release_the_turtles ::argv
#
# # code to trace including package imports
#
# ::turtles::capture_the_turtles
# \endcode
#
# Any packages and procs for which the user wishes to collect trace information
# MUST go after the invocation of \c ::turtles::release_the_turtles but
# before the invocation of \c ::turtles::capture_the_turtles.
# The library does not retroactively scan the list of defined procs but rather
# works by adding a trace handler to the \c proc command, which in turn
# adds trace handlers to every proc defined thereafter.
#
# A special handler is added to the \c ::Tclx::fork proc to enable the TURTLES
# system to halt trace info collection prior to forking and resume after the fork
# in both the parent and child.
#
# Trace handling is disabled by default. Any user wishing to enable TURTLES tracing
# will need to add the following command line arguments to the Tcl program invocation:
# \verbatim
#   +TURTLES -enabled -TURTLES
# \endverbatim
#
# All command-line configurable parameters for the TURTLES system must be bracketed
# between \c +TURTLES and \c -TURTLES. These are consumed from the variable name reference
# passed to \c ::turtles::release_the_turtles and excised for any future consumers of
# the variable to make command-line parameter handling implicit and seamless.
#
# The TURTLES system supports two commit modes for trace info: \c staged and \c direct.
# The \c staged mode writes trace info to an in-memory sqlite database which is periodically
# flushed to a persistent sqlite database on disk. In \c direct mode, the trace info
# is written directly to disk. This is configurable by the user via the \c -commitMode
# TURTLES command-line parameter.
#
# The benefit of \c staged mode is that it should be less intrusive to the program execution
# since the writeout to disk only occurs on a configurable interval determined by the
# TURTLES command-line parameter \c -intervalMillis. Following are some sample command-line
# argument snippets:
#
# Staged mode with finalization every 30 seconds (default)
# \verbatim
# +TURTLES -enabled -commitMode staged -TURTLES
# \endverbatim
#
# Staged mode with finalization every 5 seconds
# \verbatim
# +TURTLES -enabled -commitMode staged -intervalMillis 5000 -TURTLES
# \endverbatim
#
# The benefit of \c direct mode is that all trace info up to the point of program exit should be
# available on disk even in the case of unexpected termination at the cost of performance.
# A sample command-line argument snippet:
#
# \verbatim
# +TURTLES -enabled -commitMode direct -TURTLES
# \endverbatim
#
# By default, the finalized persistence database is stored to the current working directory
# with the following name format:
# \verbatim
# turtles-${pid}.db
# \endverbatim
# Both the leading path and base filename prefix can be configured by the \c -dbPath and \c -dbPrefix
# TURTLES command-line arguments, respectively. For instance:
# \verbatim
# +TURTLES -enabled -dbPath /tmp -dbPrefix my_program
# \endverbatim
# would yield a finalized database at /tmp/my_program-${pid}.db. The inclusion of the pid
# is necessary for disambiguation in the case of forking.
#
# The TURTLES system also can operate in one of two scheduling modes, specified by the \c -scheduleMode
# TURTLES command-line argument. The system defaults to \c mt, or multi-threaded, where separate
# threads are launched to handle the actual writing of trace info to the database along with the
# scheduling of the finalization when running in the \c staged commit mode. Since \c ::thread::create
# launches a separate interpreter altogether, the scheduling thread can run independent of the rest
# of the program but still use its own Tcl event loop to evoke periodic behavior.
#
# For most use cases in simple programs, this is sufficient, but the model does not support forking
# since forks and threads don't mix. Once forked, the recorder and scheduler thread are rendered
# moribund. To overcome this issue, the \c ev, i.e., event-loop, mode was developed. The tacit
# assumption of this scheduling mode is that the program will sometime later enter the Tcl event
# loop and permit the finalizer to schedule its periodic updates using the \c after command.
#
# The user should note that the support under forking is not impeccable and may suffer some
# information loss across the fork boundary for calls in-flight close to the time of the fork.
# Prior to the fork, the parent's trace database is flushed to disk and closed. After the fork, a copy
# of the parent's trace database is made for the child with the pid suffix appropriately updated.
# The parent reopens its own database, and the child opens the database newly created for it. In this way,
# the child retains the trace information state of the parent in keeping with the notion that the
# memory state of the parent passes to the child. Should the databases be merged post-hoc, the trace
# information should be a proper union of the activity of parent and its child, provided that conflicts
# resulting from the records duplicated from parent to child are ignored.
#
# Scheduling mode is specified from the command line as follows:
#
# Multi-threaded
# \verbatim
# +TURTLES -enabled -scheduleMode mt -TURTLES
# \endverbatim
# Event-loop
# \verbatim
# +TURTLES -enabled -scheduleMode ev -TURTLES
# \endverbatim
namespace eval ::turtles {
	## Valid options to pass to the TURTLES system.
	variable options
	set options {
		{enabled "TURTLES enabled (disabled by default)"}
		{commitMode.arg staged "Final commit mode: (staged|direct)"}
		{intervalMillis.arg 30000 "Interval between final commits (ms)"}
		{dbPath.arg {./} "Final DB directory path"}
		{dbPrefix.arg {turtles} "Final DB name prefix"}
		{scheduleMode.arg mt "Finalizer scheduling mode (multi-threaded \[mt\] | event-loop \[ev\])"}
		{debug "Print debug information to stderr"}
	}

	namespace export release_the_turtles capture_the_turtles options
}

## Handler for proc entry.
#
# Note that this handler is triggered _before_ the proc has started execution.
#
# \param[in] commandString the command string to be executed
# \param[in] op the operation (in this case, \c enter).
proc ::turtles::on_proc_enter {commandString op} {
	set time0 [clock microseconds]
	# Retrieve the frame two levels down the call stack to avoid
	# confusing with the stack frame for ::turtles::on_proc_enter.
	set execFrame [info frame -2]
	if { [dict exists $execFrame proc] } {
		# Called from within procedure
		set rawCallerName [dict get $execFrame proc]
		set callerName [uplevel namespace origin [subst {\{$rawCallerName\}}]]
	} else {
		# Called from top level
		set callerName ""
	}
	# Avoid unnecessary recursive descent.
	if { [ regexp {^::turtles::} $callerName ] } { return }
	# Callee needs to be fully qualified for consistency.
	lassign $commandString rawCalleeName
	set calleeName [uplevel namespace origin [subst {\{$rawCalleeName\}}]]
	# Get hashes on FQFNs for caller and callee.
	set callerId [ ::turtles::hashing::hash_string $callerName ]
	set calleeId [ ::turtles::hashing::hash_string $calleeName ]
	regsub {tid} [ thread::id ] {} threadId
	set srcLine  [ dict get $execFrame line]
	set stackLvl [ info level ]
	# Set the unique trace ID for this exact call point.
	# The trace ID is a hash of the current thread, stack level, caller, source line, and callee.
	set traceId [ ::turtles::hashing::hash_int_list [list $threadId $stackLvl $callerId $srcLine $calleeId] ]
	# Set time of entry as close to function entry as possible to avoid adding overhead to accounting.
	set timeEnter [ clock microseconds ]
	# Record entry into proc.
	if { [info exists ::turtles::debug] } {
		puts stderr "\[$timeEnter:$op:$traceId\] $callerName ($callerId) -> $calleeName ($calleeId) \{$rawCalleeName\}"
	}
	catch { ::turtles::persistence::add_call $callerId $calleeId $traceId $timeEnter }
	catch { ::turtles::persistence::add_call 0 [::turtles::hashing::hash_string ::turtles::on_proc_enter] $traceId $time0 [clock microseconds] }
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
		set rawCallerName [dict get $execFrame proc]
		set callerName [uplevel namespace origin [subst {\{$rawCallerName\}}]]
	} else {
		# Called from top level
		set callerName ""
	}
	# Avoid unnecessary recursive descent.
	if { [ regexp {^::turtles::} $callerName ] } { return }
	# Callee needs to be fully qualified for consistency.
	lassign $commandString rawCalleeName
	set calleeName [uplevel namespace origin [subst {\{$rawCalleeName\}}]]
	# Get hashes on FQFNs for caller and callee.
	set callerId [ ::turtles::hashing::hash_string $callerName ]
	set calleeId [ ::turtles::hashing::hash_string $calleeName ]
	regsub {tid} [ thread::id ] {} threadId
	set srcLine  [ dict get $execFrame line]
	set stackLvl [ info level ]
	# The trace ID is a hash of the current thread, stack level, caller, source line, and callee.
	set traceId [ ::turtles::hashing::hash_int_list [list $threadId $stackLvl $callerId $srcLine $calleeId] ]
	# Record exit from proc.
	if { [info exists ::turtles::debug] } {
		puts stderr "\[$timeLeave:$op:$traceId\] $callerName ($callerId) -> $calleeName ($calleeId) \{$rawCalleeName\}"
	}
	catch { ::turtles::persistence::update_call $callerId $calleeId $traceId $timeLeave }
	catch { ::turtles::persistence::add_call 0 [::turtles::hashing::hash_string ::turtles::on_proc_leave] $traceId $timeLeave [clock microseconds] }
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
	set remainder [lassign $commandString _proc rawProcName rawProcArgs rawProcBody]
	if [info exists ::turtles::debug] {
		puts "on_proc_define_add_trace: rawProcName = $rawProcName"
	}
	# Proceed only if the command string is a proc def.
	if { $remainder eq {} && $_proc eq {proc} && $rawProcName ne {}} {
		# Attempt name resolution.
		set procName [uplevel namespace origin [subst {\{$rawProcName\}}]]
		# Proceed only if we can resolve the proc name.
		if { $procName ne {} } {
			::turtles::add_proc_trace $procName
			if [info exists ::turtles::debug] {
				puts "on_proc_define_add_trace: $procName"
			}
		} else {
			puts stderr "CANNOT RESOLVE COMMAND \{$rawProcName\}! ns = [namespace_current], ns' = [uplevel namespace current]"
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

	if { [info exists ::turtles::debug] } {
		puts stderr "add_proc_trace: $procId $procName $timeDefined"
	}

	lappend ::turtles::tracedProcs $procName
	# Add handler for proc entry.
	if { [ catch { trace add execution $procName [list enter] ::turtles::on_proc_enter } err ] != 0 } {
		puts stderr "Failed to add enter trace for '$procName' [info commands $procName] \{$commandString\}: $err"
	} else {
		# Add handler for proc exit iff the handler for entry was successfully installed.
		if { [ catch { trace add execution $procName [list leave] ::turtles::on_proc_leave } err ] != 0 } {
			puts stderr "Failed to add leave trace for '$procName' [info commands $procName] \{$commandString\}: $err"
		}
	}
}

## Consumes TURTLES options from a given argv string reference.
#
# The function returns a dictionary with all params defined according
# to user-supplied values or system defaults.
#
# NB: The variable behind the given argv string reference may be modified.
# Any string snippets bracketed between +TURTLES ... -TURTLES will be removed.
#
# Valid options are defined in \c ::turtles::options.
# \param[in,out] _argv variable name reference for an argv string
proc ::turtles::hatch_the_turtles {_argv} {
	upvar $_argv {argv'}


	set usage "+TURTLES ?options? -TURTLES\nGiven '${argv'}'"

	set params [dict create]
	set targv [::turtles::options::consume {argv'}]
	if { [catch {set rawparams [::cmdline::getoptions targv $::turtles::options $usage]} catchResult] == 1 } {
		puts stderr "catch result = $catchResult"
		set params [dict create enabled 0]
	} else {
		foreach {k v} $rawparams {
			dict set params $k $v
		}
	}
	return $params
}

## User-level convenience function for triggering automatic \c proc instrumentation.
#
# This function binds to the \c proc command so that any proc declared after invocation
# will have the entry and exit handlers bound to it.
#
# Options are determined from the string behind the variable name reference and
# must be placed within a +TURTLES ... -TURTLES snippet. The variable referred to
# by the given argument is modified so that any bracketed TURTLES snippet is removed.
#
# See \c ::turtles::hatch_the_turtles for the set of valid options. Note that the
# -enabled boolean flag must be passed with the TURTLES options in order for the
# trace handlers to be injected. The system is disabled by default.
#
# \param[in,out] _argv a name reference to an argv string
proc ::turtles::release_the_turtles {_argv} {
	upvar $_argv {argv'}
	# Initialize an empty list of procs being traced.
	set ::turtles::tracedProcs [list]

	# Determine whether or not to enable trace logging.
	set params [::turtles::hatch_the_turtles {argv'}]

	# Turn debugging output to stderr on if requested.
	if { [dict get $params debug] } {
		set ::turtles::debug 1
	}
	# Set up dummy procs so that ::turtles::capture_the_turtles doesn't throw an error.
	if { ![dict get $params enabled] } {
		namespace eval ::turtles::persistence {
			proc stop {} { return }
			namespace export *
		}
		return $params
	}

	# Initialize the ghost namespace based on the given or implicit mode parameter.
	namespace eval ::turtles::persistence {
		namespace import ::turtles::persistence::[uplevel { subst {[dict get $params scheduleMode]} }]::*
		namespace export *
	}

	proc ::turtles::pre_fork {commandString op} {
		::turtles::persistence::stop
	}

	eval [subst {
		proc ::turtles::post_fork {commandString code result op} {
			# If the current process is a spawned child...
			if { \$result == 0 } {
				# Copy the DB at the parent's path to the child's path.
				::turtles::persistence::base::copy_db_from_fork_parent [dict get $params dbPath] [dict get $params dbPrefix]
			}
			::turtles::persistence::start [dict get $params commitMode] [dict get $params intervalMillis] [dict get $params dbPath] [dict get $params dbPrefix]
		}
	}]

	# Add guards for forking.
	trace add execution {fork} [list enter] ::turtles::pre_fork
	trace add execution {fork} [list leave] ::turtles::post_fork


	# Start the persistence mechanism now so it's ready once the hooks are added. Sinks before sources!
	::turtles::persistence::start [dict get $params commitMode] [dict get $params intervalMillis] [dict get $params dbPath] [dict get $params dbPrefix]

	# Bootstrap the proc IDs for the ::turtles namespace and its children
	# so that the standard views make sense.
	foreach procName [ concat \
						   [info procs ::turtles::*] \
						   [info procs ::turtles::hashing::*] \
						   [info procs ::turtles::options::*] \
						   [info procs ::turtles::persistence::base::*] \
						   [info procs ::turtles::persistence::mt::*] \
						   [info procs ::turtles::persistence::ev::*] ] {
		# Calculate the proc ID hash and set the time defined.
		set procId [::turtles::hashing::hash_string $procName]
		set timeDefined [clock microseconds]
		# Add the proc ID hash to the lookup table and the list of traced procs.
		::turtles::persistence::add_proc_id $procId $procName $timeDefined
	}

	# Add a trigger for the proc command to add a handler for the newly defined proc.
	trace add execution {proc} [list leave] ::turtles::on_proc_define_add_trace
	return $params
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
		if { [info procs $handledProc] ne {} } {
			trace remove execution $handledProc [list enter] ::turtles::on_proc_enter
			trace remove execution $handledProc [list leave] ::turtles::on_proc_leave
		}
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
