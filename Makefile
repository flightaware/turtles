#
# Makefile for turtles Tcl package
#
PREFIX		?= /usr/local

LIB			?= $(PREFIX)/lib
BIN			?= $(PREFIX)/bin
TCLSH		?= tclsh
UNAME_S		:= $(shell uname -s)
ifeq ($(UNAME_S),Linux)
	INSTALL_GROUP=sudo
	MAKE=make
else
	INSTALL_GROUP=wheel
	MAKE=gmake
endif

SERVER_INSTALLFILES= *.tcl
DATA_INSTALLFILES=data/*.tcl data/*.txt
CONFIGS_INSTALLFILES=data/configs/*

INSTALLDIR=$(LIB)/$(PROGNAME)

PACKAGE=turtles
TARGET=$(LIB)/$(PACKAGE)
FILES=*.tcl

GITBRANCH:=$(shell git rev-parse --abbrev-ref HEAD | tr -d -c '[:alnum:]_')
BRANCH_PACKAGE=$(PACKAGE)_$(GITBRANCH)
BRANCH_TARGET=$(LIB)/$(BRANCH_PACKAGE)


all:
	@echo "'$(MAKE) install' to install the turtles Tcl package"
	@echo "'$(MAKE) install-branch' to install a branch-specific version of the turtles Tcl package to $(BRANCHPROGNAME)"

install: install-package
install-branch: install-branch-package

test-package: tests/all.tcl tests/*.test
	@cd tests && tclsh all.tcl

pkgIndex.tcl: $(shell find . -name '*.tcl' | grep -v pkgIndex.tcl)
	echo "pkg_mkIndex ." | $(TCLSH)

install-package: pkgIndex.tcl test-package
	@echo ----- installing package
	install -d -o root -g $(INSTALL_GROUP) -m 0755 $(TARGET)
	install -o root -g $(INSTALL_GROUP) -m 0644 $(FILES) $(TARGET)/
	@echo "Installed $(PACKAGE) package to $(LIB)"


install-branch-package: pkgIndex.tcl test-package
	@echo ----- installing branch package
	@install -d -o root -g $(INSTALL_GROUP) -m 0755 $(BRANCH_TARGET)
	@install -o root -g $(INSTALL_GROUP) -m 0644 $(FILES) $(BRANCH_TARGET)/
	@$(shell pwd)/rename_package.sh $(BRANCH_TARGET) $(GITBRANCH)
	@echo "Installed $(BRANCH_PACKAGE) package to $(LIB)"

tags:
	@echo "Updating tags cache"
	@/usr/local/bin/exctags -R .

clean:
	rm -rf $(TARGET)

clean-branch:
	rm -rf $(BRANCHINSTALLDIR)
