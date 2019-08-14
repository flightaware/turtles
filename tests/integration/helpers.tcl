#!/usr/bin/env tclsh

package require turtles 0.1
package require Thread
package require tcltest
namespace import ::tcltest::*

proc with_turtles {title {commitMode staged} {intervalMillis 50} testBody} {
	test with_turtles [subst {with_turtles "$title" $commitMode $intervalMillis}] \
		-setup {
			::turtles::release_the_turtles {} $commitMode $intervalMillis
			if { ![ thread::exists $::turtles::persistence::mt::recorder ] } {
				error "Persistence mechanism is not running!"
			}
		} -body {
			[eval $testBody]
		} -cleanup {
			::turtles::capture_the_turtles
			if { [ thread::exists $::turtles::persistence::mt::recorder ] } {
				error "Persistence mechanism is still running!"
			}
		} -result 1
}

proc test_caller_callee_count {stage caller callee expected} {
	thread::send $::turtles::persistence::mt::recorder [subst {
		return \[::turtles::persistence::mt::stages eval {
			SELECT SUM(calls) FROM $stage.calls_by_caller_callee WHERE caller_name = '$caller' AND callee_name = '$callee';
		}\]
	}] actual
	if { $expected != $actual } {
		error "Expected ($expected) calls for '$caller' -> '$callee', but actually got ($actual)."
	}
}
