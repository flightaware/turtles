#!/usr/bin/env tclsh

namespace eval ::turtles::options {
	namespace export 3consume
}

set ::turtles::options::regex {[+]TURTLES(.*?)[-]TURTLES(\s|$)}

proc ::turtles::options::consume {argvRef} {
	upvar $argvRef argv
	set matches [regexp -all -inline $::turtles::options::regex $argv]
	regsub -all $::turtles::options::regex $argv {} {argv'}
	set argv [string trim ${argv'}]
	set result {}
	foreach {g0 g1 g2} $matches {
		append result " [string trim $g1]"
	}
	return [string trim $result]
}

package provide turtles::options 0.1
