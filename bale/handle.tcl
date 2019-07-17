#!/usr/bin/env tclsh

package require turtles::kmm 0.1
namespace import ::turtles::kmm::*

## \file handle.tcl
# Provides the state-change handlers for receipt of commands by the k-machine model workers.
# The handlers may or may not return a dictionary of dictionaries keyed by command in the
# outermost layer and by machine ID in the next layer with the command args as the leaf value.
#
# This abstraction affords a means for unit-testing the handlers and checking the return
# values and/or state of the proc node dictionary passed by name reference.
namespace eval ::turtles::bale::handle {
	namespace export add_proc add_call find_moe test_moe req_root rsp_root found_moe
}

## Adds proc nodes to the dictionary of procs.
#
# Each node is itself represented as a dictionary with the following fields:
# * \c procId: the proc name hash
# * \c procName: the fully-qualified
# * \c neighbors: a dictionary of neighbors. Each neighbor is represented as a {int int} list indicating the other edge terminus and weight, respectively.
# * \c outerEdges: a list of edges radiating out of the MST fragment from the proc node
# * \c innerEdges: a list of edges connecting other nodes within the MST fragment to the proc node
# * \c root: the \c procId of the MST fragment root which coordinates downcast and convergecast within the fragment
# * \c parent: the \c procId of the proc node's immediate parent in the MST. A root node is its own parent.
# * \c children: a \c procId list of the proc node's children in the MST
# * \c moe: maximum outgoing edge in the MST fragment. This is represented as a {int int int} list representing callerId, calleeId, and calls (edge weight), respectively.
# * \c awaiting: A decrement counter used to keep state during phase work.
#
# \param[in] procRef a name reference to the worker's dictionary of proc nodes
# \param[in] args a list with type stride {int string} providing \c procId and \c procName
proc ::turtles::bale::handle::add_proc {procRef args} {
	upvar $procRef procs
	# args: int string ...
	foreach {procId procName} $args {
		dict set $procs $procId [ dict create \
									  procId $procId \
									  procName $procName \
									  neighbors [dict create] \
									  outerEdges [list] \
									  innerEdges [list] \
									  root $procId \
									  parent $procId \
									  children [list] \
									  moe {$procId $procId 0} \
									  awaiting 0
								 ]
		lappend $roots $procId
	}
}

## Add the calls, i.e., edge weight, from a call edge to the respective caller and callee.
# Note that this step erases the directionality of the connection between two procs.
#
# \param[in] procRef a name reference to the worker's dictionary of proc nodes
# \param[in] args a list with type stride {int int int} providing \c callerId, \c calleeId, and \c calls (i.e., edge weight), respectively.
proc ::turtles::bale::handle::add_call {procRef args} {
	upvar $procRef procs
	# args: {int int int}
	foreach {callerId calleeId calls} $args {
		if {callerId == calleeId} {
			# Ignore self-reference. This is MST construction, not cycle detection.
			continue
		}
		# If the caller is on this machine, add or update the edge.
		if { [dict exists $procs $callerId] } {
			dict update $procs $callerId _caller { dict update $_caller neighbors _neighbors { dict incr $_neighbors $calleeId $calls } }
		}
		# If the callee is on this machine, add or update the edge.
		if { [dict exists $procs $calleeId] } {
			dict update $procs $calleeId _callee { dict update $_callee neighbors _neighbors { dict incr $_neighbors $callerId $calls } }
		}
	}
}

## Trigger a search of the maximum outgoing edge (MOE) on the subtrees rooted by the given proc nodes.
#
# Calling this invokes a downcast of the MOE search and subsequent local MOE test when a given subtree
# root has exhausted the search beneath it.
#
# \param[in] procRef a name reference to the worker's dictionary of proc nodes
# \param[in] a \c procId list corresponding to the roots of subtrees to search
proc ::turtles::bale::handle::find_moe {procRef args} {
	upvar $procRef procs
	# Initialize the buffers of find_moe and test_moe messages to send.
	set findMsgs [dict create]
	set testMsgs [dict create]
	# args: int ...
	# Iterate over the list of targeted proc nodes to pass the find_moe message onto the node's children in the MST.
	foreach {procId} $args {
		set children [dict get [dict get $procs $procId] children]
		# Reset the awaiting counter to the number of children from which the proc node expects messages plus 1 for itself.
		dict update $procs $procId _proc { dict update $_proc awaiting _awaiting { set _awaiting [ expr { [llength $children] + 1 } ] } }
		if { [llength $children] == 0 } {
			dict lappend $testMsgs [machine_hash $procId] $procId
		} else {
			foreach childId $children {
				# Correlate the child with the machine where it resides.
				dict lappend $findMsgs [machine_hash $childId] $childId
			}
		}
	}
	return [dict create {find_moe} $findMsgs {test_moe} $testMsgs]
}

