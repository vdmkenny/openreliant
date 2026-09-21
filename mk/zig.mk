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

# The game, optimized, for the host's own processor: a Zig built for Intel Macs, run under Rosetta
# on Apple silicon, would otherwise build the game for Intel too.
GAME_TARGET := $(if $(and $(filter Darwin,$(HOST_OS)),$(filter arm64 aarch64,$(HOST_ARCH))),-Dtarget=aarch64-macos,)

.PHONY: play
play: | $(GAME_DIR)/.stamp-install ## Build the game optimized and run it on the installed game files
	$(ZIG) build -Doptimize=ReleaseFast $(GAME_TARGET)
	$(ROOT)/zig-out/bin/starlancer $(INSTALL_DIR)

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
