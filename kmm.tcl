#!/usr/bin/env tclsh

package require Tcl 8.5 8.6
package require Thread

# \file kmm.tcl
# Provides common functions for emulating a k-machine model in Tcl threads.
namespace eval ::turtles::kmm {
	namespace export machine_hash send recv bcast scatterv dict_scatterv init
}

proc ::turtles::kmm::machine_hash {procId} {
	return [expr {$procId % $::turtles::kmm::machines} ]
}

proc ::turtles::kmm::send {targetId cmd cmdArgs {await {}}} {
	set targetThread [lindex $::turtles::kmm::model targetId]
	thread::send -async $targetThread [subst {
		::turtles::kmm::recv $cmd $cmdArgs
	}] awaiter
	if { $await ne {} } {
		vwait $awaiter
	}
	return $awaiter
}

proc ::turtles::kmm::bcast {cmd cmdArgs {await {}}} {
	set i 0
	array set awaiters
	foreach targetThread $::turtles::kmm::model {
		::turtles::send -async $targetThread [subst {
			::turtles::kmm::recv $cmd $cmdArgs
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
	dict for {cmd cmdArgs} $d { ::turtles::kmm::scatterv $cmd $cmdArgs }
}

proc ::turtles::kmm::init {k initFn recvFn} {
	set ::turtles::kmm::supervisor [thread::current]
	set ::turtles::kmm::model [list]
	for {set i 0} {i < k} {incr i} {
		lappend $::turtles::kmm::model [ thread::create [subst {
			global ::turtles::kmm::myself
			global ::turtles::kmm::machines
			global ::turtles::kmm::supervisor
			# Set the machine ID.
			set ::turtles::kmm::myself $i
			# Set the number of participating machines.
			set ::turtles::kmm::machines $k
			# Set the supervisor thread variable.
			set ::turtles::kmm::supervisor $::turtles::kmm::supervisor
			interp alias {} ::turtles::kmm::recv {} $recvFn
			$initFn
			thread::wait
		}] ]
	}
	# Broadcast (k-machine index -> thread) map to all k-machine model threads.
	for {set i 0} {$i < k} {incr i} {
		thread::send [lindex $::turtles::kmm::model] [subst {
			global ::turtles::kmm::model
			set ::turtles::kmm::model $::turtles::kmm::model
		}]
	}
}

package provide turtles::kmm 0.1

