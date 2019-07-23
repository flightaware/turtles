#!/usr/bin/env tclsh

package require turtles::kmm 0.1
package require turtles::bale::handle 0.1
package require turtles::bale::machine 0.1

## \file bale.tcl
# Provides the graph clustering algorithms for the history of proc calls recorded
# during a given run of a program. A group of turtles is called a bale, hence the
# filename.
#
# A minimum-spanning tree (MST) algorithm is used as an efficient method for
# finding connected components in the call graph. The user may specify a
# connection threshold to ignore proc links below a certain level of activity.
# By setting this threshold to zero (0), singletons in the call graph denote
# procs which are not called during the recorded experiment.
#
# The commands exposed by the \c ::turtles::bale namespace are necessarily
# post-hoc operations. As such the data needs to be persisted to disk in
# the form of a sqlite database.
namespace eval ::turtles::bale {
	namespace export find_connected_procs
}

## Groups procs which are connected by invocation into sets.
#
# \param[in] db the sqlite database from which to pull trace information
# \param[in] k the number of threads in the k-machine model for performing the distributed MST (default: 1, i.e., non-distributed)
# \param[in] callThreshold the minimum edge weight for a call to be considered (default: 0, i.e., at least once)
proc ::turtles::bale::find_connected_procs {db {k 1} {callThreshold 0}} {
	# Start k-machine model threads.
	::turtles::kmm::init $k ::turtles::bale::init ::turtles::bale::recv
	# Open sqlite DB and populate threads with proc IDs (nodes) assigned per thread by a load-balancing hash.
	sqlite3 ::turtles::bale::procs_db $db
	set msgv [dict create]
	::turtles::bale::procs_db eval {
		SELECT proc_id, proc_name FROM proc_ids;
	} values {
		dict lappend [::turtles::kmm::machine_hash $values(proc_id)] $values(proc_id) $values(proc_hash)
	}
	::turtles::kmm::scatterv {add_proc} $msgv
	# Populate proc ID nodes with call edges from aggregate caller/callee view.
	set msgv [dict create]
	::turtles::bale::procs_db eval {
		SELECT caller_id callee_id calls FROM call_pts;
	} values {
		set caller_machine [::turtles::kmm::machine_hash $values(caller_id)]
		set callee_machine [::turtles::kmm::machine_hash $values(caller_id)]
		dict lappend $caller_machine $values(caller_id) $values(callee_id) $values(call)
		if { $caller_machine != $callee_machine } {
			dict lappend $callee_machine $values(caller_id) $values(caller_id) $values(callee_id) $values(call)
		}
	}
	::turtles::kmm::scatterv {add_call} $msgv
	# Phase 0: Signal to k-machine model threads to prepare for MST phases.
	# Copy neighbors collection to active edges and sort by call count in descending order.
	# While MST forest is incomplete...
	#   Signal to k-machine model threads to kick off "Find MOE" phase.
	#   Phase 1: Find MOE. Wait for forest to be traversed.
	#   Signal to k-machine model to kick off "Merge" phase.
	#   Phase 2: Merge. Wait for new forest of roots to be updated.
}

## K-machine model worker thread for \c ::turtles::bale::find_connected_procs.
#
# The worker thread initializes its internal state and waits for commands to be send via ::thread::send.
#
# Actual handling of the commands is delegated to the ::turtles::bale::recv.
#
# \param[in] i the k-machine identifier
# \param[in] k the number of machines participating in the k-machine model
proc ::turtles::bale::init {} {
	global ::turtles::bale::machineState
	# Initialize the machine state dictionary.
	set ::turtles::bale::machineState [::turtles::bale::machine::init]
}

proc ::turtles::bale::recv {cmd cmdArgs} {
	switch $cmd {
		# Generic phase commands
		phase_init { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::phase_init ::turtles::bale::machineState $cmdArgs ] }
		phase_done { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::phase1_done ::turtles::bale::machineState $cmdArgs ] }

		# Phase 1 commands
		add_proc   { ::turtles::bale::handle::add_proc ::turtles::bale::machineState $cmdArgs }
		add_call   { ::turtles::bale::handle::add_call ::turtles::bale::machineState $cmdArgs }
		find_moe   { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::find_moe  ::turtles::bale::machineState $cmdArgs ] }
		test_moe   { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::test_moe  ::turtles::bale::machineState $cmdArgs ] }
		req_root   { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::req_root  ::turtles::bale::machineState $cmdArgs ] }
		rsp_root   { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::rsp_root  ::turtles::bale::machineState $cmdArgs ] }
		found_moe  { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::found_moe ::turtles::bale::machineState $cmdArgs ] }

		# Phase 3 commands
		req_active { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::req_active ::turtles::bale::machineState $cmdArgs ] }
		rsp_active { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::rsp_active ::turtles::bale::machineState $cmdArgs ] }
		# Miscellaneous
		put_state { puts stderr $::turtles::bale::machineState }
		default   { ::turtles::bale::handle::invalid_cmd $cmd $cmdArgs }
	}
}

package provide turtles::bale 0.1
