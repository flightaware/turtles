#!/usr/bin/env tclsh
package require Tcl     8.5 8.6
package require Thread
package require sqlite3

package require turtles::persistence::base 0.1

## Namespace for handling persistence of trace information generated by the turtles package.
namespace eval ::turtles::persistence::ev {
	variable stage0
	variable stage1
	namespace export start stop add_proc_id add_call update_call stage0 stage1
}

## \file persistence_ev.tcl
# Provides the mechanisms for the proc entry and exit handlers to persist
# trace information about proc execution for the purpose of building call
# graphs and other execution analysis artifacts.
#
# Under the hood, the library makes extensive use of Tcl's
# sqlite facilities for portability and ease of aggregation.
#
# Persistence is handled in two stages: ephemeral (0) and final (1).
# During the ephemeral stage, the handlers access an in-memory
# sqlite database (created with the \c :memory: literal name).
#
# A separate worker thread (recorder) courtesy of the Tcl Thread library
# marshals persistence requests. Another worker thread (scheduler)
# maintains a periodic notification sent to the recorder to induce
# a stage transfer from ephemeral to finalized for any new trace
# information since the last transfer. Novelty is defined by the
# timestamps of the trace information records and is calculated
# within the recorder's finalize function from the stage 1 tables
# so as to prevent unnecessary and complicated accounting of timestamps.
#
# If the program crashes or otherwise suddenly exits, any
# information which has not transitioned from the ephemeral to
# the final stage will be lost. An option is provided to allow
# consumers to skip the ephemeral stage and write directly to
# final storage at the cost of increased overhead and decreased
# performance.
#
# To persist trace information, it is recommended to invoke
# \c ::turtles::persistence::start with the appropriate parameters
# and _then_ add trace hooks.
# To stop persistence, it is recommended to remove the relevant
# trace hooks and _then_ invoke \c ::turtles::persistence::stop.
#
# The writes to ephemeral storage are marshalled implicitly
# through the following functions:
#
# * \c ::turtles::persistence::add_proc_id
# * \c ::turtles::persistence::add_call
# * \c ::turtles::persistence::update_call
#
# Under the hood, these procs use thread::send to induce the
# recorder thread to perform the requisite SQL calls.


## Adds a proc id to the proc id table in the stage 0 persistence DB.
#
# NB: If there is a conflict, i.e., if the given procId and/or procName
# already exist in the stage 0 persistence DB proc_ids table, the existing
# record will NOT be overwritten, and the proc will swallow the conflict.
#
# \param[in] procId proc name hash
# \param[in] procName proc name
# \param[in] timeDefined the epoch time in microseconds at which the proc definition was invoked
proc ::turtles::persistence::ev::add_proc_id {procId procName timeDefined {awaiter {}}} {
	eval [::turtles::persistence::base::add_proc_id [namespace current]::stage0 $procId $procName $timeDefined]
}

## Adds a call point to the call point table in the stage 0 persistence DB to record proc entry.
#
# \param[in] callerId proc name hash of the caller
# \param[in] calleeId proc name hash of the callee, i.e., the function of interest
# \param[in] traceId identifier disambiguating calls on the same caller-callee edge in the call graph
# \param[in] timeEnter the epoch time in microseconds at which the proc entry handler was triggered
proc ::turtles::persistence::ev::add_call {callerId calleeId traceId timeEnter {awaiter {}}} {
	eval [::turtles::persistence::base::add_call [namespace current]::stage0 $callerId $calleeId $traceId $timeEnter]
}

## Updates a previously added call point in the call point table in the stage 0 persistence DB to record proc exit.
#
# \param[in] callerId proc name hash of the caller
# \param[in] calleeId proc name hash of the callee, i.e., the function of interest
# \param[in] traceId identifier disambiguating calls on the same caller-callee edge in the call graph
# \param[in] timeLeave the epoch time in microseconds at which the proc exit handler was triggered
proc ::turtles::persistence::ev::update_call {callerId calleeId traceId timeLeave {awaiter {}}} {
	eval [::turtles::persistence::base::update_call [namespace current]::stage0 $callerId $calleeId $traceId $timeLeave]
}

## Initializes the turtles persistence model.
#
# Note that in \c direct mode the persistence model writes directly to the final DB.
#
# \param[in] finalDB the file for finalized persistence as a sqlite DB
# \param[in] commitMode the mode for persistence (\c staged | \c direct) [default: \c staged]
# \param[in] intervalMillis the number of milliseconds between stage transfers [default: 30000]
proc ::turtles::persistence::ev::start {finalDB {commitMode staged} {intervalMillis 30000}} {
	switch $commitMode {
		staged {
				::turtles::persistence::base::init_stage [namespace current]::stage0
				::turtles::persistence::base::init_stage [namespace current]::stage1 $finalDB
			::turtles::persistence::ev::start_finalizer [namespace current]::nextFinalizeCall [namespace current]::stage0 [namespace current]::stage1 $intervalMillis
		}
		direct {
				::turtles::persistence::base::init_stage [namespace current]::stage0 $finalDB
		}
		default {
			error "::turtles::persistence::start: invalid commit mode '$commitMode'. Valid options are 'staged' or 'direct'."
		}
	}
}


## Halts and tears down the turtles persistence model.
#
# If the model is operating in \c staged mode, any pending
# ::turtles::persistence::finalize call is cancelled, and an
# explicit call is made immediately to transfer the remaining
# unfinalized information from the ephemeral to the finalized DB.
#
# The underlying sqlite DB(s) introduced via \c ::turtles::persistence::start
# are closed and any pertinent namespace variables are unset.
#
# NB: This proc should not be called until all the relevant trace hooks are eliminated.
proc ::turtles::persistence::ev::stop {} {
	::turtles::persistence::base::stop_finalizer [namespace current]::nextFinalizeCall
	::turtles::persistence::base::stop_recorder [namespace current]::stage0 [namespace current]::stage1
}

## Kicks off the periodic prompt in the scheduler to notify the recorder to
# transfer new trace information from stage 0 to stage 1.
#
# \param stage0 the stage 0 command (i.e., sqlite DB) for ephemeral storage
# \param stage1 the stage 1 command (i.e., sqlite DB) for finalized storage
# \param intervalMillis the interval in ms between finalize notifications
proc ::turtles::persistence::ev::start_finalizer {nextRef stage0 stage1 intervalMillis} {
	upvar $nextRef next
	set next [after $intervalMillis ::turtles::persistence::ev::schedule_finalize next $stage0 $stage1 $intervalMillis ]
}

## The self-perpetuating worker that continually transfers ephemeral trace information to the finalized DB.
#
# This function is only invoked if the persistence model is invoked in \c staged mode.
#
# NB: This function should only be executed directly in the scheduler thread.
#
# \param[in] intervalMillis the number of milliseconds between operations
proc ::turtles::persistence::ev::schedule_finalize {nextRef stage0 stage1 intervalMillis} {
	upvar $nextRef next
	::turtles::persistence::base::finalize $stage0 $stage1
	set ::turtles::persistence::base::nextFinalizeCall [after $intervalMillis ::turtles::persistence::ev::schedule_finalize next $stage0 $stage1 $intervalMillis]
}

package provide turtles::persistence::ev 0.1