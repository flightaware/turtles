#!/usr/bin/env tclsh

package require Tcl 8.5 8.6
package require sqlite3
package require cmdline

##### PARSE ARGS #####

set options {
	{cutoff.arg 0 "minimum # of calls required to include caller-callee edge"}
	{undirected "construct undirected graph (caller <-> callee) \[default (caller -> callee)\]"}
	{verbosity.arg 0 "level of verbosity in output"}
}

set usage "?options?"

if { [ catch { array set params [::cmdline::getoptions ::argv $options $usage] } catchResult] == 1 } {
	puts stderr $catchResult
	exit 255
}

set dbFileName [lindex $::argv 0]

##### LOAD DATA #####

sqlite3 db $dbFileName
set clusters [dict create]


db eval {
	SELECT proc_id, proc_name
	FROM proc_ids
	LEFT JOIN (SELECT callee_id FROM call_pts GROUP BY callee_id) AS distinct_call_pts ON proc_ids.proc_id = distinct_call_pts.callee_id
	WHERE callee_id IS NOT NULL;
} {
	dict set clusters $proc_id [dict create proc_name $proc_name group $proc_id group_name $proc_name neighbors [dict create] degree_called 0 degree_group 0]
}

db eval [subst {
	SELECT caller_id, callee_id, COUNT(*) AS calls FROM call_pts GROUP BY caller_id, callee_id HAVING COUNT(*) > $params(cutoff);
}] {
	# @FIXME: Check existence of proc. There seems to be a bug in TURTLES where not all procs get registered.
	if { [dict exists $clusters $callee_id] && ( [dict exists $clusters $caller_id] || $caller_id == 0 ) } {
		if { $caller_id != 0 } {
			dict with clusters $caller_id {
				dict incr neighbors $callee_id $calls
			}
		}

		dict with clusters $callee_id {
			if { $caller_id != 0 && $params(undirected) } {
				dict incr neighbors $caller_id $calls
			}
			incr degree_called $calls
			incr degree_group $calls
		}
	} else {
		set callee_name {???}
		set caller_name {???}
		if { [dict exists $clusters $callee_id] } {
			set callee_name [dict get $clusters $callee_id proc_name]
		}
		if { [dict exists $clusters $caller_id] } {
			set caller_name [dict get $clusters $caller_id proc_name]
		}
		puts stderr "Graph edge missing terminus: ($caller_id/$caller_name, $callee_id/$callee_name)"
	}
}

db close

##### TRAVERSE GRAPH #####

set done 0
set senders [dict keys $clusters]

# BFS is done when there are no more messages to send.
while { [llength $senders] > 0 } {
	set {senders'} [dict create]
	foreach i_u $senders {
		set group_u [dict get $clusters $i_u group]
		set group_name_u [dict get $clusters $i_u group_name]
		set degree_group_u [dict get $clusters $i_u degree_group]
		set proc_name_u [dict get $clusters $i_u proc_name]
		dict for {i_v e_uv} [dict get $clusters $i_u neighbors] {
			# Process message from u -> v.
			dict with clusters $i_v {
				if { $group_u != $group && $degree_group_u >= $degree_group } {
					# Node v becomes a member of u's group.
					set group $group_u
					set group_name $group_name_u
					set degree_group $degree_group_u
					# Add node to subsequent list of senders.
					dict set {senders'} $i_v {}
				}
			}
		}
	}

	# Promote the subsequent senders list.
	set senders [dict keys ${senders'}]
}

set groups [dict create]
dict for {i_u u} $clusters {
	set group_name [dict get $u group_name]
	set proc_name [dict get $u proc_name]
	if { $params(verbosity) >= 2 } {
		puts "DEBUG $group_name $proc_name \{$u\}"
	}
	dict lappend groups $group_name $proc_name
}

dict for {i_g g} $groups {
	puts "$i_g \{$g\}"
}
