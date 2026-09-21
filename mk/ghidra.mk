# The Ghidra project: ghidra/projects/starlancer.gpr (git-ignored; it embeds the game's code).
#
# Programs are imported in groups, one project folder per group. Imports are deliberately
# one-shot: every prerequisite is order-only and -overwrite is never passed, so nothing here can
# replace a program that has been annotated by hand. To really start over, `make
# ghidra-forget-<group>` and delete the folder in the GUI.
#
# The project is single-user: close the GUI before running any headless target, and vice versa.

##@ Ghidra

GHIDRA_PROJECT_DIR := $(GHIDRA_DIR)/projects
GHIDRA_PROJECT     := starlancer
GHIDRA_SCRIPTS_DIR := $(GHIDRA_DIR)/scripts
GHIDRA_EXPORT_DIR  := $(GHIDRA_DIR)/export

HEADLESS := $(WITH_JDK) $(GHIDRA_HOME)/support/analyzeHeadless $(GHIDRA_PROJECT_DIR)
HEADLESS_MAX_CPU ?= 8

# Re-importing replaces a program in the project, discarding anything done to it by hand. It is
# therefore opt-in: `make ghidra-import-game OVERWRITE=1`, for when the input file itself changed.
OVERWRITE ?=
IMPORT_FLAGS := $(if $(OVERWRITE),-overwrite)

# Group -> files, relative to game/.
GHIDRA_GROUPS := game safedisc surrender vfx

# The game itself: the executable recovered from the SafeDisc wrapper, plus the language resource
# DLLs it loads. This is the subject of the decompilation.
GHIDRA_FILES_game := decrypted/LANCER.EXE install/LANGUAGE.DLL
# The SafeDisc 1.40 kit: the loader that stands in for the game, and its helpers on disc 1.
GHIDRA_FILES_safedisc := install/LANCER.EXE cd1/DPLAYERX.DLL cd1/CLCD32.DLL cd1/DRVMGT.DLL cd1/SECDRV.SYS
# "Surrender", the 3D renderer: DirectDraw and Direct3D 7 back ends, plus its math and allocator.
GHIDRA_FILES_surrender := install/srddraw.dll install/srd3d.dll install/srfastmath.dll install/srmemory.dll
# Miles Design's 2D library (WinVFX) and system abstraction layer (SAL).
GHIDRA_FILES_vfx := install/vfx.dll install/winvfx8.dll install/winvfx16.dll install/w32sal.dll

.PHONY: ghidra-import
ghidra-import: $(addprefix ghidra-import-,$(GHIDRA_GROUPS)) ## Import and auto-analyse every program group (headless)

.PHONY: ghidra-export
ghidra-export: $(addprefix ghidra-export-,$(GHIDRA_GROUPS)) ## Dump functions, strings, disassembly and C for every group into ghidra/export

# ghidra-import-<group>, ghidra-export-<group>, ghidra-forget-<group>
define GHIDRA_GROUP_RULES
.PHONY: ghidra-import-$(1) ghidra-export-$(1) ghidra-forget-$(1)
ghidra-import-$(1): $$(GHIDRA_PROJECT_DIR)/.imported-$(1)

$$(GHIDRA_PROJECT_DIR)/.imported-$(1): | $$(GAME_DIR)/.stamp-install $$(STAMPS_DIR)/ghidra-natives
	mkdir -p $$(GHIDRA_PROJECT_DIR)
	$$(HEADLESS) $$(GHIDRA_PROJECT)/$(1) \
	    -import $$(addprefix $$(GAME_DIR)/,$$(GHIDRA_FILES_$(1))) $$(IMPORT_FLAGS) \
	    -max-cpu $$(HEADLESS_MAX_CPU) -analysisTimeoutPerFile 3600 \
	    -log $$(GHIDRA_PROJECT_DIR)/import-$(1).log
	touch $$@

