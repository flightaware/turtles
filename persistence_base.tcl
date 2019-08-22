#!/usr/bin/env tclsh

package require Tcl 8.5 8.6
package require Tclx
package require turtles::hashing           0.1

## \file persistence_base.tcl
# Provides functions and lambda bodies common to both MT and event-loop versions
# of the persistence mechanisms.
#
# This is the base underlying mechanism for the proc entry and exit handlers to persist
# trace information about proc execution for the purpose of building call
# graphs and other execution analysis artifacts.
#
# Under the hood, the library makes extensive use of Tcl's
# sqlite facilities for portability and ease of aggregation.
#
# In staged mode, persistence is handled in two stages: ephemeral (0) and final (1).
# During the ephemeral stage, the handlers access an in-memory
# sqlite database (created with the \c :memory: literal name).
#
# If the program crashes or otherwise suddenly exits, any
# information which has not transitioned from the ephemeral to
# the final stage will be lost. An option is provided to allow
# consumers to skip the ephemeral stage and write directly to
# final storage at the cost of increased overhead and decreased
# performance, namely direct mode.
#
# The writes to ephemeral storage are marshalled implicitly
# through the following lambdas:
#
# * \c ::turtles::persistence::base::add_proc_id
# * \c ::turtles::persistence::base::add_call
# * \c ::turtles::persistence::base::update_call
#
# These lambdas are then used by the MT and event-loop versions of the persistence mechanism
# according to their scheduling logic.

## Namespace for common persistence lambda bodies and utility functions.
namespace eval ::turtles::persistence::base {
	variable nextFinalizeCall
	namespace export \
		get_db_filename safe_quote \
		script add_proc_id add_call update_call \
		init_proc_id_table init_call_pt_table init_views \
		init_stage close_stage \
		finalize nextFinalizeCall
}

