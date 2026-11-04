#!/usr/bin/env python3
"""Helpers for check-quality.sh in the default (changed-code) scope.

inventory <repo> <base> <outdir>     what changed since <base>, as files + manifest.json
go-lines <manifest> <file>          changed lines of <file>, as mutator --lines wants them
go-tests <repo> <manifest> <out>     per changed Go file, the go test command for mutator
go-test-command <commands> <file>
go-mutation <manifest> <log>...      mutator site logs on changed lines against the mutation thresholds
go-dry <manifest> <dry.edn>          dryer pairs that touch a changed line
flavor-tests <selection.json>        tests that need the Firebase flavor (none today)
dart-config <manifest> <selection> <file> <out.xml>
dart-report <manifest> <raw.json> <out.json> <status>
dart-mutation <log> <status>
"""
import json
import os
import re
import subprocess
import sys

CRAP_MAX = 4.0
MUTATION_MIN = 90.0
GENERATED = re.compile(r"(\.pb\.go|\.pb\w*\.dart|\.g\.dart|\.freezed\.dart|/generated/|/l10n/app_i18n\w*\.dart)$")


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def changed_lines(repo, base, path):
    """New-side line ranges of <path> that differ from <base>; whole file if it is new."""
    tracked = subprocess.run(["git", "-C", repo, "cat-file", "-e", f"{base}:{path}"], capture_output=True).returncode == 0
    if not tracked:
        with open(os.path.join(repo, path), encoding="utf-8") as f:
            n = sum(1 for _ in f)
        return [[1, n]] if n else []
    ranges = []
    for line in git(repo, "diff", "-U0", "--no-renames", base, "--", path).splitlines():
        m = re.match(r"@@ -\S+ \+(\d+)(?:,(\d+))? @@", line)
        if m:
            start, count = int(m.group(1)), int(m.group(2) or 1)
            if count:
                ranges.append([start, start + count - 1])
    return ranges


def inventory(repo, base, out):
    changed = set(git(repo, "diff", "--no-renames", "--name-only", "--diff-filter=d", base).splitlines())
    changed |= set(git(repo, "ls-files", "--others", "--exclude-standard").splitlines())
    go, dart = {}, {}
    for path in sorted(changed):
        if not os.path.isfile(os.path.join(repo, path)) or GENERATED.search(path):
            continue
        if path.endswith(".go") and not path.endswith("_test.go"):
            lines = changed_lines(repo, base, path)
            if lines:
                go[path] = lines
        elif path.startswith("app/lib/") and path.endswith(".dart"):
            lines = changed_lines(repo, base, path)
            if lines:
                dart[path] = lines
    tracked = [p for p in dart if subprocess.run(["git", "-C", repo, "cat-file", "-e", f"{base}:{p}"], capture_output=True).returncode == 0]
    untracked = [p for p in dart if p not in tracked]
    os.makedirs(out, exist_ok=True)
    write = lambda name, items: open(os.path.join(out, name), "w").write("".join(i + "\n" for i in items))
    write("go-files.txt", go)
    write("flutter-files.txt", dart)
    write("flutter-tracked.txt", tracked)
    write("flutter-untracked.txt", [p.removeprefix("app/") for p in untracked])
    json.dump({"base": base, "go": go, "flutter": dart}, open(os.path.join(out, "manifest.json"), "w"), indent=2)


def go_lines(manifest, file):
    ranges = json.load(open(manifest))["go"][file]
    print(",".join(str(n) for b, e in ranges for n in range(b, e + 1)))


def go_tests(repo, manifest, out):
    # mutator links every sibling directory into its worker, and `go test ./...`
    # does not descend into symlinks, so each file gets an explicit package list:
    # its own package plus every package whose tests depend on it.
    # go list reports resolved directories; macOS temp dirs sit behind /var -> /private/var.
    repo = os.path.realpath(repo)
    listing = subprocess.run(
        ["go", "list", "-e", "-test", "-f", '{{.ImportPath}}|{{.Dir}}|{{join .Deps " "}}', "./..."],
        cwd=repo, capture_output=True, text=True, check=True).stdout
    dirs, tested_by = {}, {}
    for row in listing.splitlines():
        path, folder, deps = row.split("|")
        name, _, variant = path.partition(" [")
        if name.endswith(".test"):
            continue
        if not variant:
            dirs[name] = "./" + os.path.relpath(folder, repo)
            continue
        owner = variant.removesuffix(".test]")
        for dep in deps.split() + [name]:
            tested_by.setdefault(dep, set()).add(owner)
    by_dir = {d: p for p, d in dirs.items()}
    commands = {}
    for file in json.load(open(manifest))["go"]:
        package = by_dir["./" + os.path.dirname(file)]
        targets = sorted(dirs[p] for p in tested_by.get(package, set()) | {package} if p in dirs)
        # Fixed database/Redis fixtures cannot be shared by concurrent test binaries.
        commands[file] = "go test -count=1 -p=1 " + " ".join(targets)
    json.dump(commands, open(out, "w"), indent=2)


def go_test_command(commands, file):
    print(json.load(open(commands))[file])


