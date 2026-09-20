# The game itself, all of it under game/ (git-ignored; none of it is ours to redistribute).
#
#   game/discs/disc<N>.bin   raw disc images: your own dumps, or `make fetch-game`
#   game/cd<N>/              the files on each disc
#   game/install/            what the installer would put on disk: LANCER.CAB unpacked, plus the
#                            loader and language DLLs it copies from the disc
#
# Extraction is pure Zig (sltool reads raw sectors and ISO 9660 itself) except for LANCER.CAB, an
# LZX-compressed Microsoft cabinet, which still goes through 7z.

##@ Game files

DISCS_DIR   := $(GAME_DIR)/discs
INSTALL_DIR := $(GAME_DIR)/install

# Redump-verified images of the US release, as hosted by the Internet Archive.
ARCHIVE_ORG := https://archive.org/download/StarLancerUSA
DISC_URL_1  := $(ARCHIVE_ORG)/Microsoft%20StarLancer%20%28USA%29%20%28Disc%201%29.zip
DISC_URL_2  := $(ARCHIVE_ORG)/Microsoft%20StarLancer%20%28USA%29%20%28Disc%202%29.zip
DISC_MD5_1  := 9da87ffd24e61c28ad9760055ca19706
DISC_MD5_2  := f966ba5a086464edf180b644ba73ccc5

DECRYPTED_DIR := $(GAME_DIR)/decrypted
# The payload executable, recovered from the SafeDisc wrapper. See docs/binary/safedisc.md.
PAYLOAD := $(DECRYPTED_DIR)/LANCER.EXE

.PHONY: game
game: $(GAME_DIR)/.stamp-install $(GAME_DIR)/.stamp-cd2 $(PAYLOAD) ## Unpack the disc images and recover the payload executable

.PHONY: fetch-game
fetch-game: $(DISCS_DIR)/disc1.zip $(DISCS_DIR)/disc2.zip ## Download both disc images from archive.org (1.3 GB)

$(DISCS_DIR):
	mkdir -p $@

$(DISCS_DIR)/disc%.zip: | $(DISCS_DIR)
	$(CURL) --continue-at - --output $@ "$(DISC_URL_$*)"
	scripts/verify-hash.sh md5 $(DISC_MD5_$*) $@

# No prerequisite on the zip: a disc image you supplied yourself must not trigger a download.
#
# Images unpacked from the zips are intermediate: make removes them again once the discs are
# extracted, which saves 1.4 GB, and recreates them in seconds if ever needed. Images that were
# already there when make started are yours and are left alone.
.INTERMEDIATE: $(DISCS_DIR)/disc1.bin $(DISCS_DIR)/disc2.bin
$(DISCS_DIR)/disc%.bin: | $(DISCS_DIR)
	@test -f $(DISCS_DIR)/disc$*.zip || { \
	    echo "missing $@"; \
	    echo "  put your own image of disc $* there (raw .bin or .iso), or run: make fetch-game"; \
	    exit 1; }
	unzip -p $(DISCS_DIR)/disc$*.zip '*.bin' > $@

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
