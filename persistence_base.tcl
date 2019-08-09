#!/usr/bin/env tclsh

package require Tcl 8.5 8.6

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
proc ::turtles::persistence::base::get_db_filename {{dbPath {./}} {dbPrefix {turtles}}} {
	return [file normalize [file join $dbPath [subst {$dbPrefix-[pid].db}]]]
}

proc ::turtles::persistence::base::add_proc_id {stage procId procName timeDefined} {
	return [subst {
		$stage eval {
			INSERT INTO proc_ids (proc_id, proc_name, time_defined)
			VALUES($procId, '$procName', $timeDefined)
			ON CONFLICT DO NOTHING;
		}
	}]
}

proc ::turtles::persistence::base::add_call {stage callerId calleeId traceId timeEnter} {
	return [subst {
	    $stage eval {
			INSERT INTO call_pts (caller_id, callee_id, trace_id, time_enter)
			VALUES($callerId, $calleeId, $traceId, $timeEnter);
		}
	}]
}

proc ::turtles::persistence::base::update_call {stage callerId calleeId traceId timeLeave} {
	return [subst {
		$stage eval {
			UPDATE call_pts SET time_leave = $timeLeave
			WHERE caller_id = $callerId AND callee_id = $calleeId AND trace_id = $traceId AND time_leave IS NULL;
		}
	}]
}

## Creates the proc id table if it does not already exist.
#
# \param[in] stage persistence stage DB
proc ::turtles::persistence::base::init_proc_id_table {stage} {
	$stage eval {
		CREATE TABLE IF NOT EXISTS proc_ids
		(proc_id INT UNIQUE, proc_name TEXT UNIQUE, time_defined INT);
	}
}

## Creates the call point table if it does not already exist
#
# \param[in] stage persistence stage DB
proc ::turtles::persistence::base::init_call_pt_table {stage} {
	$stage eval {
		CREATE TABLE IF NOT EXISTS call_pts
		(caller_id INT, callee_id INT, trace_id INT, time_enter INT, time_leave INT);
		CREATE INDEX IF NOT EXISTS call_pt_edge_idx ON call_pts(caller_id, callee_id);
	}
}

## Creates a number of useful views for aggregate statistics about calls.
#
# \param[in] stage persistence stage DB
proc ::turtles::persistence::base::init_views {stage} {
	$stage eval {
		CREATE VIEW IF NOT EXISTS calls_by_caller_callee AS
		SELECT caller_name, callee_name, COUNT(*) AS calls, SUM(time_leave - time_enter) AS total_exec_micros, SUM(time_leave - time_enter)/COUNT(*) AS avg_exec_micros
		FROM (SELECT COALESCE(callers.proc_name, "") AS caller_name, callees.proc_name AS callee_name, time_enter, time_leave
			  FROM call_pts
			  LEFT JOIN proc_ids AS callers ON callers.proc_id = caller_id
			  INNER JOIN proc_ids AS callees ON callees.proc_id = callee_id)
		GROUP BY caller_name, callee_name
		ORDER BY total_exec_micros DESC;
	}
	$stage eval {
		CREATE VIEW IF NOT EXISTS calls_by_callee AS
		SELECT callee_name, SUM(calls) AS calls, SUM(total_exec_micros) AS total_exec_micros, SUM(total_exec_micros)/SUM(calls) AS avg_exec_micros
		FROM calls_by_caller_callee
		GROUP BY callee_name
		ORDER BY total_exec_micros DESC;
	}
	$stage eval {
		CREATE VIEW IF NOT EXISTS unused_procs AS
		SELECT callee_name
		FROM (SELECT proc_name AS callee_name
			  FROM proc_ids
			  LEFT JOIN call_pts ON proc_ids.proc_id = call_pts.callee_id
			  WHERE callee_id IS NULL)
		ORDER BY callee_name;
	}
}



## Transfers trace information from the ephemeral to the finalized DB.
#
# NB: This function should only be executed directly in the recorder thread.
proc ::turtles::persistence::base::finalize {stage0 stage1} {
	# Only proceed if the databases exist.
	if { [info comm $stage0 ] ne {} && [info comm $stage1 ] ne {} } {

		# Retrieve last finalize time recorded to stage 1.
		$stage1 eval {
			SELECT COALESCE(MAX(t), 0) AS tmax FROM (SELECT time_defined AS t FROM proc_ids UNION SELECT time_leave AS t FROM call_pts);
		} values {
			set lastFinalizeTime $values(tmax)
		}

		# Copy proc ids from the last finalized to the present into the final DB.
		$stage0 eval {
			SELECT proc_id, proc_name, time_defined FROM proc_ids
			WHERE time_defined > $lastFinalizeTime
		} values {
			$stage1 eval {
				INSERT INTO proc_ids (proc_id, proc_name, time_defined)
				VALUES ($values(proc_id), $values(proc_name), $values(time_defined))
				ON CONFLICT DO NOTHING;
			}
		}
		# Copy _finalized_ call points from the last finalized to the present into the final DB.
		$stage0 eval {
			SELECT caller_id, callee_id, trace_id, time_enter, time_leave FROM call_pts
			WHERE time_leave IS NOT NULL
			  AND time_leave > $lastFinalizeTime
		} values {
			if { [info exists ::turtles::debug ] } {
				puts stderr "finalize([pid]): $values(caller_id), $values(callee_id), $values(trace_id), $values(time_enter), $values(time_leave)"
			}
			$stage1 eval {
				INSERT INTO call_pts (caller_id, callee_id, trace_id, time_enter, time_leave)
				VALUES ($values(caller_id), $values(callee_id), $values(trace_id), $values(time_enter), $values(time_leave));
			}
		}
	}
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
proc ::turtles::persistence::base::init_stage {stage {stageName :memory:}} {
	sqlite3 $stage $stageName
	::turtles::persistence::base::init_proc_id_table $stage
	::turtles::persistence::base::init_call_pt_table $stage
	::turtles::persistence::base::init_views $stage
}

## Tears down a given stage in the persistence model.
#
# Under the hood, this closes the associated sqlite DB.
# The associated command will no longer be available after this completes.
#
# \param[in] stage the stage command (i.e., sqlite DB)
proc ::turtles::persistence::base::close_stage {stage} {
	if { [info comm $stage] ne {} } {
		$stage close
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
proc ::turtles::persistence::base::stop_recorder {stage0 stage1} {
	if { [info comm $stage1] ne {} } {
		# Do a last finalize to pick up any missing trace information.
		::turtles::persistence::base::finalize $stage0 $stage1
		::turtles::persistence::base::close_stage $stage1
	}
	::turtles::persistence::base::close_stage $stage0
}


package provide turtles::persistence::base 0.1
