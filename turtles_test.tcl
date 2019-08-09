#!/usr/bin/env tclsh

package require Thread
package require tcltest
package require turtles::persistence::base 0.1
package require turtles 0.1

namespace eval ::turtles::test::integration::postmortem {
	namespace export test_caller_callee_counts
}

proc ::turtles::test::integration::postmortem::test_caller_callee_counts {expectations {dbPath {./}} {dbPrefix {turtles}}} {
	set dbFilePath [::turtles::persistence::base::get_db_filename $dbPath $dbPrefix]
	sqlite3 postmortem $dbFilePath
	foreach {caller callee expected} $expectations {
		postmortem eval [subst {
			SELECT SUM(calls) AS actual FROM calls_by_caller_callee WHERE caller_name = '$caller' AND callee_name = '$callee';
		}] {
			if { $actual != $expected } {
				error  "Expected ($expected) calls for '$caller' -> '$callee', but actually got ($actual)."
			}
		}
	}
	postmortem close
}

package provide turtles::test::integration::postmortem 0.1

namespace eval ::turtles::test::integration::mt {
	namespace export *
}

proc ::turtles::test::integration::mt::with_turtles {constraints title {commitMode staged} {intervalMillis 50} testBody {postMortemBody { return }} {dbPath {./}} {dbPrefix {turtles}}} {
	::tcltest::test with_turtles [subst {with_turtles "$title" $commitMode $intervalMillis}] \
		-constraints $constraints \
		-setup {
			::turtles::release_the_turtles $commitMode $intervalMillis $dbPath $dbPrefix
			if { ![ thread::exists $::turtles::persistence::mt::recorder ] } {
				error "Persistence mechanism is not running!"
			}
		} -body {
			[eval $testBody]
		} -cleanup {
			::turtles::capture_the_turtles
			#[eval $postMortemBody]
			file delete [::turtles::persistence::base::get_db_filename $dbPath $dbPrefix]
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

proc ::turtles::test::integration::mt::print_caller_callee_calls {stage} {
	thread::send $::turtles::persistence::mt::recorder [subst {
		 ::turtles::persistence::mt::$stage eval {
			 SELECT * FROM calls_by_caller_callee;
		 } values {
			 puts "'$values(caller_name)' -> '$values(callee_name)' : $values(calls)"
		 }
	}]
}

package provide turtles::test::integration::mt 0.1


namespace eval ::turtles::test::integration::ev {
	namespace export *
}

proc ::turtles::test::integration::ev::with_turtles {constraints title {commitMode staged} {intervalMillis 50} testBody {postMortemBody { return }} {dbPath {./}} {dbPrefix {turtles}}} {
	::tcltest::test with_turtles [subst {with_turtles "$title" $commitMode $intervalMillis}] \
		-constraints $constraints \
		-setup {
			::turtles::release_the_turtles $commitMode $intervalMillis $dbPath $dbPrefix ev
		} -body {
			[eval $testBody]
		} -cleanup {
			::turtles::capture_the_turtles
			file delete [::turtles::persistence::base::get_db_filename $dbPath $dbPrefix]
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

proc ::turtles::test::integration::ev::print_caller_callee_calls {stage} {
	::turtles::persistence::ev::$stage eval {
		SELECT * FROM calls_by_caller_callee;
	} values {
		puts "'$values(caller_name)' -> '$values(callee_name)' : $values(calls)"
	}
}

package provide turtles::test::integration::ev 0.1