def go_mutation(manifest, *logs):
    changed = json.load(open(manifest))["go"]
    counts = {"KILLED": 0, "SURVIVED": 0, "UNCOVERED": 0}
    for log in logs:
        for line in open(log, encoding="utf-8", errors="replace"):
            # "KILLED    services/x/y.go:42 > -> >=". mutator lists uncovered sites
            # from the whole file even with --lines, so filter to changed lines.
            m = re.match(r"(KILLED|SURVIVED|UNCOVERED)\s+(\S+):(\d+) ", line)
            if m and any(b <= int(m.group(3)) <= e for b, e in changed.get(m.group(2), [])):
                counts[m.group(1)] += 1
    killed, survived, uncovered = counts["KILLED"], counts["SURVIVED"], counts["UNCOVERED"]
    executed = killed + survived
    if executed + uncovered == 0:
        print("go mutation: no mutable changed lines")
        return
    efficacy = 100.0 * killed / executed if executed else 0.0
    coverage = 100.0 * executed / (executed + uncovered)
    print(f"go mutation: killed {killed}, survived {survived}, not covered {uncovered}, "
          f"efficacy {efficacy:.1f}%, mutant coverage {coverage:.1f}%")
    if efficacy < MUTATION_MIN or coverage < MUTATION_MIN:
        sys.exit(1)


DRY_SPAN = re.compile(r':(left|right) \{:file "([^"]+)", :start-line (\d+), :end-line (\d+)\}')
DRY_SCORE = re.compile(r":score ([\d.]+)")


def go_dry(manifest, edn):
    # dryer reports every pair over its threshold and always exits 0. Only a pair
    # with one side on a changed line fails, so legacy duplicates do not block.
    changed = json.load(open(manifest))["go"]
    bad = 0
    for block in open(edn, encoding="utf-8").read().split("{:score")[1:]:
        spans = DRY_SPAN.findall(block)
        if not any(f in changed and any(b <= int(e) and int(s) <= c_end for b, c_end in changed[f])
                   for _, f, s, e in spans):
            continue
        bad += 1
        score = DRY_SCORE.search(":score" + block).group(1)
        print(f"duplicate {score}: " + " ~ ".join(f"{f}:{s}-{e}" for _, f, s, e in spans))
    if bad:
        sys.exit(1)
    print("go duplication ok")


def flavor_tests(selection):
    # No changed file needs the Firebase-enabled flavor yet; see check-quality.sh.
    return


def dart_config(manifest, selection, file, out):
    ranges = json.load(open(manifest))["flutter"][file]
    tests = json.load(open(selection))[file]
    rel = file.removeprefix("app/")
    lines = "".join(f'<lines begin="{b}" end="{e}"/>' for b, e in ranges)
    cmd = "flutter test " + " ".join(tests)
    open(out, "w").write(
        '<?xml version="1.0" encoding="UTF-8"?><mutations version="1.0">'
        f"<files><file>{rel}{lines}</file></files>"
        f'<commands><command group="test" expected-return="0" working-directory=".">{cmd}</command></commands>'
        "</mutations>\n"
    )


def dart_report(manifest, raw, out, status):
    try:
        data = json.load(open(raw))
    except (OSError, ValueError):
        sys.exit(f"dart CRAP tool produced no report (exit {status})")
    authored = set(json.load(open(manifest))["flutter"])
    # The tool's diff mode also lists changed test files; only authored lib code is gated.
    methods = [m for m in data.get("methods", []) if "app/" + m["file"].split("/app/")[-1].removeprefix("app/") in authored]
    bad = [m for m in methods if m.get("crap") is None or m["crap"] > CRAP_MAX]
    json.dump({"methods": len(methods), "over": bad}, open(out, "w"), indent=2)
    for m in bad:
        print(f"over {CRAP_MAX:g}: {m['file']}:{m['line']} {m.get('class') or ''}.{m['method']} crap={m.get('crap')}")
    if bad:
        sys.exit(1)
    print(f"dart CRAP ok: {len(methods)} methods <= {CRAP_MAX:g}")


def dart_mutation(log, status):
    text = open(log, encoding="utf-8", errors="replace").read()
    text = text.replace("\r", "\n")
    found = re.search(r"Found (\d+) mutations in", text)
    if found and int(found.group(1)) == 0:
        print("no mutable changed lines")
        return
    m = re.search(r"Undetected Mutations: (\d+) \(([\d.]+)%\)", text)
    if not m:
        sys.exit(f"mutation_test left no result (exit {status})")
    score = 100.0 - float(m.group(2))
    nc = re.search(r"Not covered by tests: (\d+)", text)
    print(f"dart mutation score {score:.1f}% (undetected {m.group(1)}, not covered {nc.group(1) if nc else '?'})")
    if score < MUTATION_MIN:
        sys.exit(1)


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {
        "inventory": inventory, "go-lines": go_lines, "go-tests": go_tests, "go-test-command": go_test_command,
        "go-mutation": go_mutation, "go-dry": go_dry, "flavor-tests": flavor_tests,
        "dart-config": dart_config, "dart-report": dart_report, "dart-mutation": dart_mutation,
    }[cmd](*args)