ghidra-export-$(1): | $$(GHIDRA_PROJECT_DIR)/.imported-$(1)
	mkdir -p $$(GHIDRA_EXPORT_DIR)/$(1)
	$$(HEADLESS) $$(GHIDRA_PROJECT)/$(1) -process -noanalysis -readOnly \
	    -scriptPath $$(GHIDRA_SCRIPTS_DIR) -postScript ExportProgram.java $$(GHIDRA_EXPORT_DIR)/$(1) \
	    -max-cpu $$(HEADLESS_MAX_CPU) -log $$(GHIDRA_PROJECT_DIR)/export-$(1).log

ghidra-forget-$(1):
	rm -f $$(GHIDRA_PROJECT_DIR)/.imported-$(1)
endef
$(foreach group,$(GHIDRA_GROUPS),$(eval $(call GHIDRA_GROUP_RULES,$(group))))

# Runs one Ghidra script against a group, with the program writable so the script may annotate it.
# SCRIPT names a file in ghidra/scripts, ARGS are passed to it, and GROUP defaults to the game.
SCRIPT ?=
ARGS   ?=
GROUP  ?= game

.PHONY: ghidra-run
ghidra-run: | $(GHIDRA_PROJECT_DIR)/.imported-$(GROUP) ## Run a Ghidra script: make ghidra-run SCRIPT=Name.java [ARGS="..."] [GROUP=game]
	@test -n "$(SCRIPT)" || { echo "set SCRIPT=<file in ghidra/scripts>"; exit 1; }
	$(HEADLESS) $(GHIDRA_PROJECT)/$(GROUP) -process -noanalysis \
	    -scriptPath $(GHIDRA_SCRIPTS_DIR) -postScript $(SCRIPT) $(ARGS) \
	    -max-cpu $(HEADLESS_MAX_CPU) -log $(GHIDRA_PROJECT_DIR)/script-$(GROUP).log

GHIDRA_NAMES_DIR := $(GHIDRA_DIR)/names
GHIDRAGEN_DIR    := $(ROOT)/zig-out/ghidra

.PHONY: ghidra-annotate
ghidra-annotate: | $(GHIDRA_PROJECT_DIR)/.imported-game ## Name and type the payload's known functions and data, from ghidra/names and the Zig definitions
	$(ZIG) build ghidragen
	mkdir -p $(GHIDRAGEN_DIR)
	$(ROOT)/zig-out/bin/ghidragen types $(GHIDRAGEN_DIR)/types.tsv
	$(ROOT)/zig-out/bin/ghidragen names $(GHIDRAGEN_DIR)/names.tsv
	$(HEADLESS) $(GHIDRA_PROJECT)/game -process LANCER.EXE -noanalysis \
	    -scriptPath $(GHIDRA_SCRIPTS_DIR) \
	    -postScript Annotate.java $(GHIDRAGEN_DIR)/types.tsv \
	        $(GHIDRAGEN_DIR)/names.tsv $(GHIDRA_NAMES_DIR)/LANCER.EXE.runtime.tsv \
	        $(GHIDRA_NAMES_DIR)/LANCER.EXE.tsv \
	    -max-cpu $(HEADLESS_MAX_CPU) -log $(GHIDRA_PROJECT_DIR)/annotate.log

.PHONY: ghidra-gui
ghidra-gui: | $(STAMPS_DIR)/ghidra-natives ## Open the project in the Ghidra GUI; the Ghydra plugin serves HTTP on :8192+ per open program
	$(WITH_JDK) $(GHIDRA_HOME)/ghidraRun "$(GHIDRA_PROJECT_DIR)/$(GHIDRA_PROJECT).gpr"

.PHONY: ghydra-status
ghydra-status: | $(STAMPS_DIR)/ghydra-cli ## List the Ghidra instances the ghydra CLI / MCP bridge can reach
	$(VENV_DIR)/bin/ghydra instances list

##@ Derived tables

