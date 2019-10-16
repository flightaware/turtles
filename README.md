# TURTLES (Tcl Universal Recursive Trace Log Execution Scrutinizer)

The TURTLES family of packages provides a pure Tcl trace injection framework
for recording proc call statistics including caller/callee info and timing.
The call records are stored in a sqlite3 database which contains a few helpful
views by default for understanding proc interaction and usage at a glance.

## Requirements

TURTLES depends on a few libraries for its operation. These dependencies were
kept to a minimum and avoided using core flightaware packages with the goal
of making the library as light and portable as possible.

Required Tcl packages include the following:

- `Tcl` (8.5|8.6)
- `Tclx`
- `Thread`
- `cmdline`
- `platform`
- `sqlite3`
- `tcltest`

TURTLES should work with either Tcl 8.5 or 8.6, but 8.6 is recommended.

Turtles additionally requires the following programs to perform installation
and documentation auto-generation:

- `make` or `gmake`
- `doxygen`

## Installation

Installation of the library is accomplished through the use of make targets.

To install, simply type the following command:

```
    [environment variable overrides] [sudo] make install
```

### Environment Variable Overrides

Installation is configurable through a number of environment variables.
Because users may not wish or be able to install in a system-wide location,
some flexibility in this regard is provided.

#### `OWNER`

The `chown` user of the installation. Default is `root`.

#### `INSTALL_GROUP`

The `chown` group of the installation. Default depends on the target system.

`uname -s` = `Linux`, `$OWNER` = `root`: `sudo`

`uname -s` = `Linux`, `$OWNER` != `root`: first group to which `$OWNER` belongs

`uname -s` != `Linux`, `$OWNER` = `root`: `wheel`

`uname -s` != `Linux`, `$OWNER` != `root`: first group to which `$OWNER` belongs

#### `PREFIX`

The installation path prefix. Default is `/usr/local`.

#### `LIB`

The installation library path prefix. Default is `$PREFIX/lib`.

#### `DOC`

The installation documentation path prefix. Default is `$PREFIX/share/doc`.


#### `DOCDIR`

The `doxygen` output directory whence documentation is installed to `$DOC`.

Default is `./docs`.

#### `TCLSH`

The Tcl shell command used for executing tests, etc. Default is `tclsh`.

### Considerations

Note that for some target directories `sudo` or `root` access may be required.
The installation will place the packages under `$LIB/turtles-0.1`.

If `doxygen` is present on the target system, the installation will also
auto-generate documentation for the various functions defined in the packages
in both HTML and PDF format. This documentation will be placed in the path
`$DOC/turtles-0.1`.

## Usage

TURTLES is designed to add trace handlers to procs as they are defined by
the `proc` command. As such, it is recommended that users of the library
include the `turtles` package and initialize the framework as soon as possible
during program execution. Make sure that the turtles installation location
is visible to the Tcl interpreter on the target system.

### Starting Traces

Inclusion and initialization is straightforwardly accomplished as follows:

```
package require turtles
::turtles::release_the_turtles ::argv
```

The argument string variable may be replaced with any string, but most use
cases will generally be using `::argv` so that library options can be passed
through the command-line.

### Stopping Traces

Stopping the framework is likewise straightforward:

```
::turtles::capture_the_turtles
```

### Configuration

TURTLES is configured by a command line options bracketed by special delimiters,
namely between `+TURTLES`, which signals to the TURTLES command-line parser
to start processing options, and `-TURTLES`, which signals to the parser to stop
processing options. Note that TURTLES lies dormant until explicitly enabled.

The simplest command-line addendum to enable tracing:

```
+TURTLES -enabled -TURTLES
```

For more detailed information, please review the namespace documentation for
`::turtles` in `turtles.tcl`.

## Contact

To report bugs or feature requests, please submit an issue under the github
repo at https://github.com/flightaware/turtles. For other inquiries,
please contact the author and maintainer, Michael Yantosca, via e-mail at
michael.yantosca@flightaware.com.
