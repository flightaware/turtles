#!/usr/bin/env tclsh

package require turtles 0.1
package require Thread
package require tcltest

namespace eval ::turtles::test::integration::mt {
	namespace export *
}

proc ::turtles::test::integration::mt::with_turtles {title {commitMode staged} {intervalMillis 50} testBody} {
	::tcltest::test with_turtles [subst {with_turtles "$title" $commitMode $intervalMillis}] \
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

proc ::turtles::test::integration::mt::test_caller_callee_count {stage caller callee expected} {
	thread::send $::turtles::persistence::mt::recorder [subst {
		return \[::turtles::persistence::mt::$stage eval {
			SELECT SUM(calls) FROM calls_by_caller_callee WHERE caller_name = '$caller' AND callee_name = '$callee';
		}\]
	}] actual
	if { $expected != $actual } {
		error "Expected ($expected) calls for '$caller' -> '$callee', but actually got ($actual)."
	}
}

package provide turtles::test::integration::mt 0.1


namespace eval ::turtles::test::integration::ev {
	namespace export *
}

proc ::turtles::test::integration::ev::with_turtles {title {commitMode staged} {intervalMillis 50} testBody} {
	::tcltest::test with_turtles [subst {with_turtles "$title" $commitMode $intervalMillis}] \
		-setup {
			::turtles::release_the_turtles {} $commitMode $intervalMillis ev
		} -body {
			[eval $testBody]
		} -cleanup {
			::turtles::capture_the_turtles
		} -result 1
}

proc ::turtles::test::integration::ev::test_caller_callee_count {stage caller callee expected} {
	::turtles::persistence::ev::$stage eval [subst {
		SELECT SUM(calls) AS totalCalls FROM calls_by_caller_callee WHERE caller_name = '$caller' AND callee_name = '$callee';
	}] values {
		set actual $values(totalCalls)
	}
	if { $expected != $actual } {
		error "Expected ($expected) calls for '$caller' -> '$callee', but actually got ($actual)."
	}
}

package provide turtles::test::integration::ev 0.1
