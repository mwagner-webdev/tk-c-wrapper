# tkx -- build, generate and test.
#
#   make deps              fetch + build pinned Tcl/Tk (tools/deps.sh)
#   make                   library, test bridge and examples
#   make generate          regenerate the committed generated files
#   make check-generated   fail if regeneration differs from the committed files
#   make test              run the tcltest suite (uses Xvfb if DISPLAY is unset)
#   make compat            build + test against Tk 9.0.4 with an API generated
#                          from the 9.0.4 sources (nothing committed changes)
#
# Variables: TK_VERSION (default 9.1.0), GEN_DIR (directory holding the
# generated include/, src/, tests/ files; default: the repository).

TK_VERSION ?= 9.1.0
TK_MM      := $(word 1,$(subst ., ,$(TK_VERSION))).$(word 2,$(subst ., ,$(TK_VERSION)))
DEPS       := deps/$(TK_VERSION)
PREFIX     := $(abspath $(DEPS)/install)
TCLSH      := $(PREFIX)/bin/tclsh$(TK_MM)
TK_SRC     := $(DEPS)/src/tk$(TK_VERSION)
TCL_SRC    := $(DEPS)/src/tcl$(TK_VERSION)
GEN_DIR    ?= .
BUILD      := build/$(TK_VERSION)

CC      ?= cc
CFLAGS  ?= -O2 -g
WARN    := -Wall -Wextra -Wno-unused-parameter -Wno-unused-label
CPPFLAGS_TKX := -I$(GEN_DIR)/include -Iinclude -Isrc -I$(PREFIX)/include
LIBS_TK := -L$(PREFIX)/lib -ltcl9tk$(TK_MM) -ltcl$(TK_MM) -Wl,-rpath,$(PREFIX)/lib

LIB_SRCS := src/tkx_runtime.c src/tkx_handles.c src/tkx_callbacks.c $(GEN_DIR)/src/tkx_generated.c
LIB_OBJS := $(patsubst %.c,$(BUILD)/obj/%.o,$(notdir $(LIB_SRCS)))
LIB      := $(BUILD)/libtkx.so
BRIDGE   := $(BUILD)/libtkxtest.so
EXAMPLES := $(BUILD)/hello $(BUILD)/layout

.PHONY: all lib bridge examples deps generate check-generated test test-headless header-test compat clean

all: lib bridge examples header-test

lib: $(LIB)
bridge: $(BRIDGE)
examples: $(EXAMPLES)

deps:
	tools/deps.sh $(TK_VERSION)

$(BUILD)/obj:
	mkdir -p $@

$(BUILD)/obj/%.o: src/%.c src/tkx_internal.h include/tkx.h $(GEN_DIR)/include/tkx_generated.h | $(BUILD)/obj
	$(CC) -std=c11 $(CFLAGS) $(WARN) -fPIC -fvisibility=hidden $(CPPFLAGS_TKX) -c $< -o $@

$(BUILD)/obj/tkx_generated.o: $(GEN_DIR)/src/tkx_generated.c src/tkx_internal.h include/tkx.h $(GEN_DIR)/include/tkx_generated.h | $(BUILD)/obj
	$(CC) -std=c11 $(CFLAGS) $(WARN) -fPIC -fvisibility=hidden $(CPPFLAGS_TKX) -c $< -o $@

$(LIB): $(LIB_OBJS)
	$(CC) -shared -o $@ $(LIB_OBJS) $(LIBS_TK)

# The tcltest bridge: a Tcl extension that calls the compiled C API.
$(BRIDGE): tests/test_bridge.c tests/test_bridge.h $(GEN_DIR)/tests/tkx_bridge_generated.c $(LIB)
	$(CC) -std=c11 $(CFLAGS) $(WARN) -fPIC -shared $(CPPFLAGS_TKX) -Itests \
	    tests/test_bridge.c $(GEN_DIR)/tests/tkx_bridge_generated.c -o $@ \
	    -L$(BUILD) -ltkx -Wl,-rpath,$(abspath $(BUILD)) $(LIBS_TK)

# Examples and the header test use only include/ (no Tcl/Tk headers).
$(BUILD)/%: examples/%.c $(LIB) include/tkx.h
	$(CC) -std=c11 $(CFLAGS) $(WARN) -I$(GEN_DIR)/include -Iinclude $< -o $@ \
	    -L$(BUILD) -ltkx -Wl,-rpath,$(abspath $(BUILD))

header-test: $(BUILD)/header_only.o
$(BUILD)/header_only.o: tests/header_only.c include/tkx.h $(GEN_DIR)/include/tkx_generated.h | $(BUILD)/obj
	$(CC) -std=c99 -pedantic -Wall -Wextra -Werror -I$(GEN_DIR)/include -Iinclude -c $< -o $@
	$(CC) -x c++ -std=c++11 -Wall -Werror -I$(GEN_DIR)/include -Iinclude -c $< -o $(BUILD)/header_only_cxx.o

generate:
	$(TCLSH) generator/generate.tcl --tk-src $(TK_SRC) --tcl-src $(TCL_SRC) --out .

check-generated:
	$(TCLSH) generator/check.tcl --tk-src $(TK_SRC) --tcl-src $(TCL_SRC)

# Run the tcltest suite.  Without a DISPLAY the suite is run under Xvfb.
test: all
	@if [ -n "$$DISPLAY" ]; then \
	    TKX_BUILD=$(BUILD) TKX_TK_SRC=$(TK_SRC) TKX_TCL_SRC=$(TCL_SRC) TKX_GEN_DIR=$(GEN_DIR) $(TCLSH) tests/all.tcl; \
	else \
	    TKX_BUILD=$(BUILD) TKX_TK_SRC=$(TK_SRC) TKX_TCL_SRC=$(TCL_SRC) TKX_GEN_DIR=$(GEN_DIR) xvfb-run -a -s "-screen 0 1280x1024x24" $(TCLSH) tests/all.tcl; \
	fi

# Headless subset (generator and ABI tests only; display tests are skipped).
test-headless: all
	env -u DISPLAY TKX_BUILD=$(BUILD) TKX_TK_SRC=$(TK_SRC) TKX_TCL_SRC=$(TCL_SRC) TKX_GEN_DIR=$(GEN_DIR) $(TCLSH) tests/all.tcl

# Compatibility: generate from the Tk 9.0.4 sources into build/9.0.4/gen and
# build/test against the Tk 9.0.4 runtime.
compat:
	tools/deps.sh 9.0.4
	deps/9.0.4/install/bin/tclsh9.0 generator/generate.tcl --tk-src deps/9.0.4/src/tk9.0.4 \
	    --tcl-src deps/9.0.4/src/tcl9.0.4 --out build/9.0.4/gen
	$(MAKE) TK_VERSION=9.0.4 GEN_DIR=build/9.0.4/gen test

clean:
	rm -rf build
