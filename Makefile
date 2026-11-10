# tkx -- build, generate and test.
#
#   make deps              fetch + build pinned Tcl/Tk (tools/deps.sh)
#   make                   library, test bridge and examples
#   make generate          regenerate the committed generated files
#   make check-generated   fail if regeneration differs from the committed files
#   make test              run the tcltest suite (Linux: uses Xvfb if DISPLAY is unset)
#   make test-headless     generator/ABI tests only; display tests are skipped
#   make compat            build + test against Tk 9.0.4 with an API generated
#                          from the 9.0.4 sources (nothing committed changes)
#
# Platforms: Linux/Unix (X11), macOS (Aqua), Windows (MSYS2 MINGW64 shell
# with gcc).  Variables: TK_VERSION (default 9.1.0), GEN_DIR (directory
# holding the generated include/, src/, tests/ files; default: the repo).

TK_VERSION ?= 9.1.0
TK_MM      := $(word 1,$(subst ., ,$(TK_VERSION))).$(word 2,$(subst ., ,$(TK_VERSION)))
TK_MMN     := $(subst .,,$(TK_MM))
DEPS       := deps/$(TK_VERSION)
PREFIX     := $(abspath $(DEPS)/install)
TK_SRC     := $(DEPS)/src/tk$(TK_VERSION)
TCL_SRC    := $(DEPS)/src/tcl$(TK_VERSION)
GEN_DIR    ?= .
BUILD      := build/$(TK_VERSION)

UNAME := $(shell uname -s)
ifneq (,$(findstring MINGW,$(UNAME))$(findstring MSYS,$(UNAME)))
  PLATFORM := windows
else ifeq ($(UNAME),Darwin)
  PLATFORM := macos
else
  PLATFORM := unix
endif

# tclsh is tclsh9.1 on Unix/macOS and tclsh91.exe on Windows.
TCLSH := $(firstword $(wildcard $(PREFIX)/bin/tclsh$(TK_MM) $(PREFIX)/bin/tclsh$(TK_MMN).exe) \
           $(PREFIX)/bin/tclsh$(TK_MM))

# Link flags come from the installed tclConfig.sh / tkConfig.sh, which know
# each platform's library names (libtcl9.1.so, libtcl9.1.dylib, tcl91.dll).
TCL_LIB_SPEC := $(shell . $(PREFIX)/lib/tclConfig.sh 2>/dev/null; echo "$$TCL_LIB_SPEC")
TK_LIB_SPEC  := $(shell . $(PREFIX)/lib/tkConfig.sh 2>/dev/null; echo "$$TK_LIB_SPEC")

ifeq ($(origin CC),default)
  ifeq ($(PLATFORM),windows)
    CC := gcc
  else
    CC := cc
  endif
endif
CFLAGS  ?= -O2 -g
WARN    := -Wall -Wextra -Wno-unused-parameter -Wno-unused-label
CPPFLAGS_TKX := -I$(GEN_DIR)/include -Iinclude -Isrc -I$(PREFIX)/include

ifeq ($(PLATFORM),windows)
  SHLIB      := .dll
  EXE        := .exe
  PICFLAGS   :=
  LIB_LDFLAGS = -shared -Wl,--out-implib,$(BUILD)/libtkx.dll.a
  SO_LDFLAGS := -shared
  RPATH_TK   :=
  RPATH_BUILD :=
  # Windows has no rpath: the Tcl/Tk DLLs (deps/.../bin) and libtkx.dll
  # must be on PATH when tests or examples run.
  RUN_ENV    := PATH="$(PREFIX)/bin:$(abspath $(BUILD)):$$PATH"
else ifeq ($(PLATFORM),macos)
  SHLIB      := .dylib
  EXE        :=
  PICFLAGS   := -fPIC -fvisibility=hidden
  LIB_LDFLAGS = -dynamiclib -Wl,-install_name,@rpath/libtkx.dylib
  SO_LDFLAGS := -dynamiclib
  RPATH_TK   := -Wl,-rpath,$(PREFIX)/lib
  RPATH_BUILD := -Wl,-rpath,$(abspath $(BUILD))
  RUN_ENV    :=
else
  SHLIB      := .so
  EXE        :=
  PICFLAGS   := -fPIC -fvisibility=hidden
  LIB_LDFLAGS = -shared
  SO_LDFLAGS := -shared
  RPATH_TK   := -Wl,-rpath,$(PREFIX)/lib
  RPATH_BUILD := -Wl,-rpath,$(abspath $(BUILD))
  RUN_ENV    :=
endif

LIBS_TK  := $(TK_LIB_SPEC) $(TCL_LIB_SPEC) $(RPATH_TK)
LIB_SRCS := src/tkx_runtime.c src/tkx_handles.c src/tkx_callbacks.c $(GEN_DIR)/src/tkx_generated.c
LIB_OBJS := $(patsubst %.c,$(BUILD)/obj/%.o,$(notdir $(LIB_SRCS)))
LIB      := $(BUILD)/libtkx$(SHLIB)
BRIDGE   := $(BUILD)/libtkxtest$(SHLIB)
EXAMPLES := $(BUILD)/hello$(EXE) $(BUILD)/layout$(EXE)
TEST_ENV := TKX_BUILD=$(BUILD) TKX_TK_SRC=$(TK_SRC) TKX_TCL_SRC=$(TCL_SRC) TKX_GEN_DIR=$(GEN_DIR)

