#!/usr/bin/env tclsh

package require Tcl 8.5 8.6

## \file lambda.tcl
# Provides lambda bodies common to both MT and event-loop versions
# of the persistence mechanisms.

## Namespace for common persistence lambda bodies.
namespace eval ::turtles::persistence::lambda {
	namespace export script add_proc_id add_call update_call stop_scheduler stop_recorder
}

set ::turtles::persistence::lambda::script [file normalize [info script]]

proc ::turtles::persistence::lambda::add_proc_id {procId procName timeDefined} {
	return [subst {
		::turtles::persistence::stage0 eval {
			INSERT INTO proc_ids (proc_id, proc_name, time_defined)
			VALUES($procId, '$procName', $timeDefined)
			ON CONFLICT DO NOTHING;
		}
	}]
}

proc ::turtles::persistence::lambda::add_call {callerId calleeId traceId timeEnter} {
	return [subst {
		::turtles::persistence::stage0 eval {
			INSERT INTO call_pts (caller_id, callee_id, trace_id, time_enter)
			VALUES($callerId, $calleeId, $traceId, $timeEnter);
		}
	}]
}

proc ::turtles::persistence::lambda::update_call {callerId calleeId traceId timeLeave} {
	return [subst {
		::turtles::persistence::stage0 eval {
			UPDATE call_pts SET time_leave = $timeLeave
			WHERE caller_id = $callerId AND callee_id = $calleeId AND trace_id = $traceId AND time_leave IS NULL;
		}
	}]
}


proc ::turtles::persistence::lambda::stop_scheduler {recorderThread} {
	return [subst {
		::turtles::persistence::stop_finalizer $recorderThread ::turtles::persistence::stage0 ::turtles::persistence::stage1
		set ::turtles::persistence::scheduler_off 1
	}]
}

proc ::turtles::persistence::lambda::stop_recorder {} {
	return {
		::turtles::persistence::close_stage ::turtles::persistence::stage1
		::turtles::persistence::close_stage ::turtles::persistence::stage0
	}
}

package provide turtles::persistence::lambda 0.1
