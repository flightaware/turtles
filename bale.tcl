#!/usr/bin/env tclsh

package require turtles::kmm 0.1
package require turtles::bale::handle 0.1

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
	# Broadcast (k-machine index -> thread) map to all k-machine model threads.
	# Open sqlite DB and populate threads with proc IDs (nodes) assigned per thread by a load-balancing hash.
	# Populate proc ID nodes with call edges from aggregate caller/callee view.
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
proc ::turtles::bale::worker {i k} {
	global ::turtles::kmm::myself
	global ::turtles::kmm::machines
	global ::turtles::bale::procs
	global ::turtles::bale::roots
	# Set the machine ID.
	set ::turtles::kmm::myself $i
	# Set the number of participating machines.
	set ::turtles::kmm::machines $k
	# Initialize the proc node dictionary.
	set ::turtles::bale::procs [dict create]
	# Initialize the root proc list.
	set ::turtles::bale::roots [list]
	interp alias {} ::turtles::kmm::recv {} ::turtles::bale::recv
	thread::wait
}

proc ::turtles::bale::recv {cmd args} {
	switch $cmd {
		add_proc  { ::turtles::bale::handle::add_proc ::turtles::bale::procs $args }
		add_call  { ::turtles::bale::handle::add_call ::turtles::bale::procs $args }
		find_moe  { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::find_moe  ::turtles::bale::procs $args ] }
		found_moe { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::found_moe ::turtles::bale::procs $args ] }
		test_moe  { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::test_moe  ::turtles::bale::procs $args ] }
		req_root  { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::req_root  ::turtles::bale::procs $args ] }
		rsp_root  { ::turtles::bale::dict_scatterv [ ::turtles::bale::handle::rsp_root  ::turtles::bale::procs $args ] }
		default   { ::turtles::bale::handle::invalid_cmd $cmd $args }
	}
}

package provide turtles::bale 0.1