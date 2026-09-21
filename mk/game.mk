# The game itself, all of it under game/ (git-ignored; none of it is ours to redistribute).
#
#   game/discs/disc<N>.bin   raw images of your own discs, which you supply
#   game/cd<N>/              the files on each disc
#   game/install/            what the installer would put on disk: LANCER.CAB unpacked, plus the
#                            loader and language DLLs it copies from the disc
#   game/decrypted/          the payload executable, recovered from the SafeDisc wrapper
#   game/assets/<archive>/   the contents of each .HOG, decompressed
#   game/models/             the .SHP models as Wavefront OBJ
#   game/sprites/            the .SPR shapes as PNG
#
# Extraction is pure Zig (sltool reads raw sectors and ISO 9660 itself) except for LANCER.CAB, an
# LZX-compressed Microsoft cabinet, which still goes through 7z.

##@ Game files

DISCS_DIR     := $(GAME_DIR)/discs
INSTALL_DIR   := $(GAME_DIR)/install
DECRYPTED_DIR := $(GAME_DIR)/decrypted

# The payload executable, recovered from the SafeDisc wrapper. See docs/binary/safedisc.md.
PAYLOAD := $(DECRYPTED_DIR)/LANCER.EXE

ASSETS_DIR := $(GAME_DIR)/assets

# The archives worth unpacking by default: resource.hog holds the models, sprites, images,
# missions and stat tables. The disc archives are mostly video and the speech archive is large.
HOG_ARCHIVES := install/resource.hog install/pilots/pilots.hog

.PHONY: game
game: $(GAME_DIR)/.stamp-install $(GAME_DIR)/.stamp-cd2 $(PAYLOAD) ## Unpack your disc images and recover the payload executable

.PHONY: assets
assets: $(addprefix $(GAME_DIR)/.stamp-hog-,$(notdir $(basename $(HOG_ARCHIVES)))) ## Extract the .HOG archives into game/assets

$(GAME_DIR)/.stamp-hog-%: | $(GAME_DIR)/.stamp-install $(SLTOOL)
	$(SLTOOL) hog extract $(firstword $(filter %/$*.hog,$(addprefix $(GAME_DIR)/,$(HOG_ARCHIVES)))) $(ASSETS_DIR)/$*
	touch $@

MODELS_DIR := $(GAME_DIR)/models

.PHONY: models
models: $(GAME_DIR)/.stamp-models ## Export every .SHP model to game/models as Wavefront OBJ

$(GAME_DIR)/.stamp-models: | $(GAME_DIR)/.stamp-hog-resource $(SLTOOL)
	mkdir -p $(MODELS_DIR)
	@count=0; for f in $(ASSETS_DIR)/resource/*.[sS][hH][pP]; do \
	    name=$$(basename "$$f"); \
	    $(SLTOOL) shp obj "$$f" "$(MODELS_DIR)/$${name%.*}.obj" > /dev/null; \
	    count=$$((count + 1)); \
	done; echo "exported $$count models to $(MODELS_DIR)"
	touch $@

SPRITES_DIR := $(GAME_DIR)/sprites

.PHONY: sprites
sprites: $(GAME_DIR)/.stamp-sprites ## Export every .SPR shape to game/sprites as PNG

$(GAME_DIR)/.stamp-sprites: | $(GAME_DIR)/.stamp-hog-resource $(SLTOOL)
	mkdir -p $(SPRITES_DIR)
	@for f in $(ASSETS_DIR)/resource/*.[sS][pP][rR]; do \
	    $(SLTOOL) spr extract "$$f" $(SPRITES_DIR) > /dev/null; \
	done; echo "exported $$(ls $(SPRITES_DIR) | wc -l | tr -d ' ') images to $(SPRITES_DIR)"
	touch $@

.PHONY: check-missions
check-missions: | $(GAME_DIR)/.stamp-hog-resource $(SLTOOL) ## Parse every .DTE mission
	@bad=0; for f in $(ASSETS_DIR)/resource/*.dte; do \
	    $(SLTOOL) dte info "$$f" > /dev/null || { echo "FAILED: $$f"; bad=$$((bad + 1)); }; \
	done; echo "$$(ls $(ASSETS_DIR)/resource/*.dte | wc -l | tr -d ' ') missions checked, $$bad with problems"

.PHONY: check-models
check-models: | $(GAME_DIR)/.stamp-hog-resource $(SLTOOL) ## Validate every .SHP model for internal consistency
	@bad=0; for f in $(ASSETS_DIR)/resource/*.[sS][hH][pP]; do \
	    $(SLTOOL) shp check "$$f" > /dev/null || { echo "FAILED: $$f"; bad=$$((bad + 1)); }; \
	done; echo "$$(ls $(ASSETS_DIR)/resource/*.[sS][hH][pP] | wc -l | tr -d ' ') models checked, $$bad with problems"

$(DISCS_DIR):
	mkdir -p $@

# Supply your own images of your own discs. A zip holding one is unpacked for convenience, and
# removed again once the disc has been extracted; an image you placed here yourself is left alone.
.INTERMEDIATE: $(DISCS_DIR)/disc1.bin $(DISCS_DIR)/disc2.bin
$(DISCS_DIR)/disc%.bin: | $(DISCS_DIR)
	@test -f $(DISCS_DIR)/disc$*.zip || { \
	    echo "missing $@"; \
	    echo "  Place your own image of disc $* here: a raw .bin (2352-byte sectors) or an .iso,"; \
	    echo "  or a .zip containing one, named disc$*.zip."; \
	    exit 1; }
	unzip -p $(DISCS_DIR)/disc$*.zip '*.bin' '*.iso' > $@

# sltool is order-only on purpose: rebuilding it must not re-extract the game, which would in
# turn make every later step look stale.
$(GAME_DIR)/.stamp-cd%: $(DISCS_DIR)/disc%.bin | $(SLTOOL)
	rm -rf $(GAME_DIR)/cd$*
	$(SLTOOL) cd extract $< $(GAME_DIR)/cd$*
	touch $@

$(GAME_DIR)/.stamp-install: $(GAME_DIR)/.stamp-cd1
	rm -rf $(INSTALL_DIR) $(INSTALL_DIR).tmp
	7z x -y -bd -o$(INSTALL_DIR).tmp $(GAME_DIR)/cd1/LANCER.CAB > /dev/null
	mv $(INSTALL_DIR).tmp/CAB $(INSTALL_DIR)
	rmdir $(INSTALL_DIR).tmp
	cp $(GAME_DIR)/cd1/GAME/CAB/* $(INSTALL_DIR)/
	touch $@

# Recovering the key is a 2^32 search, so the result is cached: pass KEY= to skip the search.
KEY ?=

$(PAYLOAD): $(INSTALL_DIR)/LANCER.ICD | $(SLTOOL)
	mkdir -p $(DECRYPTED_DIR)
	$(SLTOOL) safedisc decrypt $< $@ $(if $(KEY),--key $(KEY))

$(INSTALL_DIR)/LANCER.ICD: $(GAME_DIR)/.stamp-install
	@test -f $@
