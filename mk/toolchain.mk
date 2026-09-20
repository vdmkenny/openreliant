# Third-party toolchain, all of it under tools/ (git-ignored): a JDK, Ghidra with native helpers
# for this host, Maven, and the GhydraMCP plugin + CLI.
#
# Each step leaves a stamp in tools/.stamps/, so `make setup` only does what is missing. Downloads
# are order-only prerequisites: a re-fetched archive never forces a rebuild.

##@ Toolchain

.PHONY: setup
setup: jdk ghidra ghydra ## Install the whole toolchain into tools/

$(DOWNLOADS_DIR) $(STAMPS_DIR):
	mkdir -p $@

# --- JDK (Eclipse Temurin) --------------------------------------------------------------------

JDK_ARCHIVE := $(DOWNLOADS_DIR)/temurin-$(JDK_MAJOR)-$(ADOPTIUM_OS)-$(ADOPTIUM_ARCH).tar.gz
JDK_URL     := https://api.adoptium.net/v3/binary/latest/$(JDK_MAJOR)/ga/$(ADOPTIUM_OS)/$(ADOPTIUM_ARCH)/jdk/hotspot/normal/eclipse

.PHONY: jdk
jdk: $(STAMPS_DIR)/jdk ## Eclipse Temurin JDK for this host (Ghidra 12 needs 21+)

$(JDK_ARCHIVE): | $(DOWNLOADS_DIR)
	$(CURL) --output $@ "$(JDK_URL)"

# The archive unpacks to jdk-<version>/; on macOS the JDK proper is in Contents/Home below that.
$(STAMPS_DIR)/jdk: | $(JDK_ARCHIVE) $(STAMPS_DIR)
	tar -xzf $(JDK_ARCHIVE) -C $(TOOLS_DIR)
	top=$$(tar -tzf $(JDK_ARCHIVE) | head -1 | cut -d/ -f1); \
	home=$$top; if [ -d "$(TOOLS_DIR)/$$top/Contents/Home" ]; then home=$$top/Contents/Home; fi; \
	ln -sfn "$$home" $(JDK_HOME)
	$(JDK_HOME)/bin/java -version
	touch $@

# --- Ghidra -----------------------------------------------------------------------------------

GHIDRA_ARCHIVE := $(DOWNLOADS_DIR)/ghidra_$(GHIDRA_VERSION)_PUBLIC_$(GHIDRA_DATE).zip
GHIDRA_URL     := https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_$(GHIDRA_VERSION)_build/$(notdir $(GHIDRA_ARCHIVE))

.PHONY: ghidra
ghidra: $(STAMPS_DIR)/ghidra-natives ## Ghidra, with native helpers built for this host

$(GHIDRA_ARCHIVE): | $(DOWNLOADS_DIR)
	$(CURL) --output $@ "$(GHIDRA_URL)"
	scripts/verify-hash.sh sha256 $(GHIDRA_SHA256) $@

$(STAMPS_DIR)/ghidra: | $(GHIDRA_ARCHIVE) $(STAMPS_DIR)
	unzip -q -o $(GHIDRA_ARCHIVE) -d $(TOOLS_DIR)
	ln -sfn $(notdir $(GHIDRA_HOME)) $(TOOLS_DIR)/ghidra
	@# Pin Ghidra to the project JDK so it also starts when launched outside of make.
	sed -i.orig 's|^JAVA_HOME_OVERRIDE=.*|JAVA_HOME_OVERRIDE=$(JDK_HOME)|' $(GHIDRA_HOME)/support/launch.properties
	touch $@