## Safely quotes a string so that it can be wrapped with single quotes in a sqlite3 DB command.
#
# The proc replaces all backslashes with a double backslash and then all single quotes with
# two single quotes.
#
# This is made necessary by the fact that commands passed by \c thread::send cannot expect
# to expand variables that properly belong to the calling thread and are not present in the
# called thread.
#
# A better option would probably be to set up channels for interthread communication so that
# the amount of data transferred would be minimized.
#
# \param[in] unsafe the string to be made safe
proc ::turtles::persistence::base::safe_quote {unsafe} {
	regsub -all {\\} $unsafe {\\\\} safeBS
	regsub -all {'} $safeBS {''} safeSQ
	return $safeSQ
}

## Deterministically constructs the persistence DB filename based on provided arguments.
#
# The format is \c $dbPath/$dbPrefix-[pid].db
#
# \param[in] dbPath the path under which the database resides
# \param[in] dbPrefix the first part of the database filename
# \param[in] myPid an optional pid argument to use for overriding so processes can access DBs other than their own
proc ::turtles::persistence::base::get_db_filename {{dbPath {./}} {dbPrefix {turtles}} {myPid {}}} {
	if { $myPid eq {} } {
		set myPid [pid]
	}
	return [file normalize [file join $dbPath [subst {$dbPrefix-$myPid.db}]]]
}

## Copies the database file from a forked child's parent to the file to be used by the child itself.
#
# This simply gets the child's process parent and determines the appropriate filename
# so it can make a copy for itself.
#
# \param[in] dbPath the path under which the database resides
# \param[in] dbPath the first part of the database filename
proc ::turtles::persistence::base::copy_db_from_fork_parent {{dbPath {./}} {dbPrefix {turtles}}} {
	set ppid [id process parent]
	file copy \
		[::turtles::persistence::base::get_db_filename $dbPath $dbPrefix $ppid] \
		[::turtles::persistence::base::get_db_filename $dbPath $dbPrefix]
}

## Returns a lambda suitable for passing via \c thread::send that adds a proc entry to the database.
#
# \param[in] dbcmd the sqlite3 database command
# \param[in] procId the proc name hash
# \param[in] procName the fully-qualified canonical proc name
# \param[in] timeDefined the time in epoch μs when the proc was defined during execution
proc ::turtles::persistence::base::add_proc_id {dbcmd procId procName timeDefined} {
	set safeProcName [::turtles::persistence::base::safe_quote $procName]
	return [subst {
		$dbcmd eval {
			INSERT INTO main.proc_ids (proc_id, proc_name, time_defined)
			VALUES($procId, '$safeProcName', $timeDefined)
			ON CONFLICT DO NOTHING;
		}
	}]
}

## Returns a lambda suitable for passing via \c thread::send that adds a call point entry to the database.
#
# This function is primarily used by the proc enter handler.
#
# The optional timeLeave parameters is mostly for introspection on the timings of \c ::turtles::* operations.
# The proc enter/leave handlers can't use the general mechanism because it will create an infinite recursion.
#
# \param[in] dbcmd the sqlite3 database command
# \param[in] callerId the caller proc name hash
# \param[in] calleeId the callee proc name hash
# \param[in] traceId a unique identifier for enabling the system to update the call point entry
# \param[in] timeEnter the time in epoch μs when the proc was entered during execution
# \param[in] timeLeave the time in epoch μs when the proc was exited during execution (optional)
proc ::turtles::persistence::base::add_call {dbcmd callerId calleeId traceId timeEnter {timeLeave {NULL}}} {
	return [subst {
		if { \[info comm $dbcmd\] ne {} } {
			$dbcmd eval {
				INSERT INTO main.call_pts (caller_id, callee_id, trace_id, time_enter, time_leave)
				VALUES($callerId, $calleeId, $traceId, $timeEnter, $timeLeave);
			}
		}
	}]
}

## Returns a lambda suitable for passing via \c thread::send that updates a call point entry in the database.
#
# This function is primarily used by the proc leave handler.
#
# The updated record must match the callerId, calleId, and traceId.
#
# \param[in] dbcmd the sqlite3 database command
# \param[in] callerId the caller proc name hash
# \param[in] calleeId the callee proc name hash
# \param[in] traceId a unique identifier for enabling the system to update the call point entry
# \param[in] timeLeave the time in epoch μs when the proc was exited during execution (optional)
proc ::turtles::persistence::base::update_call {dbcmd callerId calleeId traceId timeLeave} {
	return [subst {
		if { \[info comm $dbcmd\] ne {} } {

			$dbcmd eval {
				UPDATE main.call_pts SET time_leave = $timeLeave
				WHERE caller_id = $callerId AND callee_id = $calleeId AND trace_id = $traceId AND time_leave IS NULL;
			}
		}
	}]
}

## Creates the proc id table if it does not already exist.
#
# \param[in] dbcmd the sqlite3 database command
# \param[in] stage the persistence stage (main or stage1)
proc ::turtles::persistence::base::init_proc_id_table {dbcmd {stage {main}}} {
	$dbcmd eval [subst {
		CREATE TABLE IF NOT EXISTS $stage.proc_ids
		(proc_id INT UNIQUE, proc_name TEXT UNIQUE, time_defined INT);
	}]
}

## Creates the call point table if it does not already exist.
#
# \param[in] dbcmd the sqlite3 database command
# \param[in] stage the persistence stage (main or stage1)
proc ::turtles::persistence::base::init_call_pt_table {dbcmd {stage {main}}} {
	$dbcmd eval [subst {
		CREATE TABLE IF NOT EXISTS $stage.call_pts
		(caller_id INT, callee_id INT, trace_id INT, time_enter INT, time_leave INT);
		CREATE INDEX IF NOT EXISTS $stage.call_pt_edge_idx ON call_pts(caller_id, callee_id);
	}]
}

## Creates a number of useful views for aggregate statistics about calls.
#
# \param[in] dbcmd the sqlite3 database command
# \param[in] stage the persistence stage (main or stage1)
proc ::turtles::persistence::base::init_views {dbcmd {stage {main}}} {
	$dbcmd eval [subst {
		CREATE VIEW IF NOT EXISTS $stage.calls_by_caller_callee AS
		SELECT caller_name, callee_name, COUNT(*) AS calls, SUM(time_leave - time_enter) AS total_exec_micros, SUM(time_leave - time_enter)/COUNT(*) AS avg_exec_micros
		FROM (SELECT COALESCE(callers.proc_name, "") AS caller_name, callees.proc_name AS callee_name, time_enter, time_leave
			  FROM call_pts
			  LEFT JOIN proc_ids AS callers ON callers.proc_id = caller_id
			  INNER JOIN proc_ids AS callees ON callees.proc_id = callee_id)
		GROUP BY caller_name, callee_name
		ORDER BY total_exec_micros DESC;
	}]
	$dbcmd eval [subst {
		CREATE VIEW IF NOT EXISTS $stage.calls_by_callee AS
		SELECT callee_name, SUM(calls) AS calls, SUM(total_exec_micros) AS total_exec_micros, SUM(total_exec_micros)/SUM(calls) AS avg_exec_micros
		FROM calls_by_caller_callee
		GROUP BY callee_name
		ORDER BY total_exec_micros DESC;
	}]
	$dbcmd eval [subst {
		CREATE VIEW IF NOT EXISTS $stage.unused_procs AS
		SELECT callee_name
		FROM (SELECT proc_name AS callee_name
			  FROM proc_ids
			  LEFT JOIN call_pts ON proc_ids.proc_id = call_pts.callee_id
			  WHERE callee_id IS NULL)
		ORDER BY callee_name;
	}]
}

## Transfers trace information from the ephemeral to the finalized DB.
#
# The proc is used in staged commit mode, but not direct.
#
# It should only be executed directly in the recorder thread in MT schedule mode.
#
# NB: Calling this function will remove all call point entries from the ephemeral stage
# up until the time of entry into this proc after those entries have been transferred
# to the final stage. This is done to keep memory costs down and simplify the query logic.
#
# \param[in] dbcmd the sqlite3 database command
proc ::turtles::persistence::base::finalize {dbcmd} {
	set time0 [clock microseconds]
	# Only proceed if the databases exist.
	if { [::turtles::persistence::base::commit_mode_is_staged $dbcmd] } {
		# Retrieve last finalize time recorded to stage 1.
		$dbcmd eval {
			SELECT COALESCE(MAX(t), 0) AS tmax FROM (SELECT time_defined AS t FROM stage1.proc_ids UNION SELECT time_leave AS t FROM stage1.call_pts);
		} {
			set lastFinalizeTime $tmax
		}
		# Copy proc ids from the last finalized to the present into the final DB.
		$dbcmd eval {
			INSERT INTO stage1.proc_ids
			SELECT proc_id, proc_name, time_defined FROM main.proc_ids
			WHERE time_defined > $lastFinalizeTime
			ON CONFLICT DO NOTHING;

			INSERT INTO stage1.call_pts
			SELECT caller_id, callee_id, trace_id, time_enter, time_leave FROM main.call_pts
			WHERE time_leave IS NOT NULL AND time_leave < $time0
			ON CONFLICT DO NOTHING;

			DELETE FROM main.call_pts
			WHERE time_leave IS NOT NULL AND time_leave < $time0;
		}
		set script [::turtles::persistence::base::add_call $dbcmd 0 [::turtles::hashing::hash_string ::turtles::persistence::base::finalize] $time0 $time0 [clock microseconds]]
		if {[catch { eval $script } err] != 0 } {
			puts stderr $err
		}
	}
}

## Determines whether a persistence database is in staged or direct mode.
#
# Under the hood, this checks how many databases are attached.
# Staged mode has both the final persistence and the in-memory persistence.
#
# \param[in] dbcmd the sqlite3 database command
proc ::turtles::persistence::base::commit_mode_is_staged {dbcmd} {
	return [expr {[info comm $dbcmd ] ne {} && [llength [$dbcmd eval { PRAGMA database_list }]] > 3}];
}

## Initialize the persistence stages with all the requisite tables and views.
#
# \param[in] dbcmd the sqlite3 database command
# \param[in] commitMode \c staged or \c direct
# \param[in] finalStageName the actual filename for the final persistence DB
proc ::turtles::persistence::base::init_stages {dbcmd commitMode finalStageName} {
	if { $finalStageName ne {} } {
		file mkdir [file normalize [file dirname $finalStageName]]
	}
	switch $commitMode {
		staged {
			sqlite3 $dbcmd {:memory:}
			$dbcmd eval { ATTACH DATABASE $finalStageName AS stage1; }
			::turtles::persistence::base::init_proc_id_table $dbcmd stage1
			::turtles::persistence::base::init_call_pt_table $dbcmd stage1
			::turtles::persistence::base::init_views $dbcmd stage1
		}
		direct {
			sqlite3 $dbcmd $finalStageName
		}
	}
	::turtles::persistence::base::init_proc_id_table $dbcmd
	::turtles::persistence::base::init_call_pt_table $dbcmd
	::turtles::persistence::base::init_views $dbcmd
}

## Tears down a given stage in the persistence model.
#
# Under the hood, this closes the associated sqlite DB.
# The associated command will no longer be available after this completes.
#
# \param[in] dbcmd the sqlite3 database command
proc ::turtles::persistence::base::close_stages {dbcmd} {
	if { [info comm $dbcmd] ne {} } {
		if { [ ::turtles::persistence::base::commit_mode_is_staged $dbcmd ] } {
			$dbcmd eval {
				INSERT INTO stage1.proc_ids
				SELECT p0.proc_id, p0.proc_name, p0.time_defined FROM main.proc_ids AS p0
				LEFT JOIN stage1.proc_ids AS p1 ON p0.proc_id = p1.proc_id
				WHERE p1.proc_id IS NULL
				ON CONFLICT DO NOTHING;
				INSERT INTO stage1.call_pts
				SELECT caller_id, callee_id, trace_id, time_enter, time_leave FROM main.call_pts
				WHERE true
				ON CONFLICT DO NOTHING;
				DETACH DATABASE stage1;
			}
		}
		$dbcmd close
	}
}

## Terminates the periodic prompt in the scheduler to notify the recorder
# to transfer new trace information from stage 0 to stage 1.
#
# Invocation of this proc forces an \c update in the scheduler thread
# to execute any pending tasks in the Tcl event loop for the thread.
# Any new finalize prompt scheduled after this update is cancelled.
#
# The variable holding the pointer to the next finalize prompt is unset.
#
# Note that this is only needed in \c ev schedule mode to target the cancellation
# of any pending finalize job. In \c mt schedule mode, all jobs in the scheduler
# thread can be summarily cancelled.
#
# \param[in] nextRef the after job id to cancel
proc ::turtles::persistence::base::stop_finalizer {nextRef} {
	upvar $nextRef next
	# Force any pending finalize call to execute.
	update
	# Cancel the newly pending finalize call.
	after cancel $next
}

# An explicit finalize notification is
# made to the recorder thread to catch the last trace information
# that has not been transferred from stage 0 to stage 1.
#
# NB: This should not be invoked while trace handlers which could modify
# the stage databases are active.
#
# \param[in] dbcmd the sqlite3 database command
proc ::turtles::persistence::base::stop_recorder {dbcmd} {
	update
	# Do a last finalize to pick up any missing trace information.
	::turtles::persistence::base::finalize $dbcmd
	::turtles::persistence::base::close_stages $dbcmd
}


package provide turtles::persistence::base 0.1
