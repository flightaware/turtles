#!/usr/bin/env tclsh

package require Tcl 8.5 8.6

namespace eval ::turtles::bale::proc {
	namespace export init diff validate
}

## Initializes a proc node with defaults given a proc ID and a proc name.
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
# * \c awaiting: a decrement counter used to keep state during phase work.
# * \c state: a representation of the proc node's current state in the GHS algorithm. This is used as a sanity guard before executing certain operations.
#
# \param[in] procId a hash of the given procName
# \param[in] procName the fully qualified name of the proc
proc ::turtles::bale::proc::init {procId procName} {
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

## Validates whether the proc node variable referenced by the given name is valid.
#
# \param[in] procP a name reference to a proc node dictionary
proc ::turtles::bale::proc::validate {procP} {
	upvar $procP procA
	return [expr { \
					   [ dict exists $procA procId ] && \
					   [ dict exists $procA procName ] && \
					   [ dict exists $procA neighbors ] && \
					   [ dict exists $procA outerEdges ] && \
					   [ dict exists $procA innerEdges ] && \
					   [ dict exists $procA root ] && \
					   [ dict exists $procA parent ] && \
					   [ dict exists $procA children ] && \
					   [ dict exists $procA moe ] && \
					   [ dict exists $procA awaiting ] && \
					   [ catch { dict size [dict get $procA neighbors] } ] == 0 && \
					   [ llength [dict get $procA moe] ] == 3 && \
					   [ string is entier [dict get $procA procId ] ] && \
					   [ string is entier [dict get $procA root ] ]&& \
					   [ string is entier [dict get $procA parent ] ] && \
					   [ string is entier [dict get $procA awaiting ] ] } ]
}


## Produces a difference dictionary between two proc nodes specified by the given name references.
#
# This is primarily used in testing to determine whether an operation on a proc node has had the desired effect.
# It is fairly expensive and is not recommended for production code.
#
# \param[in] proc1P
# \param[in] proc2P
proc ::turtles::bale::proc::diff {proc1P proc2P} {
	upvar $proc1P procA
	upvar $proc2P procB
	set procD [dict create]
	dict for {kA vA} $procA {
		if { [dict exists $procB $kA] } {
			set vB [dict get $procB $kA]
			switch $kA {
				procId   -
				procName -
				outerEdges -
				innerEdges -
				root     -
				parent   -
				children -
				moe      -
				awaiting -
				state    {
					if { $vA != $vB } { dict set procD $kA $vB }
				}
				neighbors {
					set vD [dict create]
					dict for {k1 v1} $vA {
						if { [dict exists $vB $k1] } {
							set v2 [dict get $vB $k1]
							if { $v1 != $v2 } {
								dict set vD $k1 $v2
							}
						} else {
							dict lappend vD "-" $k1
						}
					}
					dict for {k2 v2} $vB {
						if { ![dict exists $vA $k2] } {
							dict set vD "+$k2" $v2
						}
					}
					if { [dict size $vD] > 0 } { dict set procD neighbors $vD }
				}
				default {
					puts stderr "default: $kA $vA $vB"
				}
			}
		} else {
			dict lappend procD - $kA
		}
	}
	dict for {k v} $procB {
		if { ![dict exists $procA $k] } {
			dict set procD "+$k" $v
		}
	}
	return $procD
}

package provide turtles::bale::proc 0.1
