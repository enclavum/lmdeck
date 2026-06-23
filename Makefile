# LMDeck — build / run / release a SwiftUI menu-bar app. Common tasks:
#
#   Develop:     make run             build + ad-hoc sign + launch ./LMDeck.app
#                make run-settings    …with the Settings window open
#                make test            Swift unit tests (also run on every build)
#                make integration-test  pytest against a running instance (see integration/)
#   Signed test: make run-signed      build + Developer ID sign + launch — exercises the signed-only
#                                      paths (data-protection Keychain, hardened runtime)
#   Ship:        make release         signed + notarized + stapled LMDeck.dmg (the full artifact)
#                make dmg | notarize | verify   the individual release steps
#   Clean:       make clean
#
# `make` / `make run` use ad-hoc signing (`--sign -`): local-only, no Apple ID/cert, so anyone can
# build from source. The release targets need a Developer ID cert + .signing.mk + LMDeck.provisionprofile
# — see README → Development for the one-time setup.

CONFIG    := release
EXE       := LMDeck
APP       := $(EXE).app
BUILD_BIN := .build/$(CONFIG)/$(EXE)
CONTENTS  := $(APP)/Contents

# Developer ID release config. The signing identity lives in .signing.mk (gitignored, so the
# author's name stays out of the public repo) — see README → Development for the format.
-include .signing.mk
DEV_ID         ?=
NOTARY_PROFILE ?= lmdeck-notary
ENTITLEMENTS   := Resources/LMDeck.entitlements
PROFILE        := LMDeck.provisionprofile
DMG            := $(EXE).dmg
DMG_STAGE      := .dmg-stage

.PHONY: all test integration-test build bundle sign run run-settings run-signed sign-release dmg notarize verify release clean

# Default: build + ad-hoc sign → ./LMDeck.app
all: build sign

# ─── Tests ────────────────────────────────────────────────────────────────────

# Swift unit tests — pure functions only (parsing, aggregation, auth, host/port normalization).
# Command Line Tools lack XCTest/Testing, so point at full Xcode's toolchain when needed.
test:
	@dev=$$(xcode-select -p 2>/dev/null); \
		case "$$dev" in *Xcode*) ;; *) dev=$$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer ;; esac; \
		if echo "$$dev" | grep -q Xcode; then \
			DEVELOPER_DIR="$$dev" swift test; \
		else \
			echo "Swift unit tests need full Xcode (Command Line Tools lack XCTest/Testing)."; \
			echo "Install Xcode, or run: sudo xcode-select -s /Applications/Xcode.app"; exit 1; \
		fi

# Python integration tests against a *running* LMDeck (see integration/README.md). Local secrets/
# config live in integration/.env (gitignored). Pass extra args via ARGS=.
integration-test:
	@cd integration && \
		( [ -d .venv ] || python3 -m venv .venv ) && \
		./.venv/bin/pip install -q -r requirements.txt && \
		( set -a; [ -f .env ] && . ./.env; set +a; ./.venv/bin/python -m pytest $(ARGS) )

# ─── Build pipeline ───────────────────────────────────────────────────────────

# Compile (release). Unit tests run first, as part of every build.
build: test
	swift build -c $(CONFIG)

# Assemble LMDeck.app from the compiled binary + Info.plist + icon. An intermediate step that
# sign / run / dmg depend on — you rarely run it directly.
bundle:
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BUILD_BIN) $(CONTENTS)/MacOS/$(EXE)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	@echo "bundled $(APP)"

# Ad-hoc code signature — local-only, no Apple ID/cert (the dev default; with no Keychain entitlement
# the app uses the plaintext-UserDefaults secret backend).
sign: bundle
	codesign --force --sign - $(APP)
	@echo "ad-hoc signed $(APP)"

# ─── Run (local dev) ──────────────────────────────────────────────────────────

