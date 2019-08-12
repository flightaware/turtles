#!/usr/bin/env tclsh

package require tcltest
package require turtles::persistence::base 0.1
package require turtles 0.1
package require sqlite3

namespace eval ::turtles::test::integration::postmortem {
	namespace export test_caller_callee_counts test_cleanup
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

proc ::turtles::test::integration::postmortem::test_cleanup {postMortemBody {dbPath {./}} {dbPrefix {turtles}}} {
	::turtles::capture_the_turtles
	eval $postMortemBody
	file delete [::turtles::persistence::base::get_db_filename $dbPath $dbPrefix]
}

package provide turtles::test::integration::postmortem 0.1
