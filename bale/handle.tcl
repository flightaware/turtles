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
	namespace export add_proc add_call find_moe test_moe req_root rsp_root found_moe init_msgv fix_msgv init_proc_node
}

proc ::turtles::bale::handle::init_proc_node {procId procName} {
	return [ dict create \
				 procId $procId \
				 procName $procName \
				 neighbors [dict create] \
				 outerEdges [list] \
				 innerEdges [list] \
				 root $procId \
				 parent $procId \
				 children [list] \
				 moe [list $procId $procId 0] \
				 awaiting 0 \
				 state {IDLE} ]
}

## Adds proc nodes to the dictionary of procs.
#
# Each node is itself represented as a dictionary with the following fields:
# * \c procId: the proc name hash
# * \c procName: the fully-qualified
# * \c neighbors: a dictionary of neighbors. Each neighbor is represented as a {int int} list indicating the other edge terminus and weight, respectively.
# * \c outerEdges: a list of adjacent node labels outside of the node's current MST fragment
# * \c innerEdges: a list of adjacent node labels within the node's current MST fragment
# * \c root: the \c procId of the MST fragment root which coordinates downcast and convergecast within the fragment
# * \c parent: the \c procId of the proc node's immediate parent in the MST. A root node is its own parent.
# * \c children: a \c procId list of the proc node's children in the MST
# * \c moe: maximum outgoing edge in the MST fragment. This is represented as a {int int int} list representing callerId, calleeId, and calls (edge weight), respectively.
# * \c awaiting: A decrement counter used to keep state during phase work.
#
# \param[in] procsRef a name reference to the worker's dictionary of proc nodes
# \param[in] args a list with type stride {int string} providing \c procId and \c procName
proc ::turtles::bale::handle::add_proc {procsRef cmdArgs} {
	upvar $procsRef procs
	# args: int string ...
	foreach {procId procName} $cmdArgs {
		dict set procs $procId [init_proc_node $procId $procName]
	}
}

## Add the calls, i.e., edge weight, from a call edge to the respective caller and callee.
# Note that this step erases the directionality of the connection between two procs.
#
# \param[in] procsRef a name reference to the worker's dictionary of proc nodes
# \param[in] args a list with type stride {int int int} providing \c callerId, \c calleeId, and \c calls (i.e., edge weight), respectively.
proc ::turtles::bale::handle::add_call {procsRef cmdArgs} {
	upvar $procsRef procs
	# args: {int int int}
	foreach {callerId calleeId calls} $cmdArgs {
		if {$callerId == $calleeId} {
			# Ignore self-reference. This is MST construction, not cycle detection.
			continue
		}
		# If the caller is on this machine, add or update the edge.
		if { [dict exists $procs $callerId] } {
			dict with procs $callerId { dict incr neighbors $calleeId $calls }
		}
		# If the callee is on this machine, add or update the edge.
		if { [dict exists $procs $calleeId] } {
			dict with procs $calleeId { dict incr neighbors $callerId $calls }
		}
	}
}

