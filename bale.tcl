#!/usr/bin/env tclsh

package require sqlite3

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
#
# NB: The current implementation is incomplete and as such will not work.
namespace eval ::turtles::bale {
	variable prelude
	namespace export find_connected_procs init recv prelude
}

set ::turtles::bale::prelude {
	package require turtles::bale
}

## Groups procs which are connected by invocation into sets.
#
# The underlying implementation follows the Gallager-Humblet-Spira algorithm for MST.
# (cf. https://sites.google.com/site/gopalpandurangan/dnabook.pdf, pp. 102-106)
#
# A k-machine model is simulated using threads as stand-ins for machines.
# The phases of the algorithm are roughly defined as follows:
#
# Phase 0: Load call records from storage and balance across local storage of machines.
# Copy neighbors collection to outer edges and sort by call count in descending order.
# Signal to k-machine model threads to prepare for MST phases.
#
# Phase 1: Find Maximum Outgoing Edge (MOE) for each MST fragment.
#
# Phase 2: Merge MST fragments along found MOEs.
#
# Phase 3: Check for termination condition. If not done, go to phase 1. Otherwise, go to phase 4.
# The algorithm terminates when each node in the graph has no adjacent edges radiating out to
# another node not in the MST fragment to which it belongs.
#
# Phase 4: Summarize results.
#
# \param[in] db the sqlite database from which to pull trace information
# \param[in] k the number of threads in the k-machine model for performing the distributed MST (default: 1, i.e., non-distributed)
# \param[in] callThreshold the minimum edge weight for a call to be considered (default: 0, i.e., at least once)
proc ::turtles::bale::find_connected_procs {db {k 1} {callThreshold 0}} {
	# Start k-machine model threads.
	::turtles::kmm::start $k $::turtles::bale::prelude ::turtles::bale::init ::turtles::bale::recv
	# Open sqlite DB and populate threads with proc IDs (nodes) assigned per thread by a load-balancing hash.
	sqlite3 ::turtles::bale::procs_db $db
	set msgv [dict create]
	::turtles::bale::procs_db eval {
		SELECT proc_id, proc_name FROM proc_ids;
	} {
		dict lappend msgv [::turtles::kmm::machine_hash $proc_id] $proc_id $proc_name
	}
	::turtles::kmm::scatterv {add_proc} $msgv
	# Populate proc ID nodes with call edges from aggregate caller/callee view.
	set msgv [dict create]
	::turtles::bale::procs_db eval {
		SELECT caller_id, callee_id, COUNT(*) AS calls FROM call_pts GROUP BY caller_id, callee_id;
	} {
		set caller_machine [::turtles::kmm::machine_hash $caller_id]
		set callee_machine [::turtles::kmm::machine_hash $callee_id]
		dict lappend msgv $caller_machine $caller_id $callee_id $calls
		if { $caller_machine != $callee_machine } {
			dict lappend msgv $callee_machine $callee_id $caller_id $callee_id $calls
		}
	}
	::turtles::kmm::scatterv {add_call} $msgv
	set msgv [dict create]
	for {set i 0} {$i < $k} {incr i} {
		dict set msgv $i 0
	}
	# Kicks off chain of phases.
	::turtles::kmm::scatterv {phase_init} $msgv
	::turtles::kmm::wait_until_done
	::turtles::kmm::stop
}

## K-machine model worker thread for \c ::turtles::bale::find_connected_procs.
#
# The worker thread initializes its internal state and waits for commands to be send via ::thread::send.
#
# Actual handling of the commands is delegated to \c ::turtles::bale::recv.
proc ::turtles::bale::init {} {
	global ::turtles::bale::machineState
	# Initialize the machine state dictionary.
	set ::turtles::bale::machineState [::turtles::bale::machine::init]
}

## K-machine model message dispatcher for a single "machine".
#
# Given a command and concomitant arguments, this function determines the appropriate action to take.
#
# Most responses involve calling a handler function which returns a collection of messages to disseminate.
# In this way, each message processed triggers a cascade of responses which in turn trigger another cascade of messages
# in order to drive the computation forward.
#
# \param[in] cmd the message type, i.e., command to execute
# \param[in] cmdArgs the arguments for the given message type/command
proc ::turtles::bale::recv {cmd cmdArgs} {
	switch $cmd {
		# Generic phase commands
		phase_init  { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::phase_init ::turtles::bale::machineState $cmdArgs ] }
		phase_done  { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::phase1_done ::turtles::bale::machineState $cmdArgs ] }

		# Data-loading commands
		add_proc    { ::turtles::bale::handle::add_proc ::turtles::bale::machineState $cmdArgs }
		add_call    { ::turtles::bale::handle::add_call ::turtles::bale::machineState $cmdArgs }

		# Phase 0 commands
		prepare     { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::prepare  ::turtles::bale::machineState $cmdArgs ] }

		# Phase 1 commands
		find_moe    { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::find_moe  ::turtles::bale::machineState $cmdArgs ] }
		test_moe    { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::test_moe  ::turtles::bale::machineState $cmdArgs ] }
		req_root    { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::req_root  ::turtles::bale::machineState $cmdArgs ] }
		rsp_root    { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::rsp_root  ::turtles::bale::machineState $cmdArgs ] }
		found_moe   { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::found_moe ::turtles::bale::machineState $cmdArgs ] }
		notify_moe  { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::notify_moe ::turtles::bale::machineState $cmdArgs ] }

		# Phase 2 commands
		merge       { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::merge ::turtles::bale::machineState $cmdArgs ] }
		req_combine { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::req_combine ::turtles::bale::machineState $cmdArgs ] }
		new_root    { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::new_root ::turtles::bale::machineState $cmdArgs ] }

		# Phase 3 commands
		req_active  { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::req_active ::turtles::bale::machineState $cmdArgs ] }
		rsp_active  { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::rsp_active ::turtles::bale::machineState $cmdArgs ] }

		# Phase 4 commands
		# @TODO: Actually do something useful in aggregating the clusters. Like write records to a sqlite DB.
		summarize   { ::turtles::kmm::dict_scatterv [ ::turtles::bale::handle::rsp_active ::turtles::bale::machineState $cmdArgs ] }

		# Miscellaneous
		put_state   { puts stderr $::turtles::bale::machineState }
		bye         { ::turtles::kmm::bye }
		default     { ::turtles::bale::handle::invalid_cmd $cmd $cmdArgs }
	}
}

package provide turtles::bale 0.1
