#!/usr/bin/env tclsh

package require Tcl 8.5 8.6
package require Thread

# \file kmm.tcl
# Provides common functions for emulating a k-machine model in Tcl threads.
namespace eval ::turtles::kmm {
	variable ::turtles::kmm::supervisor
	variable ::turtles::kmm::model
	variable ::turtles::kmm::machines
	variable ::turtles::kmm::mutex
	variable ::turtles::kmm::cond
	namespace export \
		machine_hash \
		send recv bcast scatterv dict_scatterv \
	    init wait_until_done stop \
		supervisor model machines mutex cond
}

proc ::turtles::kmm::machine_hash {procId} {
	return [expr {$procId % $::turtles::kmm::machines} ]
}

proc ::turtles::kmm::send {i cmd cmdArgs {awaiterP {}}} {
	upvar $awaiterP awaiter
	set tid [lindex $::turtles::kmm::model $i]
	set msg [subst { ::turtles::kmm::recv $cmd $cmdArgs }]
	puts "thread::send -async tid $msg awaiter"
	thread::send -async $targetThread $msg awaiter
}

proc ::turtles::kmm::bcast {cmd cmdArgs {await {}}} {
	set i 0
	array set awaiters
	set results [dict create]
	foreach tid $::turtles::kmm::model {
		::thread::send -async $tid [subst { ::turtles::kmm::recv $cmd $cmdArgs }] awaiters($i)
		incr i
	}
	if { $await ne {} } {
		for {set j 0} {$j < $i} {incr j} {
			vwait awaiters($j)
			dict set results $j awaiters($j)
		}
	}
	return $results
}

proc ::turtles::kmm::scatterv {cmd msgv} {
	puts "::turtles::kmm::scatterv $cmd $msgv"
	return [dict map {machine msg} $msgv { ::turtles::kmm::send $machine $cmd $msg sync}]
}

proc ::turtles::kmm::dict_scatterv {d} {
	dict for {cmd msgv} $d { ::turtles::kmm::scatterv $cmd $msgv }
}

proc ::turtles::kmm::start {k prelude initFn recvFn} {
	global ::turtles::kmm::mutex
	global ::turtles::kmm::cond
	global ::turtles::kmm::supervisor
	global ::turtles::kmm::model
	global ::turtles::kmm::machines
	set ::turtles::kmm::machines $k
	set ::turtles::kmm::mutex [thread::mutex create]
	set ::turtles::kmm::cond [thread::cond create]
	set ::turtles::kmm::supervisor [thread::id]
	set ::turtles::kmm::model [list]
	for {set i 0} {$i < $k} {incr i} {
		set workerBody [subst {
			package require Tcl 8.5 8.6
			package require Thread
			package require turtles::kmm

			$prelude

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
			interp alias {} ::turtles::kmm::init {} $initFn
			::turtles::kmm::init
			thread::wait
		}]
		puts $workerBody
		lappend ::turtles::kmm::model [ thread::create $workerBody ]
	}
	# Broadcast (k-machine index -> thread) map to all k-machine model threads.
	for {set i 0} {$i < $k} {incr i} {
		thread::send [lindex $::turtles::kmm::model $i] [subst {
			global ::turtles::kmm::model
			set ::turtles::kmm::model $::turtles::kmm::model
		}]
	}
}

proc ::turtles::kmm::wait_until_done {} {
	set machinesActive $::turtles::kmm::machines
	thread::mutex lock $::turtles::kmm::mutex
	while { $machinesActive > 0 } {
		thread::cond wait $::turtles::kmm::cond
		set machinesActive 0
		foreach tid $::turtles::kmm::model {
			if { [thread::exists $tid] } { incr machinesActive }
		}
	}
	thread::mutex unlock $::turtles::kmm::mutex
	
}

proc ::turtles::kmm::bye {} {
	thread::cond::notify $::turtles::kmm::cond
	thread::exit 0
}

proc ::turtles::kmm::stop {} {
	foreach tid $::turtles::kmm::model {
		if { [thread::exists $tid] } { 
			::thread::release $tid
		}
	}
	::thread::cond destroy $::turtles::kmm::cond
	::thread::mutex destroy $::turtles::kmm::mutex
	unset ::turtles::kmm::supervisor
	unset ::turtles::kmm::model
	unset ::turtles::kmm::machines
}

package provide turtles::kmm 0.1

