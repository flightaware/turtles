#!/usr/bin/env tclsh

package require Tcl 8.5 8.6

package require turtles::kmm 0.1
package require turtles::bale::proc 0.1
package require turtles::bale::machine 0.1

## \file handle.tcl
# Provides the state-change handlers for receipt of commands by the k-machine model workers.
# The handlers may or may not return a dictionary of dictionaries keyed by command in the
# outermost layer and by machine ID in the next layer with the command args as the leaf value.
#
# This abstraction affords a means for unit-testing the handlers and checking the return
# values and/or state of the proc node dictionary passed by name reference.
namespace eval ::turtles::bale::handle {
	namespace export \
		init_msgv fix_msgv invalid_cmd \
		add_proc add_call \
		phase_init phase_done \
		find_moe test_moe req_root rsp_root found_moe notify_moe \
		merge req_combine \
		req_active rsp_active \
		put_state
}

## Adds proc nodes to the dictionary of procs.
#
# See \c ::turtles::bale::proc for the definition of a proc node.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a list with type stride {int string} providing \c procId and \c procName
proc ::turtles::bale::handle::add_proc {machineStateP cmdArgs} {
	upvar $machineStateP machineState
	dict with machineState {
		if { $phase != 0 } { return }
		foreach {procId procName} $cmdArgs {
			dict set procs $procId [::turtles::bale::proc::init $procId $procName]
			dict set roots $procId {}
			incr procsActive
		}
	}
}

