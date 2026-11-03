#!/usr/bin/env python3
"""Fetch Clawd's pose data onto this machine.

The poses are not redistributed with this repository: claudepix.vercel.app
publishes no licence, and Clawd is Anthropic's character. This pulls them at
build time instead, and writes clawd_presets.h.

Usage
  make assets
"""

import ast
import hashlib
import json
import re
import os
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

# Remote JavaScript is NEVER executed. Only this small data expression language
# is accepted; helper names map to our own bounded grid operations below.
# Hashes also freeze helper semantics: upstream changes require source review.
MAX_SOURCE = 1024 * 1024
MAX_FRAMES = 512
TOKEN = re.compile(r"\s*(?:(//[^\n]*|/\*[\s\S]*?\*/)|(-?\d+)|([A-Za-z_$][\w$]*)|('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")|(\.\.\.|.))")


def grid_copy(grid):
    if (not isinstance(grid, list) or len(grid) != 20 or
            any(not isinstance(row, list) or len(row) != 20 for row in grid)):
        raise ValueError("grid must be 20x20")
    return [row[:] for row in grid]


def operation(name, args, env):
    if name in ("patch", "pt"):
        out = grid_copy(args[0])
        for r, c, v in args[1]:
            if type(r) is not int or type(c) is not int:
                raise ValueError("patch coordinates must be integers")
            if 0 <= r < 20 and 0 <= c < 20:
                out[r][c] = v
        return out
    if name in ("shift", "sh"):
        base = grid_copy(args[0])
        dr, dc = args[1:]
        if type(dr) is not int or type(dc) is not int:
            raise ValueError("shift offsets must be integers")
        return [[base[r-dr][c-dc] if 0 <= r-dr < 20 and 0 <= c-dc < 20
                 else 0 for c in range(20)] for r in range(20)]
    if name == "px":
        return operation("pt", [args[0], [[r, c, env["W"]] for r, c in args[1]]], env)
    if name == "headBob":
        base = args[0]
        out = grid_copy(base)
        values = [env[k] for k in ("HL", "HS", "B", "Y")]
        for r in range(1, 6):
            for c in range(20):
                if base[r][c] in values:
                    out[r][c] = env["E"]
        for r in range(1, 6):
            for c in range(20):
                if base[r][c] in values:
                    out[r+1][c] = base[r][c]
        return out
    if name == "bobUp":
        out = grid_copy(args[0])
        out[:9] = grid_copy(args[0])[1:10]
        out[9] = [env["E"]] * 20
        out[10:] = grid_copy(env["BASE"])[10:]
        return out
    if name == "pressKeys":
        out = grid_copy(args[0])
        for c in args[1]:
            if type(c) is not int or not 0 <= c < 20:
                raise ValueError("invalid key column")
            for r in (11, 12):
                if out[r][c] == env["K"]: out[r][c] = env["Y"]
                if out[r][c] == env["G"]: out[r][c] = env["T"]
        return out
    raise ValueError("unsupported helper: " + name)


class DataParser:
    def __init__(self, source, env):
        self.tokens = []
        for m in TOKEN.finditer(source):
            comment, number, ident, string, punct = m.groups()
            if not comment:
                self.tokens.append(number or ident or string or punct)
        self.i, self.env = 0, env

    def take(self, expected=None):
        token = self.tokens[self.i]
        self.i += 1
        if expected is not None and token != expected:
            raise ValueError("expected " + expected)
        return token

    def value(self, depth=0):
        if depth > 40: raise ValueError("expression too deep")
        token = self.take()
        if token in ("[", "{", "("):
            close = {"[": "]", "{": "}", "(": ")"}[token]
            result = {} if token == "{" else []
            while self.tokens[self.i] != close:
                if token == "{":
                    key = self.take()
                    if key.startswith(("'", '\"')): key = ast.literal_eval(key)
                    self.take(":")
                    result[key] = self.value(depth+1)
                elif self.tokens[self.i] == "...":
                    self.take()
                    result.extend(self.value(depth+1))
                else:
                    result.append(self.value(depth+1))
                if self.tokens[self.i] != close: self.take(",")
            self.take(close)
            return result
        if re.fullmatch(r"-?\d+", token): return int(token)
        if token.startswith(("'", '\"')): return ast.literal_eval(token)
        if token == "null": return None
        if self.i < len(self.tokens) and self.tokens[self.i] == "(":
            return operation(token, self.value(depth+1), self.env)
        if token not in self.env: raise ValueError("unknown identifier: " + token)
        return self.env[token]


