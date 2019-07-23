#!/usr/bin/env tclsh

package require turtles::bale::proc 0.1

namespace eval ::turtles::bale::machine {
	namespace export init diff has_proc
}

proc ::turtles::bale::machine::init {} {
	return [dict create \
				procs [dict create] \
				roots [dict create] \
				phase 0 \
				machinesInPhase 0 \
				procsInPhase 0 \
				procsActive 0
		   ]
}

proc ::turtles::bale::machine::has_proc {machineStateP procId} {
	upvar $machineStateP machineState
	set ok 0
	puts stderr $machineState
	dict with machineState procs {
		# NB: This is passing the proc id key as a name reference
		# so that the dictionary can be upvar'd.
		set ok [::turtles::bale::proc::validate $procId]
	}
	return $ok				   
}

proc ::turtles::bale::machine::diff {machineState1P machineState2P} {
	upvar $machineState1P machineStateA
	upvar $machineState2P machineStateB
	set machineStateD [dict create]
	dict for {kA vA} $machineStateA {
		if { [dict exists $machineStateB $kA] } {
			set vB [dict get $machineStateB $kA]
			switch $kA {
				phase -
				machinesInPhase -
				procsInPhase -
				procsActive {
					if { $vA != $vB } { dict set machineStateD $kA $vB }
				}
				procs {
					puts stderr "vA: $vA"
					puts stderr "vB: $vB"
					set vD [dict create]
					dict for {k1 p1} $vA {
						if { [dict exists $vB $k1] } {
							set p2 [dict get $vB $k1]
							set dp [::turtles::bale::proc::diff p1 p2]
							if { [ dict size $dp ] > 0 } {
								dict set machineStateD procs $k1 $dp
							}
						} else {
							dict with machineStateD {dict lappend procs "-" $k1}
						}
					}
					dict for {k2 v2} $vB {
						if { ![dict exists $vA $k2] } {
							dict set machineStateD procs "+$k2" $v2
						}
					}
				}
				roots {
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
					if { [dict size $vD] > 0 } { dict set machineStateD roots $vD }
				}
			}
		} else {
			dict lappend procD - $kA
		}
	}				
	dict for {k v} $machineStateB {
		if { ![dict exists $machineStateA $k] } {
			dict set machineStateD "+$k" $v
		}
	}
	return $machineStateD
}

package provide turtles::bale::machine 0.1
