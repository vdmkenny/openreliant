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
	    -import $$(addprefix $$(GAME_DIR)/,$$(GHIDRA_FILES_$(1))) \
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

.PHONY: ghidra-gui
ghidra-gui: | $(STAMPS_DIR)/ghidra-natives ## Open the project in the Ghidra GUI; the Ghydra plugin serves HTTP on :8192+ per open program
	$(WITH_JDK) $(GHIDRA_HOME)/ghidraRun "$(GHIDRA_PROJECT_DIR)/$(GHIDRA_PROJECT).gpr"

.PHONY: ghydra-status
ghydra-status: | $(STAMPS_DIR)/ghydra-cli ## List the Ghidra instances the ghydra CLI / MCP bridge can reach
	$(VENV_DIR)/bin/ghydra instances list
