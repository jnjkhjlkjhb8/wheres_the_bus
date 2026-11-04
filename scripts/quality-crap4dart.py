#!/usr/bin/env python3
"""Prints the crap4dart executable and records which version it is, for the report."""
import json
import os
import shutil
import subprocess
import sys

VERSION = "0.9.5"
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tool = shutil.which("crap4dart", path=os.environ["PATH"] + os.pathsep + os.path.expanduser("~/.pub-cache/bin"))
if tool is None:
    sys.exit("crap4dart not installed: dart pub global activate crap4dart " + VERSION)
version = subprocess.run([tool, "--version"], capture_output=True, text=True).stdout.strip()
if VERSION not in version:
    sys.exit(f"crap4dart {version!r} is not the pinned {VERSION}")
runtime = os.path.join(root, ".tools", "quality-runtime", f"crap4dart-{VERSION}-annotation-start")
os.makedirs(runtime, exist_ok=True)
json.dump({"tool": tool, "version": version}, open(os.path.join(runtime, "provenance.json"), "w"))
print(tool)
