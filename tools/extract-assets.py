#!/usr/bin/env python3
"""Extract Clawd's sprite data and animation frames onto this machine.

Nothing under frames/ or clawd_presets.h ships with this repository. The
artwork belongs to Anthropic and the pose data has no public licence, so the
build pulls both from sources already present on (or reachable by) your own
machine and keeps them local.

Sources
  frames/mag_*.png   Claude.app  → clawd-magnifier.gif  (green screen)
  frames/lap_*.png   Claude.app  → clawd-laptop.mov     (white background)
  clawd_presets.h    claudepix.vercel.app/animations/   (20x20 pose grids)

Usage
  make assets              # both
  python3 tools/extract-assets.py --frames
  python3 tools/extract-assets.py --presets
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMES = os.path.join(ROOT, "frames")
HEADER = os.path.join(ROOT, "clawd_presets.h")

CLAUDE_APP = "/Applications/Claude.app/Contents/Resources/ion-dist/images/install-hub"
CLAUDEPIX = "https://claudepix.vercel.app"

# Discovered from app.js's MANIFEST. Order matters: main.m indexes into this
# array by number (see ClipForMood), so appending is safe but reordering is not.
PRESETS = [
    "idle_breathe", "idle_blink", "idle_look_around",
    "expression_wink", "expression_surprise", "expression_sleep",
    "dance_bounce", "dance_sway", "work_think",
]

TARGET_H = 26          # points tall in a 30pt Touch Bar


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def need_pillow():
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        die("Pillow is required:  python3 -m pip install --user Pillow")


def key_and_crop(images, is_bg):
    """Cut the background out of every frame, then crop them all to one shared
    box so the sprite does not jitter between frames."""
    from PIL import Image

    keyed = []
    for im in images:
        rgba = im.convert("RGBA")
        px = rgba.load()
        w, h = rgba.size
        for y in range(h):
            for x in range(w):
                if is_bg(px[x, y]):
                    px[x, y] = (0, 0, 0, 0)
        keyed.append(rgba)

    box = None
    for k in keyed[::4] or keyed:          # every 4th frame is enough
        bb = k.getbbox()
        if not bb:
            continue
        box = bb if box is None else (min(box[0], bb[0]), min(box[1], bb[1]),
                                      max(box[2], bb[2]), max(box[3], bb[3]))
    if box is None:
        die("nothing left after keying — the source art may have changed")

    scale = TARGET_H / (box[3] - box[1])
    size = (round((box[2] - box[0]) * scale), TARGET_H)
    # NEAREST keeps the pixel edges hard; anything else turns the art to mush.
    return [k.crop(box).resize(size, Image.NEAREST) for k in keyed]


def extract_frames():
    need_pillow()
    from PIL import Image

    gif = os.path.join(CLAUDE_APP, "clawd-magnifier.gif")
    mov = os.path.join(CLAUDE_APP, "clawd-laptop.mov")
    if not os.path.exists(gif):
        die(f"not found: {gif}\n       Install Claude Desktop from https://claude.ai/download")

    os.makedirs(FRAMES, exist_ok=True)
    for old in os.listdir(FRAMES):
        if old.endswith(".png"):
            os.remove(os.path.join(FRAMES, old))

    # --- magnifier: chroma key ---
    im = Image.open(gif)
    src = []
    for i in range(im.n_frames):
        im.seek(i)
        src.append(im.copy())
    out = key_and_crop(src, lambda p: p[1] > 180 and p[0] < 120 and p[2] < 120)
    for i, f in enumerate(out):
        f.save(os.path.join(FRAMES, f"mag_{i:03d}.png"))
    print(f"  frames/mag_*.png   {len(out)} frames  {out[0].size[0]}x{out[0].size[1]}")

    # --- laptop: white background, needs ffmpeg to decode ---
    if not os.path.exists(mov):
        print("  (clawd-laptop.mov missing — skipping the laptop clip)")
        return
    if not shutil.which("ffmpeg"):
        print("  (ffmpeg not installed — skipping the laptop clip: brew install ffmpeg)")
        return

    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-i", mov,
                        os.path.join(tmp, "f_%03d.png")], check=True)
        files = sorted(f for f in os.listdir(tmp) if f.endswith(".png"))
        src = [Image.open(os.path.join(tmp, f)).copy() for f in files]
        out = key_and_crop(src, lambda p: p[0] > 235 and p[1] > 235 and p[2] > 235)
        for i, f in enumerate(out):
            f.save(os.path.join(FRAMES, f"lap_{i:03d}.png"))
        print(f"  frames/lap_*.png   {len(out)} frames  {out[0].size[0]}x{out[0].size[1]}")


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "claude-usage-touchbar/1.0"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read().decode("utf-8", "replace")


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
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.cancelAnimationFrame = () => {};

(0, eval)(require('fs').readFileSync(engine, 'utf8'));

const html = require('fs').readFileSync(page, 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
(0, eval)(scripts.join('\n'));

const P = globalThis.PRESET;
if (!P) { console.error('no PRESET'); process.exit(1); }
const base = globalThis.PixelEngine.CREATURE;
process.stdout.write(JSON.stringify({
  name: P.name,
  frames: P.frames.map(f => ({ hold: f.hold, grid: f.frame || base })),
}));
"""


def extract_presets():
    """Run each preset page in Node so the engine resolves its own frames."""
    node = shutil.which("node")
    if not node:
        die("node is required to evaluate the pose data (brew install node)")

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
            holds = [h for h, _ in frames]
            clips.append((name, holds, [g for _, g in frames]))
            print(f"  {name:22} {len(frames):3d} frames")

    if not clips:
        die("no presets could be extracted")

    with open(HEADER, "w") as fh:
        fh.write("// Generated by tools/extract-assets.py — do not edit.\n")
        fh.write("// Pose data from https://claudepix.vercel.app (Clawd is Anthropic's).\n")
        fh.write("#pragma once\n#define CLAWD_N 20\n\n")
        fh.write("typedef struct { int hold; unsigned char grid[CLAWD_N*CLAWD_N]; } ClawdFrame;\n")
        fh.write("typedef struct { const char *name; int count; const ClawdFrame *frames; } ClawdClip;\n\n")
        for name, holds, frames in clips:
            fh.write(f"static const ClawdFrame kF_{name}[] = {{\n")
            for i, rows in enumerate(frames):
                hold = holds[i] if i < len(holds) else 120
                flat = ",".join(str(v) for r in rows for v in r)
                fh.write(f"  {{{hold}, {{{flat}}}}},\n")
            fh.write("};\n")
        fh.write("\nstatic const ClawdClip kClawdClips[] = {\n")
        for name, _, frames in clips:
            fh.write(f'  {{"{name}", {len(frames)}, kF_{name}}},\n')
        fh.write("};\n")
        fh.write(f"static const int kClawdClipCount = {len(clips)};\n")
    print(f"  clawd_presets.h    {len(clips)} clips")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", action="store_true", help="extract animation frames from Claude.app")
    ap.add_argument("--presets", action="store_true", help="fetch pose grids from claudepix")
    a = ap.parse_args()
    both = not (a.frames or a.presets)

    if a.frames or both:
        print("Extracting animation frames from Claude.app...")
        extract_frames()
    if a.presets or both:
        print("Fetching pose grids from claudepix.vercel.app...")
        extract_presets()
    print("\nDone. Now run: make run")
