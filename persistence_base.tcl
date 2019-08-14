#!/usr/bin/env tclsh

package require Tcl 8.5 8.6
package require Tclx

## \file persistence_base.tcl
# Provides functions and lambda bodies common to both MT and event-loop versions
# of the persistence mechanisms.

## Namespace for common persistence lambda bodies.
namespace eval ::turtles::persistence::base {
	variable nextFinalizeCall
	namespace export \
		get_db_filename \
		script add_proc_id add_call update_call \
		init_proc_id_table init_call_pt_table init_views \
		init_stage close_stage \
		finalize nextFinalizeCall
}

proc ::turtles::persistence::base::get_db_filename {{dbPath {./}} {dbPrefix {turtles}} {myPid {}}} {
	if { $myPid eq {} } {
		set myPid [pid]
	}
	return [file normalize [file join $dbPath [subst {$dbPrefix-$myPid.db}]]]
}

proc ::turtles::persistence::base::copy_db_from_fork_parent {{dbPath {./}} {dbPrefix {turtles}}} {
	set ppid [id process parent]
	file copy \
		[::turtles::persistence::base::get_db_filename $dbPath $dbPrefix $ppid] \
		[::turtles::persistence::base::get_db_filename $dbPath $dbPrefix]
}

proc ::turtles::persistence::base::add_proc_id {dbcmd procId procName timeDefined} {
	regsub -all {\\} $procName {\\\\} procNameBS
	regsub -all {'} $procName {''} procNameSQ
	return [subst {
		$dbcmd eval {
			INSERT INTO main.proc_ids (proc_id, proc_name, time_defined)
			VALUES($procId, '$procNameSQ', $timeDefined)
			ON CONFLICT DO NOTHING;
		}
	}]
}

proc ::turtles::persistence::base::add_call {dbcmd callerId calleeId traceId timeEnter} {
	return [subst {
		if { \[info comm $dbcmd\] ne {} } {
			$dbcmd eval {
				INSERT INTO main.call_pts (caller_id, callee_id, trace_id, time_enter)
				VALUES($callerId, $calleeId, $traceId, $timeEnter);
			}
		}
	}]
}

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
# \param[in] stage persistence stage DB
proc ::turtles::persistence::base::init_proc_id_table {dbcmd {stage {main}}} {
	$dbcmd eval [subst {
		CREATE TABLE IF NOT EXISTS $stage.proc_ids
		(proc_id INT UNIQUE, proc_name TEXT UNIQUE, time_defined INT);
	}]
}

## Creates the call point table if it does not already exist
#
# \param[in] stage persistence stage DB
proc ::turtles::persistence::base::init_call_pt_table {dbcmd {stage {main}}} {
	$dbcmd eval [subst {
		CREATE TABLE IF NOT EXISTS $stage.call_pts
		(caller_id INT, callee_id INT, trace_id INT, time_enter INT, time_leave INT);
		CREATE INDEX IF NOT EXISTS $stage.call_pt_edge_idx ON call_pts(caller_id, callee_id);
	}]
}

## Creates a number of useful views for aggregate statistics about calls.
#
# \param[in] stage persistence stage DB
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
# NB: This function should only be executed directly in the recorder thread.
proc ::turtles::persistence::base::finalize {dbcmd} {
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
		}
		# Copy _finalized_ call points from the last finalized to the present into the final DB.
		$dbcmd eval {
			INSERT INTO stage1.call_pts
			SELECT caller_id, callee_id, trace_id, time_enter, time_leave FROM main.call_pts
			WHERE time_leave IS NOT NULL AND time_leave > $lastFinalizeTime
			ON CONFLICT DO NOTHING;
		}
	}
}

proc ::turtles::persistence::base::commit_mode_is_staged {dbcmd} {
	return [expr {[info comm $dbcmd ] ne {} && [llength [$dbcmd eval { PRAGMA database_list }]] > 3}];
}

## Initializes a given stage in the persistence model.
#
# Under the hood, this creates the sqlite database and the requisite tables
# for storing trace information.
#
# Without a \c stageName argument, it defaults to an in-memory database.
# It is recommended to invoke this variant only once during execution.
#
# \param[in] stage the stage command (i.e., sqlite DB) to be used for this stage
# \param[in] stageName the filename of the sqlite DB (default = \c :memory:)
# proc ::turtles::persistence::base::init_stage {stage {stageName :memory:}} {
# 	if { $stageName ne {:memory:} && $stageName ne {} } {
# 		file mkdir [file normalize [file dirname $stageName]]
# 	}
# 	sqlite3 $stage $stageName
# 	::turtles::persistence::base::init_proc_id_table $stage
# 	::turtles::persistence::base::init_call_pt_table $stage
# 	::turtles::persistence::base::init_views $stage
# }

proc ::turtles::persistence::base::init_stages {dbcmd commitMode finalStageName} {
	if { $finalStageName ne {} } {
		file mkdir [file normalize [file dirname $finalStageName]]
	}
	switch $commitMode {
		staged {
			sqlite3 $dbcmd {:memory:}
			#$dbcmd eval [subst { ATTACH DATABASE '$finalStageName' AS stage1; }]
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
# \param[in] dbcmd the command (i.e., sqlite DB) for 
proc ::turtles::persistence::base::close_stages {dbcmd} {
	if { [info comm $dbcmd] ne {} } {
		if { [ ::turtles::persistence::base::commit_mode_is_staged $dbcmd ] } {
			$dbcmd eval { DETACH DATABASE stage1; }
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
proc ::turtles::persistence::base::stop_recorder {dbcmd} {
	# Do a last finalize to pick up any missing trace information.
	::turtles::persistence::base::finalize $dbcmd
	::turtles::persistence::base::close_stages $dbcmd
}


package provide turtles::persistence::base 0.1