VM_OPCODES     := $(ROOT)/src/formats/vm_opcodes.zig
VM_DISASSEMBLY := $(GHIDRA_EXPORT_DIR)/game/LANCER.EXE/disassembly.asm

.PHONY: vm-opcodes
vm-opcodes: ## Re-derive the mission script VM's opcode table from the payload executable
	@test -f $(VM_DISASSEMBLY) || { echo "missing $(VM_DISASSEMBLY); run 'make ghidra-export-game'" >&2; exit 1; }
	$(ZIG) build tablegen
	$(ROOT)/zig-out/bin/tablegen opcodes $(PAYLOAD) $(VM_DISASSEMBLY) $(VM_OPCODES)
	$(ZIG) fmt $(VM_OPCODES)

VM_COMMANDS   := $(ROOT)/src/formats/vm_commands.zig
VM_CONDITIONS := $(ROOT)/src/formats/vm_conditions.zig

.PHONY: vm-commands
vm-commands: ## Re-derive the mission script's command catalogue from the payload executable
	@test -f $(PAYLOAD) || { echo "missing $(PAYLOAD); run 'make game'" >&2; exit 1; }
	$(ZIG) build tablegen
	$(ROOT)/zig-out/bin/tablegen commands $(PAYLOAD) $(VM_COMMANDS)
	$(ZIG) fmt $(VM_COMMANDS)

.PHONY: vm-conditions
vm-conditions: ## Re-derive the trigger condition catalogue from the payload executable
	@test -f $(PAYLOAD) || { echo "missing $(PAYLOAD); run 'make game'" >&2; exit 1; }
	$(ZIG) build tablegen
	$(ROOT)/zig-out/bin/tablegen conditions $(PAYLOAD) $(VM_CONDITIONS)
	$(ZIG) fmt $(VM_CONDITIONS)

MODEL_TABLES := $(ROOT)/src/formats/models.zig

.PHONY: model-tables
model-tables: ## Re-derive the ship type and attachment model tables from the payload executable
	@test -f $(VM_DISASSEMBLY) || { echo "missing $(VM_DISASSEMBLY); run 'make ghidra-export-game'" >&2; exit 1; }
	$(ZIG) build tablegen
	$(ROOT)/zig-out/bin/tablegen models $(PAYLOAD) $(VM_DISASSEMBLY) $(MODEL_TABLES)
	$(ZIG) fmt $(MODEL_TABLES)

CONTROL_TABLES := $(ROOT)/src/formats/controls.zig

.PHONY: control-tables
control-tables: ## Re-derive the player's actions and default bindings from the payload executable
	@test -f $(PAYLOAD) || { echo "missing $(PAYLOAD); run 'make game'" >&2; exit 1; }
	$(ZIG) build tablegen
	$(ROOT)/zig-out/bin/tablegen controls $(PAYLOAD) $(CONTROL_TABLES)
	$(ZIG) fmt $(CONTROL_TABLES)

ORDER_TABLES := $(ROOT)/src/formats/orders.zig

.PHONY: order-tables
order-tables: ## Re-derive the order table, what objects are told to do, from the payload executable
	@test -f $(PAYLOAD) || { echo "missing $(PAYLOAD); run 'make game'" >&2; exit 1; }
	$(ZIG) build tablegen
	$(ROOT)/zig-out/bin/tablegen orders $(PAYLOAD) $(ORDER_TABLES)
	$(ZIG) fmt $(ORDER_TABLES)

MANEUVER_TABLES := $(ROOT)/src/formats/maneuvers.zig

.PHONY: maneuver-tables
maneuver-tables: ## Re-derive the combat maneuvers, their scripts and handlers from the payload executable
	@test -f $(PAYLOAD) || { echo "missing $(PAYLOAD); run 'make game'" >&2; exit 1; }
	$(ZIG) build tablegen
	$(ROOT)/zig-out/bin/tablegen maneuvers $(PAYLOAD) $(MANEUVER_TABLES)
	$(ZIG) fmt $(MANEUVER_TABLES)
