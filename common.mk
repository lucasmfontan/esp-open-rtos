# esp-open-rtos common Makefile
#
# ******************************************************************
# Run 'make help' in any example subdirectory to see a usage summary
# (or skip to the bottom of this file!)
#
# For example, from the top level run:
# make help -C examples/http_get
# ******************************************************************
#
# In-depth documentation is at https://github.com/SuperHouse/esp-open-rtos/wiki/Build-Process
#
# Most sections Copyright 2015 Superhouse Automation Pty Ltd
# BSD Licensed as described in the file LICENSE at top level.
#
# This makefile is adapted from the esp-mqtt makefile by @tuanpmt
# https://github.com/tuanpmt/esp_mqtt, but it has changed significantly
# since then.
#
# assume the 'root' directory (ie top of the tree) is the directory common.mk is in
ROOT := $(dir $(lastword $(MAKEFILE_LIST)))

# include optional local overrides at the root level, then in program directory
-include $(ROOT)local.mk
-include local.mk

ifndef PROGRAM
	$(error "Set the PROGRAM environment variable in your Makefile before including common.mk"
endif

# esptool defaults
ESPTOOL ?= esptool.py
ESPBAUD ?= 115200

# Output directories to store intermediate compiled files
# relative to the program directory
BUILD_DIR ?= $(PROGRAM_DIR)build/
FW_BASE ?= $(PROGRAM_DIR)firmware/

# we create two different files for uploading into the flash
# these are the names and options to generate them
FW_1	= 0x00000
FW_2	= 0x40000

FLAVOR ?= release # or debug

# Compiler names, etc. assume gdb
ESPPORT ?= /dev/ttyUSB0
CROSS ?= xtensa-lx106-elf-

AR = $(CROSS)ar
CC = $(CROSS)gcc
LD = $(CROSS)gcc
NM = $(CROSS)nm
CPP = $(CROSS)g++
SIZE = $(CROSS)size
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump

# Source components to compile and link. Each of these are subdirectories
# of the root, with a 'component.mk' file.
COMPONENTS     ?= core FreeRTOS lwip axtls

# binary esp-iot-rtos SDK libraries to link. These are pre-processed prior to linking.
SDK_LIBS		?= main net80211 phy pp wpa

# open source libraries linked in
LIBS ?= gcc hal

# Note: this isn't overridable without a not-yet-merged patch to esptool
ENTRY_SYMBOL = call_user_start

CFLAGS		= -Wall -Werror -Wl,-EL -nostdlib -mlongcalls -mtext-section-literals -std=gnu99
LDFLAGS		= -nostdlib -Wl,--no-check-sections -Wl,-L$(BUILD_DIR)sdklib -Wl,-L$(ROOT)lib -u $(ENTRY_SYMBOL) -Wl,-static -Wl,-Map=build/${PROGRAM}.map

ifeq ($(FLAVOR),debug)
    CFLAGS += -g -O0
    LDFLAGS += -g -O0
else
    CFLAGS += -g -O2
    LDFLAGS += -g -O2
endif

GITSHORTREV=\"$(shell cd $(ROOT); git rev-parse --short -q HEAD)\"
CFLAGS += -DGITSHORTREV=$(GITSHORTREV)

LINKER_SCRIPTS  = $(ROOT)ld/eagle.app.v6.ld $(ROOT)ld/eagle.rom.addr.v6.ld

####
#### no user configurable options below here
####

# hacky way to get a single space value
empty :=
space := $(empty) $(empty)

# GNU Make lowercase function, bit of a horrorshow but works (courtesy http://stackoverflow.com/a/665045)
lc = $(subst A,a,$(subst B,b,$(subst C,c,$(subst D,d,$(subst E,e,$(subst F,f,$(subst G,g,$(subst H,h,$(subst I,i,$(subst J,j,$(subst K,k,$(subst L,l,$(subst M,m,$(subst N,n,$(subst O,o,$(subst P,p,$(subst Q,q,$(subst R,r,$(subst S,s,$(subst T,t,$(subst U,u,$(subst V,v,$(subst W,w,$(subst X,x,$(subst Y,y,$(subst Z,z,$1))))))))))))))))))))))))))

# assume the program dir is the directory the top-level makefile was run in
PROGRAM_DIR := $(dir $(firstword $(MAKEFILE_LIST)))

# derive various parts of compiler/linker arguments
SDK_LIB_ARGS         = $(addprefix -l,$(SDK_LIBS))
LIB_ARGS             = $(addprefix -l,$(LIBS))
PROGRAM_OUT   = $(BUILD_DIR)$(PROGRAM).out
LDFLAGS      += $(addprefix -T,$(LINKER_SCRIPTS))
FW_FILE_1    = $(addprefix $(FW_BASE),$(FW_1).bin)
FW_FILE_2    = $(addprefix $(FW_BASE),$(FW_2).bin)

# Common include directories, shared across all "components"
# components will add their include directories to this argument
#
# Placing $(PROGRAM_DIR) and $(PROGRAM_DIR)include first allows
# programs to have their own copies of header config files for components
# , which is useful for overriding things.
INC_DIRS      = $(PROGRAM_DIR) $(PROGRAM_DIR)include $(ROOT)include

ifeq ("$(V)","1")
Q :=
vecho := @true
else
Q := @
vecho := @echo
endif

.PHONY: all clean debug_print

all: $(PROGRAM_OUT) $(FW_FILE_1) $(FW_FILE_2)

# component_compile_rules: Produces compilation rules for a given
# component
#
# Call arguments are:
# $(1) - component name
#
# Expects that the following component-specific variables are defined:
#
# $(1)_ROOT    = Top-level dir containing component. Can be in-tree or out-of-tree.
# $(1)_SRC_DIR = List of source directories for the component. All must be under $(1)_ROOT
# $(1)_INC_DIR = List of include directories specific for the component
#
# As an alternative to $(1)_SRC_DIR, you can specify source filenames
# as $(1)_SRC_FILES. If you want to specify both directories and
# some additional files, specify directories in $(1)_SRC_DIR and
# additional files in $(1)_EXTRA_SRC_FILES.
#
# Optional variables:
# $(1)_CFLAGS  = CFLAGS to override the default CFLAGS for this component only.
#
# Each call appends to COMPONENT_ARS which is a list of archive files for compiled components
COMPONENT_ARS =
define component_compile_rules
$(1)_OBJ_DIR   = $(call lc,$(BUILD_DIR)$(1)/)
### determine source files and object files ###
$(1)_SRC_FILES ?= $$(foreach sdir,$$($(1)_SRC_DIR),$$(wildcard $$(sdir)/*.c)) $$($(1)_EXTRA_SRC_FILES)
$(1)_REAL_SRC_FILES = $$(foreach sfile,$$($(1)_SRC_FILES),$$(realpath $$(sfile)))
$(1)_REAL_ROOT = $$(realpath $$($(1)_ROOT))
# patsubst here substitutes real component root path for the relative OBJ_DIR path, making things short again
$(1)_OBJ_FILES = $$(patsubst $$($(1)_REAL_ROOT)%.c,$$($(1)_OBJ_DIR)%.o,$$($(1)_REAL_SRC_FILES))
# the last included makefile is our component's component.mk makefile (rebuild the component if it changes)
$(1)_MAKEFILE ?= $(lastword $(MAKEFILE_LIST))

### determine compiler arguments ###
$(1)_CFLAGS ?= $(CFLAGS)
$(1)_CC_ARGS = $(Q) $(CC) $$(addprefix -I,$$(INC_DIRS)) $$(addprefix -I,$$($(1)_INC_DIR)) $$($(1)_CFLAGS)
$(1)_AR = $(call lc,$(BUILD_DIR)$(1).a)

$$($(1)_OBJ_DIR)%.o: $$($(1)_REAL_ROOT)%.c $$($(1)_MAKEFILE) $(wildcard $(ROOT)*.mk) | $$($(1)_SRC_DIR)
	$(vecho) "CC $$<"
	$(Q) mkdir -p $$(dir $$@)
	$$($(1)_CC_ARGS) -c $$< -o $$@
	$$($(1)_CC_ARGS) -MM -MT $$@ -MF $$(@:.o=.d) $$<
	$(Q) $(OBJCOPY) --rename-section .text=.irom0.text --rename-section .literal=.irom0.literal $$@

# the component is shown to depend on both obj and source files so we get a meaningful error message
# for missing explicitly named source files
$$($(1)_AR): $$($(1)_OBJ_FILES) $$($(1)_SRC_FILES)
	$(vecho) "AR $$@"
	$(Q) $(AR) cru $$@ $$^

COMPONENT_ARS += $$($(1)_AR)

-include $$($(1)_OBJ_FILES:.o=.d)
endef

## Linking rules for SDK libraries
## SDK libraries are preprocessed to:
# - prefix all defined symbols with 'sdk_'
# - weaken all global symbols so they can be overriden from the open SDK side

# SDK binary libraries are preprocessed into build/lib
SDK_PROCESSED_LIBS = $(addsuffix .a,$(addprefix $(BUILD_DIR)sdklib/lib,$(SDK_LIBS)))

# Make rule for preprocessing each SDK library
#
$(BUILD_DIR)sdklib/%.a: $(ROOT)lib/%.a $(BUILD_DIR)sdklib/allsymbols.rename
	$(vecho) "Pre-processing SDK library $< -> $@"
	$(Q) $(OBJCOPY) --redefine-syms $(word 2,$^) --weaken $< $@


# Generate a regex to match symbols we don't want to rename, by parsing
# a list of symbol names
$(BUILD_DIR)sdklib/norename.match: $(ROOT)lib/symbols_norename.txt | $(BUILD_DIR)sdklib
	grep -v "^#" $< | sed ':begin;$!N;s/\n/\\|/;tbegin' > $@

# Generate list of defined symbols to rename from a single library. Uses grep & sed.
$(BUILD_DIR)sdklib/%.rename: $(ROOT)lib/%.a $(BUILD_DIR)sdklib/norename.match
	$(vecho) "Building symbol list for $< -> $@"
	$(Q) $(OBJDUMP) -t $< | grep ' g ' \
		| sed -r 's/^.+ ([^ ]+)$$/\1 sdk_\1/' \
		| grep -v `cat $(BUILD_DIR)sdklib/norename.match` > $@

# Build master list of all SDK-defined symbols to rename
$(BUILD_DIR)sdklib/allsymbols.rename: $(patsubst %.a,%.rename,$(SDK_PROCESSED_LIBS))
	cat $^ > $@

# include "dummy component" for the 'program' object files, defined in the Makefile
PROGRAM_SRC_DIR ?= $(PROGRAM_DIR)
PROGRAM_ROOT ?= $(PROGRAM_DIR)
PROGRAM_MAKEFILE = $(firstword $(MAKEFILE_LIST))
$(eval $(call component_compile_rules,PROGRAM))

## Include other components (this is where the actual compiler sections are generated)
$(foreach component,$(COMPONENTS), $(eval include $(ROOT)$(component)/component.mk))

# final linking step to produce .elf
$(PROGRAM_OUT): $(COMPONENT_ARS) $(SDK_PROCESSED_LIBS) $(LINKER_SCRIPTS)
	$(vecho) "LD $@"
	$(Q) $(LD) $(LDFLAGS) -Wl,--start-group $(SDK_LIB_ARGS) $(LIB_ARGS) $(COMPONENT_ARS) -Wl,--end-group -o $@

$(BUILD_DIR) $(FW_BASE) $(BUILD_DIR)sdklib:
	$(Q) mkdir -p $@

$(FW_FILE_1) $(FW_FILE_2): $(PROGRAM_OUT) $(FW_BASE)
	$(vecho) "FW $@"
	$(ESPTOOL) elf2image $< -o $(FW_BASE)

flash: $(FW_FILE_1) $(FW_FILE_2)
	$(ESPTOOL) -p $(ESPPORT) --baud $(ESPBAUD) write_flash $(FW_1) $(FW_FILE_1) $(FW_2) $(FW_FILE_2)

size: $(PROGRAM_OUT)
	$(Q) $(CROSS)size --format=sysv $(PROGRAM_OUT)

test: flash
	screen $(ESPPORT) 115200

# the rebuild target is written like this so it can be run in a parallel build
# environment without causing weird side effects
rebuild:
	$(MAKE) clean
	$(MAKE) all

clean:
	$(Q) rm -rf $(BUILD_DIR)
	$(Q) rm -rf $(FW_BASE)

# prevent "intermediate" files from being deleted
.SECONDARY:

# print some useful help stuff
help:
	@echo "esp-open-rtos make"
	@echo ""
	@echo "Other targets:"
	@echo ""
	@echo "all"
	@echo "Default target. Will build firmware including any changed source files."
	@echo
	@echo "clean"
	@echo "Delete all build output."
	@echo ""
	@echo "rebuild"
	@echo "Build everything fresh from scratch."
	@echo ""
	@echo "flash"
	@echo "Build then upload firmware to MCU. Set ESPPORT & ESPBAUD to override port/baud rate."
	@echo ""
	@echo "test"
	@echo "'flash', then start a GNU Screen session on the same serial port to see serial output."
	@echo ""
	@echo "size"
	@echo "Build, then print a summary of built firmware size."
	@echo ""
	@echo "TIPS:"
	@echo "* You can use -jN for parallel builds. Much faster! Use 'make rebuild' instead of 'make clean all' for parallel builds."
	@echo "* You can create a local.mk file to create local overrides of variables like ESPPORT & ESPBAUD."
	@echo ""
	@echo "SAMPLE COMMAND LINE:"
	@echo "make -j2 test ESPPORT=/dev/ttyUSB0"
	@echo ""


