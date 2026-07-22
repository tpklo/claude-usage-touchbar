APP    := ClaudeTouchBar
BUNDLE := $(APP).app
BIN    := $(BUNDLE)/Contents/MacOS/$(APP)

# DFRFoundation is a private framework; the CLT SDK ships a .tbd stub, so it
# links directly with no dlsym dance.
FLAGS := -fobjc-arc -O2 -Wall \
         -framework Cocoa \
         -F/System/Library/PrivateFrameworks -framework DFRFoundation

AGENT := local.claude-touchbar
PLIST := $(HOME)/Library/LaunchAgents/$(AGENT).plist

.PHONY: all assets test shots poses palette ruler sweat film film-drag install-script install-agent uninstall-agent run stop clean missing-assets

all: $(BIN)

# The script is the half that holds credentials, so the repo copy is the source
# of truth — edit here, then push it out rather than editing ~/bin in place.
install-script:
	@mkdir -p $(HOME)/bin
	@install -m 755 claude-touchbar.sh $(HOME)/bin/claude-touchbar.sh
	@echo "installed $(HOME)/bin/claude-touchbar.sh"

# Clawd's pose data is not redistributed — pull it onto this machine first.
assets:
	python3 tools/extract-assets.py

# A real bundle is required, not a bare binary: TouchBarServer keys Control Strip
# items off the caller's bundle identity, and a bare binary reports (null) — the
# item silently never appears.
$(BIN): main.m clawd_presets.h Info.plist
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	clang $(FLAGS) -o $@ main.m
	codesign --force --sign - $(BUNDLE)

# Not a rule that builds it — just a readable failure when it is absent.
clawd_presets.h:
	@$(MAKE) --no-print-directory missing-assets

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

# No network, no keychain, no artwork needed — this is what CI runs.
test:
	@./tools/test.sh

# The Touch Bar cannot be screenshotted, so this renders the readout at a spread
# of states to PNGs instead. The only way to actually look at a layout change.
shots: $(BIN)
	@./$(BIN) --render /tmp/claude-touchbar-shots
	@open /tmp/claude-touchbar-shots

# Start at login. An ad-hoc signature does not survive the bundle being copied,
# so the agent points at the build directory rather than moving the app.
install-agent: $(BIN)
	@mkdir -p $(HOME)/Library/LaunchAgents
	@sed 's|__APP__|$(CURDIR)/$(BUNDLE)|' $(AGENT).plist > $(PLIST)
	@launchctl bootout gui/$(shell id -u)/$(AGENT) 2>/dev/null || true
	@# bootout returns before the job is fully gone, and bootstrapping over a
	@# job still scheduled to respawn fails with EIO. Wait for it to clear.
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
	   launchctl print gui/$(shell id -u)/$(AGENT) >/dev/null 2>&1 || break; \
	   sleep 0.5; \
	 done
	@# Re-sign immediately before loading: `make` re-signs on every build, and a
	@# running launchd job holding the old signature makes the next spawn die
	@# with OS_REASON_CODESIGNING.
	@codesign --force --sign - $(BUNDLE) 2>/dev/null
	@launchctl bootstrap gui/$(shell id -u) $(PLIST)
	@echo "loaded $(AGENT) — starts at login, restarts if it dies"

uninstall-agent:
	@launchctl bootout gui/$(shell id -u)/$(AGENT) 2>/dev/null || true
	@rm -f $(PLIST)
	@echo "removed $(AGENT)"

# Candidate colours side by side on the actual Touch Bar. A colour has to be
# judged on the panel it will live on — this one is dim and viewed at a glance,
# so what reads well in a terminal or a PNG often does not survive here.
palette: $(BIN) stop
	@echo "Ctrl-C to stop, then: make install-agent"
	@./$(BIN) --palette

# Dev tools for checking work that cannot be screenshotted.
#   shots   readout across eight data states -> PNG
#   poses   every animation clip mid-frame -> PNG
#   palette candidate colours side by side, on the bar itself
#   ruler   fixed ticks, to read the usable width off the bar
poses: $(BIN)
	@./$(BIN) --poses /tmp/claude-touchbar-poses
	@open /tmp/claude-touchbar-poses

ruler: $(BIN)
	@echo "Ctrl-C to exit"; ./$(BIN) --ruler

sweat: $(BIN)
	@echo "Ctrl-C to exit"; ./$(BIN) --sweat

# Record the widget without filming a screen: runs the real animation loop
# headless and writes one PNG per frame. film-drag scripts a grab-drag-throw so
# the touch reaction can be recorded too — it applies the same wall the touch
# handler does, after an earlier version moved him straight over the readout.
FILM_DIR := /tmp/claude-touchbar-film
film: $(BIN)
	@rm -rf $(FILM_DIR) && ./$(BIN) --film $(FILM_DIR) 20
	@command -v ffmpeg >/dev/null && cd $(FILM_DIR) && \
	  ffmpeg -y -loglevel error -framerate 15 -i f%04d.png \
	    -vf "scale=iw*2:ih*2:flags=neighbor,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=none" \
	    -loop 0 clawd.gif && echo "$(FILM_DIR)/clawd.gif" || echo "frames in $(FILM_DIR) (brew install ffmpeg for a gif)"

film-drag: $(BIN)
	@rm -rf $(FILM_DIR)-drag && ./$(BIN) --film-drag $(FILM_DIR)-drag
	@command -v ffmpeg >/dev/null && cd $(FILM_DIR)-drag && \
	  ffmpeg -y -loglevel error -framerate 15 -i f%04d.png \
	    -vf "scale=iw*2:ih*2:flags=neighbor,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=none" \
	    -loop 0 drag.gif && echo "$(FILM_DIR)-drag/drag.gif" || echo "frames in $(FILM_DIR)-drag"

run: $(BIN) stop
	open $(BUNDLE)

stop:
	@pkill -x $(APP) 2>/dev/null || true

clean: stop
	rm -rf $(BUNDLE)
