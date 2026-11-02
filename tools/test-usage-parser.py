#!/usr/bin/env python3
"""Compile/run the production C parser tests without AppKit or remote services."""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--sanitize", action="store_true", help="enable AddressSanitizer and UBSan")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
compiler = shlex.split(os.environ.get("CC", "cc"))
if not compiler or not shutil.which(compiler[0]):
    raise SystemExit("A C compiler is required for the native parser tests (set CC).")
flags = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-O1", "-g"]
if args.sanitize:
    flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
with tempfile.TemporaryDirectory(prefix="usage-parser-test-") as directory:
    executable = Path(directory) / "test-usage-parser"
    subprocess.run(compiler + flags + [str(root / "tools/test-usage-parser.c"),
                                      "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
