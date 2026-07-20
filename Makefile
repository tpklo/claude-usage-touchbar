APP    := ClaudeTouchBar
BUNDLE := $(APP).app
BIN    := $(BUNDLE)/Contents/MacOS/$(APP)

# DFRFoundation is a private framework; the CLT SDK ships a .tbd stub, so it
# links directly with no dlsym dance.
FLAGS := -fobjc-arc -O2 -Wall \
         -framework Cocoa \
         -F/System/Library/PrivateFrameworks -framework DFRFoundation

.PHONY: all assets install-script run stop clean missing-assets

all: $(BIN)

# The script is the half that holds credentials, so the repo copy is the source
# of truth — edit here, then push it out rather than editing ~/bin in place.
install-script:
	@mkdir -p $(HOME)/bin
	@install -m 755 claude-touchbar.sh $(HOME)/bin/claude-touchbar.sh
	@echo "installed $(HOME)/bin/claude-touchbar.sh"

# Clawd's artwork is not redistributed — pull it onto this machine first.
assets:
	python3 tools/extract-assets.py

# A real bundle is required, not a bare binary: TouchBarServer keys Control Strip
# items off the caller's bundle identity, and a bare binary reports (null) — the
# item silently never appears.
$(BIN): main.m Info.plist $(wildcard frames/*.png)
	@test -f clawd_presets.h || $(MAKE) --no-print-directory missing-assets
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	clang $(FLAGS) -o $@ main.m
	rsync -a --delete frames/ $(BUNDLE)/Contents/Resources/frames/
	codesign --force --sign - $(BUNDLE)

# Kept as its own target so the message lives outside a shell one-liner —
# an apostrophe in "Anthropic's" broke the previous inline version.
missing-assets:
	@echo ""
	@echo "  Artwork is not bundled with this repository. It belongs to Anthropic,"
	@echo "  so the build fetches it onto your own machine instead:"
	@echo ""
	@echo "      make assets"
	@echo ""
	@exit 1

run: $(BIN) stop
	open $(BUNDLE)

stop:
	@pkill -x $(APP) 2>/dev/null || true

clean: stop
	rm -rf $(BUNDLE)
