#
# Makefile for turtles Tcl package
#
PREFIX		?= /usr/local

LIB		?= $(PREFIX)/lib
DOC     	?= $(PREFIX)/share/doc
TCLSH		?= tclsh
DOCDIR		?=./docs
# Set OWNER to $(whoami) for userspace installs.
# INSTALL_GROUP can also be explicitly overridden.
# See below for defaults.
OWNER           ?=root
UNAME_S		:= $(shell uname -s)
ifeq ($(UNAME_S),Linux)
	ifeq ($(OWNER),root)
		INSTALL_GROUP ?=sudo
	else
		INSTALL_GROUP ?=$(shell groups $(OWNER) | cut -d' ' -f1)
	endif
	MAKE=make
else
	ifeq ($(OWNER),root)
		INSTALL_GROUP ?=wheel
	else
		INSTALL_GROUP ?=$(shell groups $(OWNER) | cut -d' ' -f1)
	endif
	MAKE=gmake
endif

PACKAGE=turtles-0.1
TARGET=$(LIB)/$(PACKAGE)
DOCTARGET=$(DOC)/$(PACKAGE)
FILES=*.tcl

all:
	@echo "'[sudo] $(MAKE) install' to install the turtles Tcl package"
	@echo "=== Configurable environment variables ==="
	@echo "Installation prefix:"
	@echo "    PREFIX=$(PREFIX)"
	@echo "Package library install directory:"
	@echo "    LIB=$(LIB)"
	@echo "Package documentation install directory:"
	@echo "    DOC=$(DOC)"
	@echo "Tcl shell command:"
	@echo "    TCLSH=$(TCLSH)"
	@echo "Documentation staging directory:"
	@echo "    DOCDIR=$(DOCDIR)"

install: install-package install-docs

package: ./pkgIndex.tcl

test-package: tests/all.tcl \
	      tests/unit/*.test \
	      tests/functional/*.test \
              tests/integration/helpers.tcl tests/integration/*.test
	@cd tests && tclsh all.tcl

%/pkgIndex.tcl: $(shell find . -name '*.tcl' | grep -v pkgIndex.tcl)
	echo "pkg_mkIndex $*" | $(TCLSH)

install-package: pkgIndex.tcl docs test-package
	@echo ----- installing package
	@install -d -o $(OWNER) -g $(INSTALL_GROUP) -m 0755 $(TARGET)
	@install -o $(OWNER) -g $(INSTALL_GROUP) -m 0644 $(FILES) $(TARGET)/
	@echo "Installed $(PACKAGE) package to $(LIB)"

tags:
	@echo "Updating tags cache"
	@/usr/local/bin/exctags -R .

docs:
	@echo "Generating package documentation"
	@doxygen

install-docs:
	@echo ----- installing package docs
	@install -d -o $(OWNER) -g $(INSTALL_GROUP) -m 0755 $(DOCTARGET)
	@rsync -qvzp --chmod=Du=rwx,Dgo=rx,Fu=rw,Fog=r $(DOCDIR)/ $(DOCTARGET)/
	@echo "Installed $(PACKAGE) documentation to $(DOC)"

uninstall:
	rm -rf $(TARGET)
	rm -rf $(DOCTARGET)

clean: clean-docs
	find . -name '*~' | xargs rm -f

clean-docs:
	rm -rf $(DOCDIR)
