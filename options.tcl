#!/usr/bin/env tclsh

## \file options.tcl
# Provides options processing for the TURTLES framework.

## This namespace provides utilities for processing TURTLES options.
namespace eval ::turtles::options {
	namespace export consume
}

set ::turtles::options::regex {[+]TURTLES(.*?)[-]TURTLES(\s|$)}

## Consumes an ARGV-style string and strips out TURTLES options specifications, which it returns.
#
# TURTLES options are broadly defined as any text bracketed by "+TURTLES ... -TURTLES".
#
# This proc will destructively consume the TURTLES options so it can return them with the brackets removed.
# The string identified by the given reference may be modified. This is done so that downstream consumers
# do not need to add special handling to ignore the TURTLES brackets.
#
# Multiple groups of TURTLES-bracketed arguments can be interspersed throughout the argument string.
# See the unit tests for examples.
#
# \param[in,out] argvRef a variable name reference to an ARGV-style string
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
