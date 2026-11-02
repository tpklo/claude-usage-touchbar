#!/usr/bin/env python3
"""Offline regression checks for the native safety guards (not an AppKit build)."""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "main.m").read_text()


class NativeGuards(unittest.TestCase):
    def test_activity_allows_idle_sleep(self):
        self.assertIn("beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep", SOURCE)
        self.assertNotRegex(SOURCE, r"beginActivityWithOptions:NSActivityUserInitiated\s")

    @unittest.skipUnless(shutil.which("cc"), "C compiler unavailable")
    def test_partial_clip_header_fails_compilation(self):
        guard = re.search(r"_Static_assert\(sizeof\(kClawdClips\).*?\);", SOURCE, re.S)
        self.assertIsNotNone(guard)
        with tempfile.TemporaryDirectory() as directory:
            for count in (1, 12, 13):
                path = pathlib.Path(directory) / "guard.c"
                path.write_text("static const int kClawdClips[%d] = {0};\n" % count + guard[0])
                result = subprocess.run(["cc", "-std=c11", "-fsyntax-only", str(path)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, count == 13, result.stderr)


if __name__ == "__main__":
    unittest.main()