## Trigger a search of the maximum outgoing edge (MOE) on the subtrees rooted by the given proc nodes.
#
# Calling this invokes a downcast of the MOE search and subsequent local MOE test when a given subtree
# root has exhausted the search beneath it.
#
# \param[in] procsRef a name reference to the worker's dictionary of proc nodes
# \param[in] a \c procId list corresponding to the roots of subtrees to search
proc ::turtles::bale::handle::find_moe {procsRef cmdArgs} {
	upvar $procsRef procs
	# Initialize the buffers of find_moe and test_moe messages to send.
	set msgv [init_msgv {find_moe} {test_moe}]
	# args: int ...
	# Iterate over the list of targeted proc nodes to pass the find_moe message onto the node's children in the MST.
	foreach procId $cmdArgs {
		if { [dict exists $procs $procId state] &&
			 [dict exists $procs $procId awaiting] &&
			 [dict exists $procs $procId children] } {
			dict with procs $procId {
				# State check - only proceed if in valid state for this message.
				if { $state != {IDLE} } { continue }
				# Reset the awaiting counter to the number of children from
				# which the proc node expects messages plus 1 for itself.
				set awaiting [ expr { [llength $children] + 1 } ]
				set state {WAIT_MOE}
				if { $awaiting == 1 } {
					dict update msgv {test_moe} _msg { dict lappend _msg [machine_hash $procId] $procId }
				} else {
					foreach childId $children {
						# Correlate the child with the machine where it resides.
						dict update msgv {find_moe} _msg { dict lappend _msg [machine_hash $childId] $childId }
					}
				}
			}
		}
	}
	return [fix_msgv $msgv]
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
# \param[in] procsRef a name reference to the worker's dictionary of proc nodes
# \param[in] a \c procId list of proc nodes to perform local MOE tests
proc ::turtles::bale::handle::test_moe {procsRef cmdArgs} {
	upvar $procsRef procs
	# Initialize the buffer of found_moe messages to send.
	set msgv [init_msgv {found_moe} {req_root}]
	# args: int ...
	foreach fromId $cmdArgs {
		if { [dict exists $procs $fromId state] &&
			 [dict exists $procs $fromId outerEdges] &&
			 [dict exists $procs $fromId parent] &&
			 [dict exists $procs $fromId moe] } {
			dict with procs $fromId {
				# State check - only proceed if in valid state for this message.
				if { $state != {WAIT_MOE} } { continue }
				if { [llength $outerEdges] == 0 } {
					# proc has no outgoing edges
					# NB: root check is done in found_moe. It's ok to send found_moe to parent from here when parent is root.
					dict update msgv {found_moe} _msg { dict lappend _msg [machine_hash $parent] $parent $moe }
				} else {
					# NB: outerEdges MUST be sorted already in descending order by edge weight (calls) for this to work.
					set toId [lindex $outerEdges 0]
					dict update msgv {req_root} _msg { dict lappend _msg [machine_hash $toId] $fromId $toId }
				}
			}
		}
	}
	return [fix_msgv $msgv]
}

## Triggers requests for root information from one set of nodes to another.
#
# \param[in] procsRef a name reference to the worker's dictionary of proc nodes
# \param[in] args a list with {int int} stride indicating sender and recipient, respectively
proc ::turtles::bale::handle::req_root {procsRef cmdArgs} {
	upvar $procsRef procs
	# Initialize the buffer of rsp_root messages to send.
	set msgv [init_msgv {rsp_root}]
	# args: int int ...
	foreach {fromId toId} $cmdArgs {
		if { [dict exists $procs $toId root] } {
			# No state check required here - this is a reflexive response that does not alter
			# the state of the recipient.
			dict with procs $toId {
				dict update msgv {rsp_root} _msg { dict lappend _msg [machine_hash $fromId] $fromId $root }
			}
		}
	}
	return [fix_msgv $msgv]
}

## Triggers responses to root information requests back to the original senders.
#
# \param[in] procsRef a name reference to the worker's dictionary of proc nodes
# \param[in] args a list with {int int} stride indicating original sender and recipient root id, respectively.
proc ::turtles::bale::handle::rsp_root {procsRef cmdArgs} {
	upvar $procsRef procs
	# Initialize the buffer of found_moe messages to send.
	set msgv [init_msgv {test_moe} {found_moe}]
	# args: int int ...
	foreach {procId rspRoot} $cmdArgs {
		if { [dict exists $procs $procId state] &&
			 [dict exists $procs $procId outerEdges] &&
			 [dict exists $procs $procId innerEdges] &&
			 [dict exists $procs $procId neighbors] &&
			 [dict exists $procs $procId root] } {
			dict with procs $procId {
				# State check - only proceed if in valid state for this message and there are outer edges to work with.
				if { $state != {WAIT_MOE} || [llength $outerEdges] == 0 } { continue }
				if { $root eq $rspRoot } {
					# Internal edge. Move on to next test.
					lappend innerEdges [lindex $outerEdges 0]
					set outerEdges [lrange $outerEdges 1 end]
					dict update msgv {test_moe} _msg { dict lappend _msg [machine_hash $procId] $procId }
				} else {
					# Outgoing edge. 
					set calleeId [lindex $outerEdges 0]
					set calls [dict get $neighbors $calleeId]
					# Enqueue a found message to itself. That way we don't have to copy paste the comparison logic.
					dict update msgv {found_moe} _msg { dict lappend _msg [machine_hash $procId] $procId [list $procId $calleeId $calls] }
				}
			}
		}
	}
	return [fix_msgv $msgv]
}


## Triggers delivery of a subtree branch MOE to the subtree root.
#
# \param[in] procsRef a name reference to the worker's dictionary of proc nodes
# \params args a list with {int {int int int}} stride indicating the subtree root and the branch MOE, respectively
proc ::turtles::bale::handle::found_moe {procsRef cmdArgs} {
	upvar $procsRef procs
	# Initialize the buffer of test_moe messages to send.
	set msgv [init_msgv {test_moe} {found_moe}]
	# args: int {int int int} ...
	foreach {procId foundMOE} $cmdArgs {
		if { [dict exists $procs $procId state] &&
			 [dict exists $procs $procId awaiting] &&
			 [dict exists $procs $procId moe] &&
			 [dict exists $procs $procId parent] &&
			 [dict exists $procs $procId procId] } {
			lassign $foundMOE callerId calleeId calls
			# Decrement the awaiting counter of the recipient.
			dict with procs $procId {
				# State check - only proceed if in valid state for this message.
				if { $state != {WAIT_MOE} } { continue }
				incr awaiting -1
				if { $callerId != $calleeId && $calls > [lindex $moe 2] } {
					set moe $foundMOE
				}
				# Check if all the children have reported back.
				# NB: awaiting field is initialized to children + 1 to include
				# any MOE found during the immediate local test subphase.
				if { $awaiting == 1 } {
					# If so, move this proc node to the test subphase.
					dict update msgv {test_moe} _msg { dict lappend _msg [machine_hash $procId] $procId }
				} elseif { $awaiting == 0 } {
					set state {DONE_MOE}
					if { $parent == $procId } {
						# @TODO: MOE has been found for fragment. Initiate downcast of tree-wide MOE.
					} else {
						# Report subtree MOE to parent.
						dict update msgv {found_moe} _msg { dict lappend _msg [machine_hash $parent] $parent $moe }
					}
				}
			}
		}
	}
	return [fix_msgv $msgv]
}

## Generic default handler for invalid command types.
#
# NB: This throws an error. Perhaps it would be better to provide some sort of notification rather than
# creating a scenario where an invalid command could tank a k-machine participant.
#
# \param[in] cmd the invalid command
# \param[in] args the putative args associated with the invalid command
proc ::turtles::bale::handle::invalid_cmd {cmd args} {
	error "::turtles::bale::handle ($::turtles::kmm::myself/$::turtles::kmm::machines): unknown command '$cmd'"
}

## Initializes a command message return structure for event handlers.
#
# The structure is populated as a dictionary of dictionaries keyed first
# by command type and next by k-machine model identifier.
#
# \param[in] args variadic list of command types
proc ::turtles::bale::handle::init_msgv {args} {
	set msgv [dict create]
	foreach key $args {
		dict set msgv $key [dict create]
	}
	return $msgv
}
## Strips command type entries from a command message return structure
# in the case where there are no messages to be sent of that command type.
#
# This obviates unnecessary thread communication between k-machine model
# participants when there is no work to be done.
#
# \param[in] msgv the command message return structure to be pruned
proc ::turtles::bale::handle::fix_msgv {msgv} {
	return [ dict filter $msgv script {k v} { dict size $v } ]
}

package provide turtles::bale::handle 0.1