# Release archives carry natives for Windows and Linux x86-64 only. Everywhere else (notably
# macOS) the decompiler has to be compiled, which needs a C++ toolchain (Xcode CLT on macOS).
$(STAMPS_DIR)/ghidra-natives: $(STAMPS_DIR)/ghidra $(STAMPS_DIR)/jdk
	if [ -x "$(GHIDRA_HOME)/Ghidra/Features/Decompiler/os/$(GHIDRA_PLATFORM)/decompile" ]; then \
	    echo "Ghidra ships natives for $(GHIDRA_PLATFORM)"; \
	else \
	    gradle=$$(command -v gradle || echo ./gradlew); \
	    cd $(GHIDRA_HOME)/support/gradle && $(WITH_JDK) $$gradle --no-daemon --quiet buildNatives; \
	    test -x "$(GHIDRA_HOME)/Ghidra/Features/Decompiler/build/os/$(GHIDRA_PLATFORM)/decompile"; \
	fi
	touch $@

# --- Maven (only needed to build the GhydraMCP plugin) ----------------------------------------

MAVEN_ARCHIVE := $(DOWNLOADS_DIR)/apache-maven-$(MAVEN_VERSION)-bin.tar.gz
MAVEN_URL     := https://dlcdn.apache.org/maven/maven-3/$(MAVEN_VERSION)/binaries/$(notdir $(MAVEN_ARCHIVE))

$(MAVEN_ARCHIVE): | $(DOWNLOADS_DIR)
	$(CURL) --output $@ "$(MAVEN_URL)"
	scripts/verify-hash.sh sha512 $(MAVEN_SHA512) $@

$(STAMPS_DIR)/maven: | $(MAVEN_ARCHIVE) $(STAMPS_DIR)
	tar -xzf $(MAVEN_ARCHIVE) -C $(TOOLS_DIR)
	touch $@

# --- GhydraMCP --------------------------------------------------------------------------------
#
# Three parts: the Ghidra plugin (HTTP API inside the CodeBrowser), the `ghydra` CLI, and the MCP
# bridge. The bridge is configured in .mcp.json; the other two are installed here.

.PHONY: ghydra
ghydra: $(STAMPS_DIR)/ghydra-plugin $(STAMPS_DIR)/ghydra-cli ## GhydraMCP: Ghidra plugin + `ghydra` CLI

$(STAMPS_DIR)/ghydra-src: | $(STAMPS_DIR)
	if [ -d $(GHYDRA_SRC)/.git ]; then \
	    git -C $(GHYDRA_SRC) fetch --quiet --tags origin; \
	else \
	    git clone --quiet $(GHYDRA_REPO) $(GHYDRA_SRC); \
	fi
	git -C $(GHYDRA_SRC) -c advice.detachedHead=false checkout --quiet $(GHYDRA_REF)
	touch $@

# Build against our exact Ghidra, install like File > Install Extensions would, and switch the
# plugin on in the CodeBrowser tool so it needs no clicking through Ghidra's configure dialogs.
$(STAMPS_DIR)/ghydra-plugin: $(STAMPS_DIR)/ghydra-src $(STAMPS_DIR)/ghidra $(STAMPS_DIR)/jdk $(STAMPS_DIR)/maven
	rm -f $(GHYDRA_SRC)/target/Ghydra-*.zip
	cd $(GHYDRA_SRC) && $(WITH_JDK) GHIDRA_HOME="$(GHIDRA_HOME)" \
	    $(MAVEN_HOME)/bin/mvn --batch-mode --quiet package -DskipTests -Dghidra.version=$(GHIDRA_VERSION)
	mkdir -p "$(GHIDRA_USER_DIR)/Extensions"
	rm -rf "$(GHIDRA_USER_DIR)/Extensions/Ghydra"
	unzip -q -o "$$(ls $(GHYDRA_SRC)/target/Ghydra-*.zip | grep -v Complete)" -d "$(GHIDRA_USER_DIR)/Extensions"
	scripts/seed-codebrowser-tool.sh "$(GHIDRA_HOME)" "$(GHIDRA_USER_DIR)"
	touch $@

$(STAMPS_DIR)/ghydra-cli: $(STAMPS_DIR)/ghydra-src
	uv venv --quiet --allow-existing --python 3.12 $(VENV_DIR)
	uv pip install --quiet --python $(VENV_DIR)/bin/python $(GHYDRA_SRC)
	$(VENV_DIR)/bin/ghydra --version
	touch $@
