#!/usr/bin/env python3
"""Offline integration tests; security and curl are always local stubs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "claude-touchbar.sh"


class CacheSecurityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.log = self.home / "calls"
        for name, body in {
            "security": "printf 'security\\n' >> \"$MOCK_LOG\"\nprintf '%s' \"$MOCK_CREDENTIAL\"\n",
            "curl": "cat >/dev/null\nprintf 'curl\\n' >> \"$MOCK_LOG\"\nprintf '%s\\n200\\n' \"$MOCK_RESPONSE\"\n",
        }.items():
            path = self.bin / name
            path.write_text("#!/bin/bash\n" + body)
            path.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), USER="test-user",
                        PATH=str(self.bin) + ":/usr/bin:/bin", MOCK_LOG=str(self.log),
                        MOCK_CREDENTIAL="{}", MOCK_RESPONSE='{"five_hour":{"utilization":37},"seven_day":{"utilization":8}}')
        self.directory = self.home / ".claude-usage-touchbar"
        self.directory.mkdir(mode=0o700)
        self.cache = self.directory / "usage"
        self.marker = self.home / "INJECTED"

    def put(self, text):
        self.cache.write_text(text + "\n")
        self.cache.chmod(0o600)

    def valid(self):
        return "37 8 20 -1 - " + str(int(time.time()))

    def run_script(self):
        result = subprocess.run(["/bin/bash", str(SCRIPT), "--raw"], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.marker.exists(), "untrusted input executed")
        return result.stdout.strip()

    def enable_api(self):
        self.env["MOCK_CREDENTIAL"] = json.dumps({"claudeAiOauth": {
            "expiresAt": (time.time() + 3600) * 1000, "accessToken": "test-token-only"}})

    def test_legacy_shared_cache_path_is_not_referenced(self):
        # Do not create or disturb another process's real /tmp cache in a test.
        source = "\n".join(line for line in SCRIPT.read_text().splitlines()
                           if not line.lstrip().startswith("#"))
        self.assertNotIn("/tmp/.claude-usage-", source)

    def test_fresh_cache_avoids_credentials_and_network(self):
        self.put(self.valid())
        self.assertRegex(self.run_script(), r"^37 8 20 [0-9]+ ok -1 -$")
        self.assertFalse(self.log.exists())

    def test_arithmetic_payloads_rejected_in_each_numeric_field(self):
        for index in (0, 1, 2, 3, 5):
            with self.subTest(index=index):
                values = self.valid().split()
                values[index] = 'a[$(touch${IFS}' + str(self.marker) + ')]'
                self.put(" ".join(values))
                self.assertEqual(self.run_script(), "0 0 -1 -1 expired")

    def test_malformed_records_rejected(self):
        for value in ("", "1 2", self.valid() + " extra", "101 8 20 -1 - 1",
                      "1 2 999999999999999999999 -1 - 1", "1 2 20 -1 - 9999999999",
                      "1 2 20 -1 bad/name 1", "1 2 20 -1 - 0"):
            with self.subTest(value=value):
                self.put(value)
                self.assertEqual(self.run_script(), "0 0 -1 -1 expired")

    def test_leading_zeroes_normalized(self):
        self.put("008 009 020 -1 - " + str(int(time.time())))
        self.assertRegex(self.run_script(), r"^8 9 20 [0-9]+ ok -1 -$")

    def test_unsafe_file_permissions_rejected(self):
        self.put(self.valid())
        self.cache.chmod(0o644)
        self.assertEqual(self.run_script(), "0 0 -1 -1 expired")

    def test_symlink_cache_not_read_or_followed_on_write(self):
        victim = self.home / "victim"
        victim.write_text(self.valid())
        victim.chmod(0o600)
        original = victim.read_text()
        self.cache.symlink_to(victim)
        self.assertEqual(self.run_script(), "0 0 -1 -1 expired")
        self.enable_api()
        self.assertEqual(self.run_script(), "37 8 -1 0 ok -1 -")
        self.assertFalse(self.cache.is_symlink())
        self.assertEqual(victim.read_text(), original)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)

    def test_symlink_directory_rejected(self):
        self.directory.rmdir()
        target = self.home / "target"
        target.mkdir(mode=0o700)
        self.directory.symlink_to(target, target_is_directory=True)
        self.enable_api()
        self.assertEqual(self.run_script(), "0 0 -1 -1 none")
        self.assertEqual(list(target.iterdir()), [])

    def test_fifo_rejected_without_blocking(self):
        os.mkfifo(self.cache, 0o600)
        self.assertEqual(self.run_script(), "0 0 -1 -1 expired")

    def test_unsafe_directory_rejected(self):
        self.directory.chmod(0o755)
        self.enable_api()
        self.assertEqual(self.run_script(), "0 0 -1 -1 none")
        self.assertFalse(self.cache.exists())

    def test_hardlink_cache_rejected(self):
        victim = self.home / "victim"
        victim.write_text(self.valid())
        victim.chmod(0o600)
        os.link(victim, self.cache)
        self.assertEqual(self.run_script(), "0 0 -1 -1 expired")

    def test_oversized_cache_rejected(self):
        self.put(self.valid() + " " * 1024)
        self.assertEqual(self.run_script(), "0 0 -1 -1 expired")

    def test_concurrent_writes_leave_complete_private_record(self):
        self.enable_api()
        children = [subprocess.Popen(["/bin/bash", str(SCRIPT), "--raw"],
                                    env=self.env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE) for _ in range(4)]
        for child in children:
            out, err = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, err)
            self.assertRegex(out.strip(), r"^37 8 -1 [0-9]+ ok -1 -$")
        self.assertEqual(len(self.cache.read_text().split()), 6)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual([p.name for p in self.directory.iterdir()], ["usage"])

    def test_api_write_creates_private_complete_cache(self):
        self.directory.rmdir()
        self.enable_api()
        self.assertEqual(self.run_script(), "37 8 -1 0 ok -1 -")
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(self.cache.read_text().split()), 6)
        self.assertEqual([p.name for p in self.directory.iterdir()], ["usage"])


if __name__ == "__main__":
    unittest.main()
