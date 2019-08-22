#!/usr/bin/env tclsh

package require Tcl 8.5 8.6
package require Thread

## \file kmm.tcl
# Provides common functions for emulating a k-machine model in Tcl threads.

## The k-machine model is a common distributed system abstraction used
# for partitioning data across multiple logical, nearly identical machines,
# usually to accommodate large sets of data that would either not fit
# in the memory or storage space of one machine or would require more
# processing power than one machine could deliver.
#
# This package provides an abstraction for implementing k-machine model
# algorithms with threads standing in as the eponymous machines.
#
# Some of the utility functions take their nomenclature from the MPI
# standard (https://www.mpi-forum.org/) but do not in any way provide
# the behavioral guarantees of the standard. It is more of an homage to
# some of the ideas typified by the MPI communication primitives.
#
# Please note that this package is highly experimental and is subject
# to potentially frequent and breaking changes.
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

## Hashes an integer identifier to deterministically assign a machine for associated data.
#
# Currently, this is just a modulus operation against the number of machines in the model.
# The function presumes that the model has been started and that the \c ::turtles::kmm::machines constant
# has been initialized. A better implementation would use a universal hashing function.
#
# \param[in] id an integer identifier associated with some data to be processed by the k-machine model
proc ::turtles::kmm::machine_hash {id} {
	return [expr {$id % $::turtles::kmm::machines} ]
}

## Sends a message to a machine in the k-machine model.
#
# This is the basic k-machine model transmission primitive. It is asynchronous under the hood.
# However, the caller may specify a variable name reference which can be used as an awaiter
# to make the call synchronous from the caller's perspective. After the call, the caller
# simply needs to \c vwait on the name reference it passed to the \c send call.
#
# \param[in] i the target machine
# \param[in] cmd the command/message type to send
# \param[in] cmdArgs the arguments for the given command/message type
# \param[in] awaiterP an optional variable name reference which the caller can await on to make the send call synchronous
proc ::turtles::kmm::send {i cmd cmdArgs {awaiterP {}}} {
	upvar $awaiterP awaiter
	set tid [lindex $::turtles::kmm::model $i]
	set msg [subst { ::turtles::kmm::recv $cmd $cmdArgs }]
	puts "thread::send -async tid $msg awaiter"
	thread::send -async $targetThread $msg awaiter
}

## Broadcasts a message to all machines in the k-machine model.
#
# This proc iterates over all machines and sends the same message to each of them.
# An optional await argument is given that defaults to the empty string.
# In the case that a non-empty argument is given, this proc itself awaits all
# the responses of the machines which it contacted and delivers the results
# in a dictionary. If the caller does not specify the await argument, an empty
# dictionary is returned.
#
# \param[in] i the target machine
# \param[in] cmd the command/message type to send
# \param[in] cmdArgs the arguments for the given command/message type
# \param[in] await an optional argument indicating that the caller wishes to receive the results of the broadcast
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


## Sends a different message to a subset of the machines in the k-machine model.
#
# Sometimes it becomes necessary to send the same message type but with different arguments
# to some or all of the machines, e.g., when the message arguments depend on the resident data.
# This call achieves this by taking a single command and a dictionary keyed by machine id with
# values set to the corresponding arguments to be sent to that machine.
#
# \param[in] cmd the command/message type to send
# \param[in] msgv a dictionary of message arguments keyed by machine id
proc ::turtles::kmm::scatterv {cmd msgv} {
	puts "::turtles::kmm::scatterv $cmd $msgv"
	return [dict map {machine msg} $msgv { ::turtles::kmm::send $machine $cmd $msg sync}]
}

## Sends different messages to a subset of the machines in the k-machine model.
#
# This proc essentially consumes a set of arguments for different commands represented as a
# dictionary of \c ::turtles::kmm::scatterv message vector (msgv) arguments keyed by command/message type.
#
# This facilitates unit testing of message handlers by allowing the handlers to return a heterogeneous set
# of response messages after processing.
#
# \param[in] cmd the command/message type to send
# \param[in] msgv a dictionary of message arguments keyed by machine id
proc ::turtles::kmm::dict_scatterv {d} {
	dict for {cmd msgv} $d { ::turtles::kmm::scatterv $cmd $msgv }
}

## Starts a k-machine model.
#
# This proc handles all the thread initialization given a few parameters.
# The user specifies the number of machines in the model, along with a
# common prelude script body (useful for package imports), an initialization
# script body (for actions to be executed prior to entry into a \c thread::wait loop),
# and a receive function for responding to incoming messages.
#
# Most of the internal plumbing for the thread creation and k-machine
# housekeeping is handled implicitly so users can concentrate on the machine
# application logic.
#
# Regrettably, certain assumptions and design choices require that only one k-machine model
# be running at a given time. Future development may mitigate this.
#
# After all the machines are instantiated, the supervisor thread which made this call broadcasts
# a list of thread ids for all the threads participating in the k-machine model.
#
# \param[in] k the number of machines
# \param[in[ prelude a common script to be executed before most of the k-machine housekeeping takes place
# \param[in] initFn a common script to be executed after the indidivual k-machine housekeeping is done but before the \c thread::wait loop
# \param[in] recvFn a common script for processing messages received
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

## A utility function for the supervisor thread to call so it can wait until the k-machine model computation is finished.
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

## A utility function for a k-machine model thread to shut itself down.
#
# The proc notifies any listeners on the \c ::turtles::kmm::cond condition variable
# of its impending shutdown and causes the thread to exit.
proc ::turtles::kmm::bye {} {
	thread::cond::notify $::turtles::kmm::cond
	thread::exit 0
}

## A utility function for stopping the k-machine model.
#
# The proc releases any extant threads in the k-machine model and cleans up
# all the allocated resources.
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

