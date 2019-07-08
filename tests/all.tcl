#!/usr/bin/env tclsh
package require Tcl 8.5
package require tcltest
namespace import ::tcltest::*

configure -testdir .
runAllTests
