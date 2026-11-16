# Cado — local Whisper speech-to-text for macOS
#
# Single entry point for building and installing the app.
#   make setup     one-shot: fetch whisper.cpp, embed shader, download model, build, package
#   make run       build and run from the source tree (dev)
#   make build     just compile (release)
#   make package   assemble dist/Cado.app
#   make install   build, package, and copy to /Applications
#   make model     download the model the app auto-picks for this Mac
#                  (or a specific one: make model MODEL=small.en-q5_1)
#   make vad-model download the Silero VAD model (bench --vad, #7)
#   make parakeet-model  download the Parakeet engine's model folder (#13)
#                  (or a specific one: make parakeet-model PARAKEET=<id>)
#   make whisperkit-model  download a WhisperKit (Core ML) model folder (#12)
#                  (or a specific one: make whisperkit-model WHISPERKIT=tiny.en)
#   make brand     regenerate the checked-in brand assets from plans/mascot/*.svg:
#                  the embedded mascot art (Sources/Cado/Brand/MascotArt+SVG.swift)
#                  and Resources/AppIcon.icns (needs rsvg-convert: brew install librsvg)
#   make acknowledgements  regenerate the checked-in Acknowledgements screen text
#                  (Sources/Cado/Acknowledgements/Acknowledgements+Text.swift)
#                  from ACKNOWLEDGEMENTS.md and LICENSE
#   make release VERSION=x.y.z  Developer ID-signed, notarized, stapled dist/Cado-x.y.z.dmg
#                  + signed Sparkle feed dist/appcast.xml; prints the gh upload
#                  (docs/RELEASING.md; SKIP_NOTARIZE=1 for a local rehearsal)
#   make clean    remove build artifacts

APP   := Cado
# Empty = the model the app auto-picks for this Mac (scripts/model_catalog.sh).
MODEL ?=
# Empty = scripts/download_parakeet_model.sh's default (the app's Parakeet model).
PARAKEET ?=
# Empty = scripts/download_whisperkit_model.sh's default (the app's English Automatic pick).
WHISPERKIT ?=

.PHONY: setup embed brand acknowledgements model vad-model parakeet-model whisperkit-model build run package install release clean

# `make setup` auto-detects the model from this Mac's arch + RAM. Pass MODEL= to
# override, e.g. `make setup MODEL=small.en-q5_1` — only a command-line MODEL is
# forwarded, so the plain `make setup` reaches setup.sh with no arg (auto-pick).
setup:
ifeq ($(origin MODEL),command line)
	bash scripts/setup.sh $(MODEL)
else
	bash scripts/setup.sh
endif

# Generate the embedded Metal-shader artifacts (idempotent). Required before any
# swift build, so build/run depend on it. No-op on Intel (CPU-only build).
embed:
	bash scripts/embed_metal_shader.sh

# Brand assets are generated from the mascot SVGs and CHECKED IN (not a build
# step), so a plain build needs no rsvg-convert. Re-run after editing the art;
# BrandTests fails while the embedded art is stale.
brand:
	bash scripts/embed_mascot_art.sh
	python3 scripts/make_app_icon.py

# The Acknowledgements screen's text, likewise generated and CHECKED IN.
# Re-run after editing ACKNOWLEDGEMENTS.md or LICENSE; AcknowledgementsTests
# fails while the embedded copy is stale.
acknowledgements:
	bash scripts/embed_acknowledgements.sh

model:
	bash scripts/download_model.sh $(MODEL)

vad-model:
	bash scripts/download_vad_model.sh

parakeet-model:
	bash scripts/download_parakeet_model.sh $(PARAKEET)

whisperkit-model:
	bash scripts/download_whisperkit_model.sh $(WHISPERKIT)

build: embed
	swift build -c release

run: embed
	swift run -c release

# package_app.sh embeds + builds + assembles, so no extra build dependency here.
package:
	bash scripts/package_app.sh

install:
	bash scripts/package_app.sh --install

# VERSION is required; credentials come from the environment (docs/RELEASING.md).
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z" >&2; exit 2; }
	bash scripts/release.sh "$(VERSION)"

clean:
	swift package clean || true
	rm -rf dist
