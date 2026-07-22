#!/usr/bin/env python3
"""Fetch Clawd's pose data onto this machine.

The poses are not redistributed with this repository: claudepix.vercel.app
publishes no licence, and Clawd is Anthropic's character. This pulls them at
build time instead, and writes clawd_presets.h.

Usage
  make assets
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEADER = os.path.join(ROOT, "clawd_presets.h")
CLAUDEPIX = "https://claudepix.vercel.app"

# Discovered from app.js's MANIFEST. Order matters: main.m indexes into this
# array by number (see ClipForMood), so appending is safe but reordering is not.
PRESETS = [
    "idle_breathe", "idle_blink", "idle_look_around",
    "expression_wink", "expression_surprise", "expression_sleep",
    "dance_bounce", "dance_sway", "work_think",
    # Appended 2026-07-22 — the remaining four on claudepix. New entries go on
    # the end for the reason above: main.m addresses these by index.
    "work_coding", "dance_bounce_dj", "dance_sway_dj", "dance_djmix",
]

# Each preset page builds its frames by calling the engine's patch()/shift()
# helpers on a shared base grid, and half the frames are `null` meaning "the
# base pose". Re-implementing that in Python would be guesswork, so run the
# real code in Node against a minimal DOM stub and read the result back.
EVAL_JS = r"""
const engine = process.argv[2], page = process.argv[3];
const el = () => new Proxy({style:{}, appendChild(){}, set innerHTML(v){}},
                           {get:(t,k)=> k in t ? t[k] : el()});
globalThis.window = globalThis;
globalThis.document = { createElement: el, getElementById: el };
globalThis.performance = { now: () => 0 };
globalThis.requestAnimationFrame = () => 0;
globalThis.cancelAnimationFrame = () => {};
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};

(0, eval)(require('fs').readFileSync(engine, 'utf8'));

const html = require('fs').readFileSync(page, 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
(0, eval)(scripts.join('\n'));

// Two page formats exist. The older ones export window.PRESET and lean on the
// shared PixelEngine (values are 0/1/2 — empty, body, eye). The newer ones are
// standalone: window.FRAMES plus their own window.PAL of up to ten colours, for
// scenes with props like a laptop or desk.
const P = globalThis.PRESET;
if (P) {
  const base = globalThis.PixelEngine.CREATURE;
  process.stdout.write(JSON.stringify({
    palette: null,
    frames: P.frames.map(f => ({ hold: f.hold, grid: f.frame || base })),
  }));
} else if (globalThis.FRAMES) {
  process.stdout.write(JSON.stringify({
    palette: globalThis.PAL || null,
    frames: globalThis.FRAMES.map(f => ({ hold: f.hold, grid: f.frame })),
  }));
} else {
  console.error('neither PRESET nor FRAMES'); process.exit(1);
}
"""


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "claude-usage-touchbar/1.0"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read().decode("utf-8", "replace")


def main():
    node = shutil.which("node")
    if not node:
        die("node is needed to evaluate the pose data — brew install node\n"
            "       (build-time only; the widget itself does not use it)")

    print("Fetching pose grids from claudepix.vercel.app...")
    with tempfile.TemporaryDirectory() as tmp:
        ev = os.path.join(tmp, "ev.js")
        with open(ev, "w") as f:
            f.write(EVAL_JS)
        eng = os.path.join(tmp, "engine.js")
        with open(eng, "w") as f:
            f.write(fetch(f"{CLAUDEPIX}/animations/creature-engine.js"))

        clips = []
        for name in PRESETS:
            page = os.path.join(tmp, f"{name}.html")
            try:
                with open(page, "w") as f:
                    f.write(fetch(f"{CLAUDEPIX}/animations/{name}.html"))
                r = subprocess.run([node, ev, eng, page], capture_output=True, text=True)
                if r.returncode != 0:
                    print(f"  ! {name}: {r.stderr.strip()[:80]}")
                    continue
                data = json.loads(r.stdout)
            except Exception as e:
                print(f"  ! {name}: {e}")
                continue

            frames = [(fr["hold"], fr["grid"]) for fr in data["frames"]
                      if len(fr["grid"]) == 20 and all(len(row) == 20 for row in fr["grid"])]
            if not frames:
                print(f"  ! {name}: no usable frames (page format may have changed)")
                continue
            # Vertical extent across every frame of the clip. The creature-only
            # poses occupy rows 4-16; the prop scenes reach 0-18, and drawing
            # them at the creature's row window silently cropped desks and
            # headphones. Each clip carries its own window instead.
            rows = [r for _, g in frames for r in range(20) if any(g[r])]
            clips.append((name, frames, data.get("palette"), min(rows), max(rows)))
            print(f"  {name:22} {len(frames):3d} frames")

    if not clips:
        die("no poses could be extracted")

    with open(HEADER, "w") as fh:
        fh.write("// Generated by tools/extract-assets.py — do not edit.\n")
        fh.write("// Pose data from https://claudepix.vercel.app (Clawd is Anthropic's).\n")
        fh.write("#pragma once\n#define CLAWD_N 20\n\n")
        fh.write("typedef struct { int hold; unsigned char grid[CLAWD_N*CLAWD_N]; } ClawdFrame;\n")
        fh.write("typedef struct { const char *name; int count; const ClawdFrame *frames;\n"
                 "                 const unsigned char (*pal)[3]; int palCount;\n"
                 "                 int top, bot; } ClawdClip;\n\n")
        for name, frames, pal, top, bot in clips:
            fh.write(f"static const ClawdFrame kF_{name}[] = {{\n")
            for hold, rows in frames:
                flat = ",".join(str(v) for r in rows for v in r)
                fh.write(f"  {{{hold}, {{{flat}}}}},\n")
            fh.write("};\n")
        # Palettes: index 0 is transparent, the rest are drawn literally. A clip
        # with no palette of its own uses the caller's body colour, so its mood
        # tinting still works.
        for name, frames, pal, top, bot in clips:
            if not pal:
                continue
            rgb = []
            for c in pal[:16]:
                c = (c or "").lstrip("#")
                rgb.append(tuple(int(c[i:i+2], 16) for i in (0, 2, 4)) if len(c) == 6 else (0, 0, 0))
            body = ",".join("{%d,%d,%d}" % v for v in rgb)
            fh.write(f"static const unsigned char kPal_{name}[][3] = {{{body}}};\n")

        fh.write("\nstatic const ClawdClip kClawdClips[] = {\n")
        for name, frames, pal, top, bot in clips:
            p = f"(const unsigned char (*)[3])kPal_{name}" if pal else "0"
            n = len(pal[:16]) if pal else 0
            fh.write(f'  {{"{name}", {len(frames)}, kF_{name}, {p}, {n}, {top}, {bot}}},\n')
        fh.write("};\n")
        fh.write(f"static const int kClawdClipCount = {len(clips)};\n")

    print(f"  clawd_presets.h    {len(clips)} clips")
    print("\nDone. Now run: make run")


if __name__ == "__main__":
    main()