def read_constants(source, env):
    # Only upper-case data declarations; ignore DOM, functions and all other JS.
    # A missing/unsupported dependency is fatal, never executed as a fallback.
    for match in re.finditer(r"\bconst\s+([A-Z][A-Za-z0-9_]*\s*=[\s\S]*?);", source):
        parser = DataParser(match.group(1), env)
        while parser.i < len(parser.tokens):
            name = parser.take()
            parser.take("=")
            # The DJ helper uses this derived value internally; our own bobUp
            # implementation reads BASE directly instead of parsing JS methods.
            if name == "TABLE_ROWS": break
            env[name] = parser.value()
            if parser.i < len(parser.tokens): parser.take(",")
    return env


def extract(engine, page):
    env = read_constants(engine, {})
    scripts = re.findall(r"<script>([\s\S]*?)</script>", page)
    env = read_constants("\n".join(scripts), env)
    frames = env["PRESET"]["frames"] if "PRESET" in env else env["FRAMES"]
    return {"palette": env.get("PAL"), "frames": [
        {"hold": f["hold"], "grid": env["CREATURE"] if f["frame"] is None else f["frame"]}
        for f in frames]}


def validate_clip(data):
    if not isinstance(data, dict): raise ValueError("clip must be an object")
    pal = data.get("palette")
    if pal is not None:
        if not isinstance(pal, list) or not 1 <= len(pal) <= 16:
            raise ValueError("palette must have 1-16 entries")
        for i, color in enumerate(pal):
            if i == 0 and color in (None, "transparent"): continue
            if not isinstance(color, str) or not re.fullmatch(r"#?(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})", color):
                raise ValueError("invalid palette color")
    frames = data.get("frames")
    if not isinstance(frames, list) or not 1 <= len(frames) <= MAX_FRAMES:
        raise ValueError("invalid frame count")
    result = []
    for frame in frames:
        if not isinstance(frame, dict): raise ValueError("invalid frame")
        hold = frame.get("hold")
        if type(hold) is not int or not 1 <= hold <= 60000:
            raise ValueError("hold must be an integer in 1-60000")
        grid = grid_copy(frame.get("grid"))
        limit = len(pal) if pal else 3
        if any(type(v) is not int or not 0 <= v < limit for row in grid for v in row):
            raise ValueError("invalid palette index")
        result.append((hold, grid))
    if not any(v for _, grid in result for row in grid for v in row):
        raise ValueError("clip is entirely empty")
    return result, pal


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def fetch(name):
    with open(os.path.join(ROOT, "tools", "assets-sha256.json"), encoding="utf-8") as manifest:
        pins = json.load(manifest)
    req = urllib.request.Request(f"{CLAUDEPIX}/animations/{name}",
                                 headers={"User-Agent": "claude-usage-touchbar/1.0"})
    with urllib.request.urlopen(req, timeout=25) as response:
        data = response.read(MAX_SOURCE + 1)
    if len(data) > MAX_SOURCE: raise ValueError("asset exceeds size limit")
    if hashlib.sha256(data).hexdigest() != pins[name]:
        raise ValueError(f"{name}: SHA-256 mismatch; review upstream changes before updating pins")
    return data.decode("utf-8")


def main():
    print("Fetching pinned pose data (no JavaScript execution)...")
    clips = []
    try:
        engine = fetch("creature-engine.js")
        for name in PRESETS:
            frames, pal = validate_clip(extract(engine, fetch(name + ".html")))
            rows = [r for _, grid in frames for r in range(20) if any(grid[r])]
            clips.append((name, frames, pal, min(rows), max(rows)))
            print(f"  {name:22} {len(frames):3d} frames")
        if [clip[0] for clip in clips] != PRESETS:
            raise ValueError("incomplete clip set")
        write_header(clips)
    except (OSError, ValueError, KeyError, IndexError, TypeError, RecursionError, SyntaxError) as exc:
        die(f"{exc}; existing header left unchanged")
    print(f"  clawd_presets.h    {len(clips)} clips")
    print("\nDone. Now run: make run")


def write_header(clips):
    if [clip[0] for clip in clips] != PRESETS:
        raise ValueError("refusing partial or reordered clip set")
    # Same-directory temporary file and atomic rename preserve the previous
    # complete header on download, validation or write failure.
    tmp = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=ROOT,
                                         prefix=".clawd-presets-", delete=False) as fh:
            tmp = fh.name
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
                    if len(c) == 3: c = "".join(ch * 2 for ch in c)
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

        os.replace(tmp, HEADER)
        tmp = None
    finally:
        if tmp is not None:
            os.unlink(tmp)


if __name__ == "__main__":
    main()

