# Our own code. build.zig owns compilation; these targets only make it reachable from `make` and
# give the other fragments a file ($(SLTOOL)) to depend on.

##@ Code (Zig)

SLTOOL      := $(ROOT)/zig-out/bin/sltool
ZIG_SOURCES := $(ROOT)/build.zig $(ROOT)/build.zig.zon $(shell find $(ROOT)/src -name '*.zig')

.PHONY: build
build: $(SLTOOL) ## Build the tools into zig-out/bin

$(SLTOOL): $(ZIG_SOURCES)
	$(ZIG) build -Doptimize=ReleaseSafe
	@touch $@

# The engine, optimized, for the host's own processor: a Zig built for Intel Macs, run under Rosetta
# on Apple silicon, would otherwise build it for Intel too.
GAME_TARGET := $(if $(and $(filter Darwin,$(HOST_OS)),$(filter arm64 aarch64,$(HOST_ARCH))),-Dtarget=aarch64-macos,)

.PHONY: play
play: | $(GAME_DIR)/.stamp-install ## Build OpenReliant optimized and run it on the installed game files
	$(ZIG) build -Doptimize=ReleaseFast $(GAME_TARGET)
	$(ROOT)/zig-out/bin/openreliant $(INSTALL_DIR)

# The game's one shader, for each GPU interface SDL runs on: SPIR-V for Vulkan, and Metal's
# language from that. The outputs are committed, so building needs neither tool; regenerating needs
# glslc (from shaderc) on the PATH, and SPIRV-Cross, which this builds.
SHADER_DIR := $(ROOT)/src/platform/shaders
SHADERS    := $(foreach name,device bloom,$(foreach stage,vert frag,$(SHADER_DIR)/$(name).$(stage).spv $(SHADER_DIR)/$(name).$(stage).msl))
GLSLC      ?= glslc

.PHONY: shaders
shaders: $(SHADERS) ## Compile the game's shader for Vulkan and Metal (needs glslc)

$(SHADER_DIR)/%.vert.spv: $(SHADER_DIR)/%.glsl
	$(GLSLC) -fshader-stage=vertex -DVERTEX -O $< -o $@

$(SHADER_DIR)/%.frag.spv: $(SHADER_DIR)/%.glsl
	$(GLSLC) -fshader-stage=fragment -DFRAGMENT -O $< -o $@

$(SHADER_DIR)/%.msl: $(SHADER_DIR)/%.spv | $(SPIRV_CROSS)
	$(SPIRV_CROSS) $< --msl --msl-version 20200 --msl-decoration-binding --output $@

.PHONY: test
test: ## Run the unit tests
	$(ZIG) build test --summary all

.PHONY: fmt
fmt: ## Format the Zig sources
	$(ZIG) fmt build.zig src

.PHONY: fmt-check
fmt-check: ## Fail if any Zig source is not formatted
	$(ZIG) fmt --check build.zig src

.PHONY: zig-clean
zig-clean:
	rm -rf $(ROOT)/.zig-cache $(ROOT)/zig-out
