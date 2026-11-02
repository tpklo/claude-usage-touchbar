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
    def test_screen_sleep_notifications_and_independent_lock_state(self):
        self.assertRegex(SOURCE, r"selector:@selector\(screensSlept:\)\s+name:NSWorkspaceScreensDidSleepNotification")
        self.assertRegex(SOURCE, r"selector:@selector\(screensWoke:\)\s+name:NSWorkspaceScreensDidWakeNotification")
        slept = re.search(r"- \(void\)screensSlept:.*?\{(.*?)\}", SOURCE, re.S)[1]
        woke = re.search(r"- \(void\)screensWoke:.*?\{(.*?)\}", SOURCE, re.S)[1]
        self.assertIn("self.dark = YES;", slept)
        self.assertIn("self.dark = NO;", woke)
        self.assertIn("self.lastFrame = NSDate.timeIntervalSinceReferenceDate;", woke)
        self.assertNotIn("self.asleep", slept + woke)
        frame = re.search(r"- \(void\)frame \{(.*?)\n\}", SOURCE, re.S)[1]
        self.assertTrue(frame.strip().startswith("if (self.asleep || self.dark) return;"))
        # Source-level checks only: macOS must still deliver these notifications
        # correctly; an actual screen sleep/wake test needs a Mac.

    @unittest.skipUnless(shutil.which("cc"), "C compiler unavailable")
    def test_clip_selection_runtime_bounds(self):
        function = re.search(r"static int ClipForMood\(.*?\n\}", SOURCE, re.S)[0]
        harness = r'''
#include <assert.h>
typedef enum { MoodCalm, MoodBrisk, MoodTired, MoodPanic } Mood;
static int kClawdClipCount;
static unsigned counter;
static unsigned arc4random_uniform(unsigned n) { return counter++ % n; }
'''
        harness += function + r'''
int main(void) {
    for (kClawdClipCount = 1; kClawdClipCount <= 13; ++kClawdClipCount)
        for (int mood = 0; mood <= 3; ++mood)
            for (int previous = -1; previous <= 12; ++previous)
                for (counter = 0; counter < 32;) {
                    int pick = ClipForMood((Mood)mood, previous);
                    assert(pick >= 0 && pick < kClawdClipCount);
                }
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "clips.c"
            binary = pathlib.Path(directory) / "clips"
            path.write_text(harness)
            subprocess.run(["cc", "-std=c11", "-Wall", "-Werror", str(path), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=10)

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