## Add the calls, i.e., edge weight, from a call edge to the respective caller and callee.
# Note that this step erases the directionality of the connection between two procs.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a list with type stride {int int int} providing \c callerId, \c calleeId, and \c calls (i.e., edge weight), respectively.
proc ::turtles::bale::handle::add_call {machineStateP cmdArgs} {
	upvar $machineStateP machineState
	dict with machineState {
		if { $phase != 0 } { return }
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
}

## Trigger the pre-GHS initialization of all the nodes. Order the outgoing edges by decreasing weight.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a \c procId list corresponding to the roots of subtrees to prepare
proc ::turtles::bale::handle::prepare {machineStateP cmdArgs} {
	set msgv [init_msgv {phase_done}]
	upvar $machineStateP machineState
	dict with machineState {
		foreach procId $cmdArgs {
			# Sort neighbors by decreasing call weight.
			set outerEdges [dict keys [lsort -stride 2 -index 2 $neighbors]]
			incr procsInPhase -1
		}

		# Check if machine has finished prepping nodes.
		if { $procsInPhase == 0 } {
			for {set i 0} {i < $::turtles::kmm::machines} {incr i} {
				# Notify all other machines that this machine has finished phase 1 for all hosted proc nodes.
				dict update msgv {phase_done} _msg { dict lappend _msg $i $::turtles::kmm::myself }
			}
		}

	}
	return [fix_msgv $msgv]
}

## Trigger a search of the maximum outgoing edge (MOE) on the subtrees rooted by the given proc nodes.
#
# Calling this invokes a downcast of the MOE search and subsequent local MOE test when a given subtree
# root has exhausted the search beneath it.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a \c procId list corresponding to the roots of subtrees to search
proc ::turtles::bale::handle::find_moe {machineStateP cmdArgs} {
	# Initialize the buffers of find_moe and test_moe messages to send.
	set msgv [init_msgv {find_moe} {test_moe}]
	upvar $machineStateP machineState
	dict with machineState {
		# Iterate over the list of targeted proc nodes to pass the find_moe message onto the node's children in the MST.
		foreach procId $cmdArgs {
			if { [ ::turtles::bale::machine::has_proc machineState $procId ] } {
				dict with procs $procId {
					# State check - only proceed if in valid state for this message.
					if { $state != {IDLE} } { continue }
					# Reset the awaiting counter to the number of children from
					# which the proc node expects messages plus 1 for itself.
					set awaiting [ expr { [llength $children] + 1 } ]
					set state {WAIT_MOE}
					if { $awaiting == 1 } {
						dict update msgv {test_moe} _msg { dict lappend _msg [::turtles::kmm::machine_hash $procId] $procId }
					} else {
						foreach childId $children {
							# Correlate the child with the machine where it resides.
							dict update msgv {find_moe} _msg { dict lappend _msg [::turtles::kmm::machine_hash $childId] $childId }
						}
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
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a \c procId list of proc nodes to perform local MOE tests
proc ::turtles::bale::handle::test_moe {machineStateP cmdArgs} {
	# Initialize the buffer of found_moe messages to send.
	set msgv [init_msgv {found_moe} {req_root}]
	upvar $machineStateP machineState
	dict with machineState {
		foreach fromId $cmdArgs {
			if { [ ::turtles::bale::machine::has_proc machineState $procId ] } {
				dict with procs $fromId {
					# State check - only proceed if in valid state for this message.
					if { $state != {WAIT_MOE} } { continue }
					if { [llength $outerEdges] == 0 } {
						# proc has no outgoing edges
						# NB: root check is done in found_moe. It's ok to send found_moe to parent from here when parent is root.
						dict update msgv {found_moe} _msg { dict lappend _msg [::turtles::kmm::machine_hash $parent] $parent $moe }
					} else {
						# NB: outerEdges MUST be sorted already in descending order by edge weight (calls) for this to work.
						set toId [lindex $outerEdges 0]
						dict update msgv {req_root} _msg { dict lappend _msg [::turtles::kmm::machine_hash $toId] $toId $fromId}
					}
				}
			}
		}
	}
	return [fix_msgv $msgv]
}

## Triggers requests for root information from one set of nodes to another.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a list with {int int} stride indicating recipient and sender, respectively
proc ::turtles::bale::handle::req_root {machineStateP cmdArgs} {
	# Initialize the buffer of rsp_root messages to send.
	set msgv [init_msgv {rsp_root}]
	upvar $machineStateP machineState
	dict with machineState {
		foreach {toId fromId} $cmdArgs {
			if { [ ::turtles::bale::machine::has_proc machineState $toId ] } {
				# No state check required here - this is a reflexive response that does not alter
				# the state of the recipient.
				dict with procs $toId {
					dict update msgv {rsp_root} _msg { dict lappend _msg [::turtles::kmm::machine_hash $fromId] $fromId $root }
				}
			}
		}
	}
	return [fix_msgv $msgv]
}

## Triggers responses to root information requests back to the original senders.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a list with {int int} stride indicating original sender id and recipient root id, respectively.
proc ::turtles::bale::handle::rsp_root {machineStateP cmdArgs} {
	# Initialize the buffer of found_moe messages to send.
	set msgv [init_msgv {test_moe} {found_moe}]
	upvar $machineStateP machineState
	dict with machineState {
		foreach {procId rspRoot} $cmdArgs {
			if { [ ::turtles::bale::machine::has_proc machineState $procId ] } {
				dict with procs $procId {
					# State check - only proceed if in valid state for this message and there are outer edges to work with.
					if { $state != {WAIT_MOE} || [llength $outerEdges] == 0 } { continue }
					if { $root == $rspRoot } {
						# Internal edge. Move on to next test.
						lappend innerEdges [lindex $outerEdges 0]
						set outerEdges [lrange $outerEdges 1 end]
						dict update msgv {test_moe} _msg { dict lappend _msg [::turtles::kmm::machine_hash $procId] $procId }
					} else {
						# Outgoing edge.
						set calleeId [lindex $outerEdges 0]
						set calls [dict get $neighbors $calleeId]
						# Enqueue a found message to itself. That way we don't have to copy paste the comparison logic.
						dict update msgv {found_moe} _msg { dict lappend _msg [::turtles::kmm::machine_hash $procId] $procId [list $procId $calleeId $calls] }
					}
				}
			}
		}
	}
	return [fix_msgv $msgv]
}


## Triggers delivery of a subtree branch MOE to the subtree root.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \params[in] cmdArgs a list with {int {int int int}} stride indicating the subtree root and the branch MOE, respectively
proc ::turtles::bale::handle::found_moe {machineStateP cmdArgs} {
	# Initialize the buffer of test_moe messages to send.
	set msgv [init_msgv {test_moe} {found_moe}]
	upvar $machineStateP machineState
	dict with machineState {
		set unroots [list]
		set newroots [list]
		foreach {procId foundMOE} $cmdArgs {
			if { [ ::turtles::bale::machine::has_proc machineState $procId ] } {
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
						dict update msgv {test_moe} _msg { dict lappend _msg [::turtles::kmm::machine_hash $procId] $procId }
					} elseif { $awaiting == 0 } {
						set state {DONE_MOE}
						if { $parent == $procId } {
							# MOE has been found for fragment.
							if { $procId != [lindex $moe 0] } {
								# Add supplanted root ID to list of unroots.
								lappend unroots $procId
								lappend newroots [lindex $moe 0]
							}
							# Prepare downcast of tree-wide MOE.
							foreach childId $children {
								dict update msgv {notify_moe} _msg { dict lappend _msg [::turtles::kmm::machine_hash $childId] $childId $moe }
							}
						} else {
							# Report subtree MOE to parent.
							dict update msgv {found_moe} _msg { dict lappend _msg [::turtles::kmm::machine_hash $parent] $parent $moe }
						}
					}
				}
			}
		}
		# Remove supplanted roots.
		foreach procId $unroots {
			dict unset roots $procId
		}
		# Add usurping roots.
		foreach procId $newroots {
			dict set roots $procId {}
		}
	}
	return [fix_msgv $msgv]
}

## Triggers delivery of confirmed MOE to subtree.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a list with {int {int int int}} stride indicating the subtree root and global MOE, respectively
proc ::turtles::bale::handle::notify_moe {machineStateP cmdArgs} {
	set msgv [init_msgv {notify_moe} {phase1_done}]
	upvar $machineStateP machineState
	dict with machineState {
		foreach {procId MOE} $cmdArgs {
			if { [ ::turtles::bale::machine::has_proc machineState $procId ] } {
				dict with procs $procId {
					if { $state != {DONE_MOE} } { continue }
					# Set state to MERGE for next phase.
					set state {MERGE}
					set root [lindex $MOE 0]
					set moe $MOE
					# Decrement proc counter for phase 1.
					incr procsInPhase -1
					# Prepare downcast of tree-wide MOE.
					foreach childId $children {
						dict update msgv {notify_moe} _msg { dict lappend _msg [::turtles::kmm::machine_hash $childId] $childId $moe }
					}
				}
			}
		}

		# Check if machine has finished notifying all procs of tree-wise MOE.
		if { $procsInPhase == 0 } {
			for {set i 0} {i < $::turtles::kmm::machines} {incr i} {
				# Notify all other machines that this machine has finished phase 1 for all hosted proc nodes.
				dict update msgv {phase_done} _msg { dict lappend _msg $i $::turtles::kmm::myself }
			}
		}

	}
	return [fix_msgv $msgv]
}

## Triggers delivery of merge message to MOE roots.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a list with {int} stride indicating the root for which to trigger phase 2
proc ::turtles::bale::handle::merge {machineStateP cmdArgs} {
	set msgv [init_msgv {req_combine}]
	upvar $machineStateP machineState
	dict with machineState {
		foreach procId $cmdArgs {
			if { $state != {MERGE} } { continue }
			# The target is the opposite terminus of the MOE.
			set target [lindex $MOE 1]
			dict update msgv {req_combine} _msg { dict lappend _msg [::turtles::kmm::machine_hash $target] $target $procId }
		}
		# Wipe out the roots collection. This will be repopulated when the new_group messages start circulating.
		set roots [dict create]
	}
	return [fix_msgv $msgv]
}

## Triggers delivery of request-to-combine message from MOE roots to opposite terminii.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a list with {int int} stride indicating the recipient and sender, respectively
proc ::turtles::bale::handle::req_combine {machineStateP cmdArgs} {
	set msgv [init_msgv {new_root}]
	upvar $machineStateP machineState
	set newroots [list]
	dict with machineState {
		foreach {procId sndrId} $cmdArgs {
			if { $state != {MERGE} } { continue }
			# The requester becomes the child of this node.
			lappend children $sndrId
			# Node becomes new root iff:
			#  the node is the originating terminus of a MOE
			#  the opposite terminus of this node's MOE sent the req_combine message
			#  this node's value is greater than the opposite node (tie-breaker)
			if { $procId == [lindex $MOE 0] && $sndrId == [lindex $MOE 1] && $procId > $childId } {
				# Ensure that this new root gets added to the roster on the machine.
				lappend newroots $procId
				# Prepare to establish new rooted fragment.
				dict update msgv {new_root} _msg { dict lappend _msg [::turtles::kmm::machine_hash $procId] $procId $procId }
			}
		}
		# Replenish roots.
		foreach procId $newroots {
			dict set roots $procId {}
		}
	}
	return [fix_msgv $msgv]
}

## Triggers delivery of new-root message to establish new fragment boundaries.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a list with {int int int} stride indicating the recipient, new root, and new parent, respectively.
proc ::turtles::bale::handle::new_root {machineStateP cmdArgs} {
	set msgv [init_msgv {new_root}]
	upvar $machineStateP machineStaet
	dict with machineState {
		foreach {procId newRoot newParent} $cmdArgs {
			if { $state != {MERGE} } { continue }
			set state {IDLE}
			incr procsInPhase -1
			set root $newRoot
			# Demote parent to child if new parent is different.
			if { $parent != $newParent } {
				lappend children $parent
			}
			# Remove new parent from children if applicable.
			set children [lsearch -inline -all -not $children] $newParent
			# Re-parent.
			set parent $newParent
			# Prepare to notify children.
			foreach childId $children {
				dict update msgv {new_root} _msg { dict lappend _msg [::turtles::kmm::machine_hash $childId] $childId $root $procId }
			}
		}

		# Check if machine has finished establishing new roots.
		if { $procsInPhase == 0 } {
			for {set i 0} {i < $::turtles::kmm::machines} {incr i} {
				# Notify all other machines that this machine has finished phase 1 for all hosted proc nodes.
				dict update msgv {phase_done} _msg { dict lappend _msg $i $::turtles::kmm::myself }
			}
		}

	}
	return [fix_msg $msgv]
}

## Triggers a "machine" in the k-machine model to start the phase identified by the given arguments.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a singleton list containing the identifier of the phase to start
proc ::turtles::bale::handle::phase_init {machineStateP cmdArgs} {
	set msgv [init_msgv {phase_done}]
	upvar $machineStateP machineState
	dict with machineState {
		lassign $cmdArgs newPhase
		set procsInPhase [dict size $procs]
		switch $newPhase {
			0 { # Organize edges
				set rootCmd {prepare}
			}
			1 { # Find MOE
				set rootCmd {find_moe}
			}
			2 { # Merge
				set rootCmd {merge}
			}
			3 { # Termination check
				set procsActive 0
				set rootCmd {req_active}
			}
			4 { # Summarize results
				set rootCmd {summarize}
			}
			default { # Invalid
				set rootCmd {}
			}
		}
		if { $rootCmd ne {} } {
			set machinesInPhase $::turtles::kmm::machines
			set phase $newPhase
			if { [dict size $roots] > 0 } {
				dict update msgv $rootCmd _msg { dict set _msg $::turtles::kmm::myself [dict keys $roots] }
			} else {
				for {set i 0} {$i < $::turtles::kmm::machines} {incr i} {
					# Notify all other machines that this machine has finished the current phase for all hosted proc nodes.
					dict update msgv {phase_done} _msg { dict lappend _msg $i $::turtles::kmm::myself }
				}
			}
		}
	}
	return [fix_msgv $msgv]
}

## Triggers a "machine" in the k-machine model to end the phase identified by the given arguments.
#
# If this is the last machine to receive the message, this will trigger a phase init of the next phase.
# If there are no more phases, it will initiate a teardown of the k-machine model.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a singleton list containing the identifier of the phase to end
proc ::turtles::bale::handle::phase_done {machineStateP cmdArgs} {
	set msgv [init_msgv {phase_init} {bye}]
	upvar $machineStateP machineState
	dict with machineState {
		if { $machinesInPhase != 0 } {
			incr machinesInPhase -1
			if { $machinesInPhase == 0 } {
				switch $phase {
					0 { # Organize edges
						dict update msgv {phase_init} _msg { dict lappend _msg $::turtles::kmm::myself 1 }
					}
					1 { # Find MOE
						dict update msgv {phase_init} _msg { dict lappend _msg $::turtles::kmm::myself 2 }
					}
					2 { # Merge
						dict update msgv {phase_init} _msg { dict lappend _msg $::turtles::kmm::myself 3 }
					}
					3 { # Termination check
						if { $procsActive > 0 } {
							dict update msgv {phase_init} _msg { dict lappend _msg $::turtles::kmm::myself 1 }
						} else {
							dict update msgv {phase_init} _msg { dict lappend _msg $::turtles::kmm::myself 4 }
						}
					}
					4 { # Summarize results
						dict update msgv {bye} _msg {dict lappend _msg $::turtles::kmm::myself}
					}
				}
			}
		}
	}
	return [fix_msgv $msgv]
}

## Triggers a "machine" in the k-machine model to summarize the final results of the algorithm.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a singleton list containing the identifier of the phase to start
proc ::turtles::bale::handle::summarize {machineStateP cmdArgs} {
	set msgv [init_msgv {phase_done}]
	upvar $machineStateP machineState
	dict with machineState {
		foreach procNode $procs {
			dict with procNode {
				set weight [dict get $neighbors $parent]
				puts "$root\t$parent\t$weight\t$procId\t$procName"
			}
		}
	}
	for {set i 0} {i < $::turtles::kmm::machines} {incr i} {
		# Notify all other machines that this machine has finished phase 1 for all hosted proc nodes.
		dict update msgv {phase_done} _msg { dict lappend _msg $i $::turtles::kmm::myself }
	}
}

## Requests the number of active proc nodes resident on the target "machine".
#
# A proc node is considered active if it has edges radiating outside its current MST fragment.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a singleton list containing the identifier of the machine requesting the statistic
proc ::turtles::bale::handle::req_active {machineStateP cmdArgs} {
	set msgv [init_msgv {rsp_active}]
	upvar $machineStateP machineState
	dict with machineState {
		lassign $cmdArgs sender
		set activeCount [dict size [dict filter $procs script {k v} { [llength [dict get outerEdges $v]] != 0 }]]
		dict update msgv {rsp_active} _msg { dict lappend _msg $sender $activeCount }
	}
	return [fix_msgv $msgv]
}

## Processes responses to requests to other machines for the number of resident active proc nodes.
#
# A proc node is considered active if it has edges radiating outside its current MST fragment.
#
# If all the machines have responded to each other, the phase is considered finished.
#
# \param[in,out] machineStateP a name reference to a state dictionary
# \param[in] cmdArgs a singleton list containing a count of active proc nodes
proc ::turtles::bale::handle::rsp_active {machineStateP cmdArgs} {
	set msgv [init_msgv {phase_done}]
	upvar $machineStateP machineState
	dict with machineState {
		incr machinesInPhase -1
		lassign $cmdArgs activeCount
		incr procsActive activeCount
		if { $machinesInPhase == 0 } {
			dict update msgv {phase_done} _msg { dict lappend _msg $::turtles::kmm::myself 3 }
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
# \param[in] cmdArgs the putative args associated with the invalid command
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
