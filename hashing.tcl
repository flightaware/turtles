#!/usr/bin/env tclsh
package require Tcl 8.5

## \file hashing.tcl
# Provides a port of the Rabin-Karp rolling hash given at
# https://en.wikipedia.org/wiki/Universal_hashing#Hashing_strings.
# This is useful for mapping fully-qualified function names (FQFNs)
# onto a set of integers in the range [0,p] where p is the modulus
# prime.

namespace eval ::turtles::hashing {
	namespace export hash_string hash_int_list
}

## The Rabin-Karp rolling hash implementation for strings.
#
# All arguments except the input string have default values.
# The multiplier \c a and modulus prime \c p are the 7th
# and 8th Mersenne primes, respectively, by default.
#
# To maintain consistency, across calls within a single program
# or across a broader multiple program context,
# the a, p, and h values MUST be the same.
# \param[in] S the input string
# \param[in] a the multiplier (default = M_7 = 2^19-1)
# \param[in] p the modulus prime (default = M_8 = 2^31-1)
# \param[in] h_0 the initial hash value (default 0)
#
proc ::turtles::hashing::hash_string {S {a 524287} {p 2147483647} {h_0 0}} {
	set h $h_0
	foreach c [split $S {}] {
		set h [ expr { ($h * $a + [scan $c %c]) % $p } ]
	}
	return $h
}

#
# All arguments except the input string have default values.
# The multiplier \c a and modulus prime \c p are the 7th
# and 8th Mersenne primes, respectively, by default.
#
# To maintain consistency, across calls within a single program
# or across a broader multiple program context,
# the a, p, and h values MUST be the same.
# \param[in] Z the input list of integers
# \param[in] a the multiplier (default = M_7 = 2^19-1)
# \param[in] p the modulus prime (default = M_8 = 2^31-1)
# \param[in] h_0 the initial hash value (default 0)
#
proc ::turtles::hashing::hash_int_list {Z {a 524287} {p 2147483647} {h_0 0}} {
	set h $h_0
	foreach z $Z {
		set h [ expr { ($h * $a + $z) % $p } ]
	}
	return $h
}

package provide turtles::hashing 0.1