# Relaunch. Compile FIRST (swift build only touches .build, not the running app), then kill the old
# instance, and only THEN bundle + sign. Overwriting/re-signing a running app bundle invalidates its
# in-memory code signature and kills its server thread (app stays up, server dies) — so bundle+sign
# must happen after the old process is gone.
run: build
	@pkill -TERM -x $(EXE) 2>/dev/null && echo "stopping $(EXE)…" || true
	@sleep 1
	@pkill -9 -x $(EXE) 2>/dev/null || true   # force-kill only if it didn't exit gracefully
	@$(MAKE) --no-print-directory sign
	open $(APP)

# Same as `run`, but opens the Settings window on launch (passes --settings to the app).
run-settings: build
	@pkill -TERM -x $(EXE) 2>/dev/null && echo "stopping $(EXE)…" || true
	@sleep 1
	@pkill -9 -x $(EXE) 2>/dev/null || true
	@$(MAKE) --no-print-directory sign
	open $(APP) --args --settings

# Like run-settings, but Developer-ID-signed — the loop for testing signed-only behavior (the
# data-protection Keychain, hardened runtime). Notarization isn't needed to launch locally.
run-signed: build
	@pkill -TERM -x $(EXE) 2>/dev/null && echo "stopping $(EXE)…" || true
	@sleep 1
	@pkill -9 -x $(EXE) 2>/dev/null || true
	@$(MAKE) --no-print-directory sign-release
	open $(APP) --args --settings

# ─── Release (Developer ID → notarized .dmg) ──────────────────────────────────

# Developer ID signing: hardened runtime (--options runtime) + the data-protection-Keychain
# entitlement + a secure timestamp. keychain-access-groups is *restricted*, so it's authorized by the
# embedded Developer ID provisioning profile ($(PROFILE) → Contents/embedded.provisionprofile);
# without it the app fails to launch ("Launchd job spawn failed"). Needs DEV_ID + the profile.
sign-release: bundle
	@[ -n "$(DEV_ID)" ] || { echo "DEV_ID not set — create .signing.mk with 'DEV_ID := Developer ID Application: …' (see README -> Development)."; exit 1; }
	@[ -f "$(PROFILE)" ] || { echo "$(PROFILE) not found — download the Developer ID provisioning profile and save it as ./$(PROFILE)."; exit 1; }
	cp "$(PROFILE)" "$(CONTENTS)/embedded.provisionprofile"
	codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) --sign "$(DEV_ID)" $(APP)
	@echo "Developer ID signed $(APP) (provisioning profile + Keychain entitlement)"

# Package the Developer-ID-signed app into a compressed .dmg with a drag-to-Applications symlink,
# then sign the dmg too.
dmg: build
	@$(MAKE) --no-print-directory sign-release
	rm -rf $(DMG_STAGE) $(DMG)
	mkdir -p $(DMG_STAGE)
	cp -R $(APP) $(DMG_STAGE)/
	ln -s /Applications $(DMG_STAGE)/Applications
	hdiutil create -volname "$(EXE)" -srcfolder $(DMG_STAGE) -ov -format UDZO $(DMG)
	rm -rf $(DMG_STAGE)
	codesign --force --timestamp --sign "$(DEV_ID)" $(DMG)
	@echo "built $(DMG)"

# Submit the dmg to Apple's notary service (waits for the verdict), then staple the ticket so the
# download validates offline. Credentials come from the keychain (NOTARY_PROFILE).
notarize: dmg
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	@echo "notarized + stapled $(DMG)"

# Inspect the app's signature, embedded entitlements, and Gatekeeper verdict.
verify:
	codesign -dv --verbose=4 $(APP)
	@echo "--- entitlements ---"
	codesign --display --entitlements - $(APP)
	@echo "--- Gatekeeper ---"
	spctl -a -t exec -vvv $(APP) || true

# The full shippable artifact: signed + notarized + stapled dmg, then verify.
release: notarize verify
	@echo "release ready: $(DMG)"

# ─── Housekeeping ─────────────────────────────────────────────────────────────

clean:
	rm -rf .build $(APP) $(DMG) $(DMG_STAGE)
	@echo "cleaned"
