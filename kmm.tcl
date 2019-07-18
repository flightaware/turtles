#!/usr/bin/env tclsh

# \file kmm.tcl
# Provides common functions for emulating a k-machine model in Tcl threads.

namespace eval ::turtles::kmm {
	namespace export machine_hash send recv bcast scatterv dict_scatterv init
}

proc ::turtles::kmm::machine_hash {procId} {
	return [expr {$procId % $::turtles::kmm::machines} ]
}

proc ::turtles::kmm::send {targetId cmd args {await {}}} {
	set targetThread [lindex $::turtles::kmm::model targetId]
	thread::send -async $targetThread [subst {
		::turtles::kmm::recv $cmd $args
	}] awaiter
	if { $await ne {} } {
		vwait $awaiter
	}
	return $awaiter
}

proc ::turtles::kmm::bcast {cmd args {await {}}} {
	set i 0
	array set awaiters
	foreach targetThread $::turtles::kmm::model {
		::turtles::send -async $targetThread [subst {
			::turtles::kmm::recv $cmd $args
		}] awaiters($i)
		incr i
	}
	if { $await ne {} } {
		for {set j 0} {$j < $i} {incr j} {
			vwait awaiters($j)
		}
	}
	return $awaiters
}

proc ::turtles::kmm::scatterv {cmd msgv} {
	dict for {machine msg} $msgv {
		::turtles::kmm::send $machine $cmd $msg
	}
}

proc ::turtles::kmm::dict_scatterv {d} {
	dict for {cmd args} $d { ::turtles::kmm::scatterv $cmd $args }
}

proc ::turtles::kmm::init {k worker} {
	set ::turtles::kmm::model [list]
	for {set i 0} {i < k} {incr i} {
		lappend $::turtles::kmm::model [ thread::create { $worker $i $k } ]
	}
	for {set i 0} {i < k} {incr i} {
		thread::send [lindex $::turtles::kmm::model] { set ::turtles::kmm::model $::turtles::kmm::model }
	}
}

package provide turtles::kmm 0.1