.PHONY: all lib bridge examples deps generate check-generated test test-headless header-test \
        compat compat-generate clean info

all: lib bridge examples header-test

lib: $(LIB)
bridge: $(BRIDGE)
examples: $(EXAMPLES)

info:
	@echo "platform=$(PLATFORM) cc=$(CC) tclsh=$(TCLSH)"
	@echo "libs=$(LIBS_TK)"

deps:
	tools/deps.sh $(TK_VERSION)

$(BUILD)/obj:
	mkdir -p $@

$(BUILD)/obj/%.o: src/%.c src/tkx_internal.h include/tkx.h $(GEN_DIR)/include/tkx_generated.h | $(BUILD)/obj
	$(CC) -std=c11 $(CFLAGS) $(WARN) $(PICFLAGS) $(CPPFLAGS_TKX) -c $< -o $@

$(BUILD)/obj/tkx_generated.o: $(GEN_DIR)/src/tkx_generated.c src/tkx_internal.h include/tkx.h $(GEN_DIR)/include/tkx_generated.h | $(BUILD)/obj
	$(CC) -std=c11 $(CFLAGS) $(WARN) $(PICFLAGS) $(CPPFLAGS_TKX) -c $< -o $@

$(LIB): $(LIB_OBJS)
	$(CC) $(LIB_LDFLAGS) -o $@ $(LIB_OBJS) $(LIBS_TK)

# The tcltest bridge: a Tcl extension that calls the compiled C API.
$(BRIDGE): tests/test_bridge.c tests/test_bridge.h $(GEN_DIR)/tests/tkx_bridge_generated.c $(LIB)
	$(CC) -std=c11 $(CFLAGS) $(WARN) $(filter -fPIC,$(PICFLAGS)) $(SO_LDFLAGS) $(CPPFLAGS_TKX) -Itests \
	    tests/test_bridge.c $(GEN_DIR)/tests/tkx_bridge_generated.c -o $@ \
	    -L$(BUILD) -ltkx $(RPATH_BUILD) $(LIBS_TK)

# Examples and the header test use only include/ (no Tcl/Tk headers).
$(BUILD)/%$(EXE): examples/%.c $(LIB) include/tkx.h
	$(CC) -std=c11 $(CFLAGS) $(WARN) -I$(GEN_DIR)/include -Iinclude $< -o $@ \
	    -L$(BUILD) -ltkx $(RPATH_BUILD)

header-test: $(BUILD)/header_only.o
$(BUILD)/header_only.o: tests/header_only.c include/tkx.h $(GEN_DIR)/include/tkx_generated.h | $(BUILD)/obj
	$(CC) -std=c99 -pedantic -Wall -Wextra -Werror -I$(GEN_DIR)/include -Iinclude -c $< -o $@
	$(CC) -x c++ -std=c++11 -Wall -Werror -I$(GEN_DIR)/include -Iinclude -c $< -o $(BUILD)/header_only_cxx.o

generate:
	$(TCLSH) generator/generate.tcl --tk-src $(TK_SRC) --tcl-src $(TCL_SRC) --out .

check-generated:
	$(TCLSH) generator/check.tcl --tk-src $(TK_SRC) --tcl-src $(TCL_SRC)

# Run the tcltest suite.  On Linux without a DISPLAY it runs under Xvfb;
# macOS (Aqua) and Windows use the desktop session.
test: all
ifeq ($(PLATFORM),unix)
	@if [ -n "$$DISPLAY" ]; then \
	    $(TEST_ENV) $(TCLSH) tests/all.tcl; \
	else \
	    $(TEST_ENV) xvfb-run -a -s "-screen 0 1280x1024x24" $(TCLSH) tests/all.tcl; \
	fi
else
	$(RUN_ENV) $(TEST_ENV) $(TCLSH) tests/all.tcl
endif

# Headless subset (generator and ABI tests only; display tests are skipped).
test-headless: all
	env -u DISPLAY $(RUN_ENV) TKX_NO_DISPLAY=1 $(TEST_ENV) $(TCLSH) tests/all.tcl

# Compatibility: generate from the Tk 9.0.4 sources into build/9.0.4/gen and
# build/test against the Tk 9.0.4 runtime.
compat:
	tools/deps.sh 9.0.4
	$(MAKE) TK_VERSION=9.0.4 GEN_DIR=build/9.0.4/gen compat-generate
	$(MAKE) TK_VERSION=9.0.4 GEN_DIR=build/9.0.4/gen test

compat-generate:
	$(TCLSH) generator/generate.tcl --tk-src $(TK_SRC) --tcl-src $(TCL_SRC) --out $(GEN_DIR)

clean:
	rm -rf build