## Trigger local proc node tests for adjacent MOE.
#
# This operation methodically checks the sorted list of remaining outgoing edges.
# The node first requests the root information of the allegedly outer neighbor.
# If the outer neighbor responds with the same root as the requesting node, it is moved
# to the inner neighbor list and the search continues until an outer neighbor is found
# or the list of outer neighbors is exhausted.
#
# If an outer neighbor is found, its edge weight is compared against
# the MOE edge weight returned by the node's subtree, and the final MOE
# is convergecast to the MST fragment root via the \c found_moe message.
#
# If the list of outer neighbors is exhausted, the subtree MOE is
# forwarded onto the root in the same manner. If there is no valid
# subtree MOE, the invalid default MOE is forwarded in its stead
# and categorically ignored by ancestors.
#
# \param[in] procRef a name reference to the worker's dictionary of proc nodes
# \param[in] a \c procId list of proc nodes to perform local MOE tests
proc ::turtles::bale::handle::test_moe {procRef args} {
	upvar $procRef procs
	# Initialize the buffer of found_moe messages to send.
	set foundMsgs [dict create]
	# Initialize the buffer of req_root messages to send.
	set reqMsgs [dict create]
	# args: int ...
	foreach fromId $args {
		dict with [dict get $procs $fromId] {
			if { [llength $outerEdges] == 0 } {
				# proc has no outgoing edges
				dict lappend $foundMsgs [machine_hash $parent] $moe
			} else {
				# NB: outerEdges MUST be sorted already in descending order by edge weight (calls) for this to work.
				lassign {toId _} [lindex $outerEdges 0]
				dict lappend $reqMsgs [machine_hash $toId] $fromId $toId
			}
		}
	}
	return [dict create {found_moe} $foundMsgs {req_root} $reqMsgs]
}

## Triggers requests for root information from one set of nodes to another.
#
# \param[in] procRef a name reference to the worker's dictionary of proc nodes
# \param[in] args a list with {int int} stride indicating sender and recipient, respectively
proc ::turtles::bale::handle::req_root {args} {
	upvar $procRef procs
	# Initialize the buffer of rsp_root messages to send.
	set rspMsgs [dict create]
	# args: int int ...
	foreach {fromId toId} $args {
		dict with [dict get $procs $toId] {
			dict lappend $rspMsgs [machine_hash $fromId] $fromId $root
		}
	}
	return [dict create {rsp_root} $rspMsgs]
}

## Triggers responses to root information requests back to the original senders.
#
# \param[in] procRef a name reference to the worker's dictionary of proc nodes
# \param[in] args a list with {int int} stride indicating original sender and recipient root id, respectively.
proc ::turtles::bale::handle::rsp_root {procRef args} {
	upvar $procRef procs
	# Initialize the buffer of found_moe messages to send.
	set foundMsgs [dict create]
	# Initialize the buffer of test_moe messages to send.
	set testMsgs [dict create]
	# args: int int ...
	foreach {procId rspRoot} $args {
		dict update $procs $procId _proc {
			dict with $_proc {
				if { $root eq $rspRoot } {
					set outerEdges [lrange $outerEdges 1 end]
					lappend $testMsgs [machine_hash $procId] $procId
				} else {
					lassign {calleeId calls} [lindex $outerEdges 0]
					lappend $foundMsgs [machine_hash] $procId [list $procId $calleeId $calls]
				}
			}
		}
	}
	return [dict create {found_moe} $foundMsgs {test_moe} $testMsgs]
}


## Triggers delivery of a subtree branch MOE to the subtree root.
#
# \param[in] procRef a name reference to the worker's dictionary of proc nodes
# \params args a list with {int {int int int}} stride indicating the subtree root and the branch MOE, respectively
proc ::turtles::bale::handle::found_moe {procRef args} {
	upvar $procRef procs
	# Initialize the buffer of test_moe messages to send.
	set testMsgs [dict create]
	# args: int {int int int} ...
	foreach {procId foundMOE} $args {
		lassign {callerId calleeId calls} $foundMOE
		# Decrement the awaiting counter of the recipient.
		dict update $procs $procId _proc { dict incr $_proc awaiting -1 }
		dict update $procs $procId _proc {
			dict update $_proc moe _currentMOE {
				if { $callerId != $calleeId && calls > [lindex _currentMOE 2] } {
					set _currentMOE $foundMOE
				}
			}
		}
		# Check if all the children have reported back.
		# NB: awaiting field is initialized to children + 1 to include
		# any MOE found during the immediate local test subphase.
		if { [dict get [dict get $procs $procId] awaiting] == 1 } {
			# If so, move this proc node to the test subphase.
			dict lappend $testMsgs [machine_hash $procId] $childId
		}
	}
	return [dict create {test_moe} $testMsgs]
}

proc ::turtles::bale::handle::invalid_cmd {cmd args} {
	error "::turtles::bale::handle ($::turtles::kmm::myself/$::turtles::kmm::machines): unknown command '$cmd'"
}

package provide turtles::bale::handle 0.1
