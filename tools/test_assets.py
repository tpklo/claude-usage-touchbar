#!/usr/bin/env python3
"""Offline, synthetic-only regression tests for asset extraction."""
import copy
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("assets", pathlib.Path(__file__).with_name("extract-assets.py"))
assets = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(assets)


def clip():
    grid = [[0] * 20 for _ in range(20)]
    grid[4][5] = 1
    return {"frames": [{"hold": 100, "grid": grid}], "palette": None}


class AssetsTest(unittest.TestCase):
    def test_valid_and_palette_shorthand(self):
        data = clip()
        data["palette"] = ["transparent", "#abc"]
        self.assertEqual(assets.validate_clip(data)[0][0][0], 100)

    def test_rejects_source_injection_and_invalid_values(self):
        for value in ["0}; system(\"bad\");", True, -1, 3, 256, 1.5, None]:
            data = clip()
            data["frames"][0]["grid"][0][0] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                assets.validate_clip(data)
        for value in [True, 0, -1, 60001, "100", float("nan"), float("inf"), 1.5]:
            data = clip()
            data["frames"][0]["hold"] = value
            with self.subTest(hold=value), self.assertRaises(ValueError):
                assets.validate_clip(data)

    def test_rejects_shape_empty_and_palette(self):
        values = [[], [[0] * 20] * 19, [[0] * 19] * 20, [[0] * 20] * 20]
        for grid in values:
            data = clip()
            data["frames"][0]["grid"] = grid
            with self.assertRaises(ValueError): assets.validate_clip(data)
        for palette in [[], ["transparent", "evil"], ["transparent"]]:
            data = clip(); data["palette"] = palette
            with self.assertRaises(ValueError): assets.validate_clip(data)
        data = clip(); data["frames"] *= assets.MAX_FRAMES + 1
        with self.assertRaises(ValueError): assets.validate_clip(data)

    def test_parser_has_only_explicit_data_operations(self):
        base = clip()["frames"][0]["grid"]
        env = {"BASE": base, "B": 1}
        result = assets.DataParser("patch(shift(BASE,1,0),[[0,0,B]])", env).value()
        self.assertEqual(result[0][0], 1)
        self.assertEqual(result[5][5], 1)
        for expression in ['require("fs")', 'eval("0")', 'process.exit()', '__import__("os")']:
            with self.subTest(expression=expression), self.assertRaises(ValueError):
                assets.DataParser(expression, {}).value()
        with self.assertRaises(ValueError):
            assets.DataParser("[" * 50 + "0" + "]" * 50, {}).value()

    def test_missing_dependency_is_not_executed(self):
        with self.assertRaises(ValueError):
            assets.read_constants('const FRAME = fetch("https://example.invalid");', {})
        with self.assertRaises((ValueError, IndexError)):
            assets.read_constants('const FRAME = [[1,2];', {})

    def test_digest_mismatch_and_size_limit(self):
        for payload in [b'not the pinned source', b'x' * (assets.MAX_SOURCE + 1)]:
            with mock.patch.object(assets.urllib.request, "urlopen", return_value=io.BytesIO(payload)):
                with self.assertRaises(ValueError): assets.fetch("creature-engine.js")

    def test_all_or_nothing_atomic_output(self):
        frames, pal = assets.validate_clip(clip())
        clips = [(name, frames, pal, 4, 4) for name in assets.PRESETS]
        with tempfile.TemporaryDirectory() as directory:
            header = pathlib.Path(directory) / "clawd_presets.h"
            header.write_text("previous complete header")
            with mock.patch.object(assets, "ROOT", directory), mock.patch.object(assets, "HEADER", str(header)):
                with self.assertRaises(ValueError): assets.write_header(clips[:-1])
                self.assertEqual(header.read_text(), "previous complete header")
                with mock.patch.object(assets.os, "replace", side_effect=OSError("write failed")):
                    with self.assertRaises(OSError): assets.write_header(clips)
                self.assertEqual(header.read_text(), "previous complete header")
                self.assertEqual(list(pathlib.Path(directory).iterdir()), [header])
                assets.write_header(clips)
                self.assertIn("kClawdClipCount = 13", header.read_text())
                self.assertEqual(list(pathlib.Path(directory).iterdir()), [header])


if __name__ == "__main__":
    unittest.main()
