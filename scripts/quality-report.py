#!/usr/bin/env python3
"""Helpers for check-quality.sh shared by the Go and Dart gates.

normalize-go-coverage <in> <out> <report.json>   one block per position, highest count wins
dart-tests <repo> <manifest> <selection.json>    tests that exercise each changed Dart file
"""
import json
import os
import re
import sys
from collections import deque


def normalize_go_coverage(src, dst, report):
    mode, blocks = "set", {}
    for line in open(src, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("mode:"):
            mode = line.split(":", 1)[1].strip()
            continue
        pos, stmts, count = line.rsplit(" ", 2)
        key = (pos, stmts)
        blocks[key] = max(blocks.get(key, 0), int(count))
    with open(dst, "w", encoding="utf-8") as f:
        f.write(f"mode: {mode}\n")
        for (pos, stmts), count in sorted(blocks.items()):
            f.write(f"{pos} {stmts} {count}\n")
    json.dump({"blocks": len(blocks)}, open(report, "w"))


# A part file is only reachable through the library that declares it.
IMPORT = re.compile(r"""^\s*(?:import|export|part)\s+['"]([^'"]+)['"]""", re.M)


def dart_tests(repo, manifest, selection):
    app = os.path.join(repo, "app")
    files = {}
    for root in ("lib", "test"):
        for dirpath, _, names in os.walk(os.path.join(app, root)):
            for n in names:
                if n.endswith(".dart"):
                    files[os.path.relpath(os.path.join(dirpath, n), app)] = None
    importers = {}
    for rel in files:
        text = open(os.path.join(app, rel), encoding="utf-8", errors="replace").read()
        for target in IMPORT.findall(text):
            if target.startswith("package:wheres_the_bus/"):
                dep = "lib/" + target.removeprefix("package:wheres_the_bus/")
            elif target.startswith(("dart:", "package:")):
                continue
            else:
                dep = os.path.normpath(os.path.join(os.path.dirname(rel), target))
            importers.setdefault(dep, set()).add(rel)
    out = {}
    for changed in json.load(open(manifest))["flutter"]:
        start = changed.removeprefix("app/")
        seen, frontier = {start}, deque([start])
        found = set()
        # Direct importers first; widen one importer layer at a time until some test reaches the file.
        while frontier and not found:
            for _ in range(len(frontier)):
                cur = frontier.popleft()
                for imp in importers.get(cur, ()):
                    if imp in seen:
                        continue
                    seen.add(imp)
                    (found.add(imp) if imp.startswith("test/") and imp.endswith("_test.dart") else frontier.append(imp))
        if not found:
            sys.exit(f"{changed}: no test imports it, directly or through the code that uses it")
        out[changed] = sorted(found)
    json.dump(out, open(selection, "w"), indent=2)


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {
        "normalize-go-coverage": normalize_go_coverage, "dart-tests": dart_tests,
    }[cmd](*args)
