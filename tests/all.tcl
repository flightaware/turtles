#!/usr/bin/env tclsh
package require Tcl 8.5 8.6
package require tcltest
namespace import ::tcltest::*

configure -testdir [file dirname [info script]]
runAllTests
