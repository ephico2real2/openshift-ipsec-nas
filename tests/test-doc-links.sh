#!/bin/bash
# Every relative link and image in every tracked Markdown file must resolve, and every #anchor must
# name a heading of its target file (GitHub's heading slugs). Run from the repository root:
#   tests/test-doc-links.sh
set -euo pipefail

python3 - <<'PY'
import os
import re
import subprocess
import sys
from urllib.parse import unquote


def slug(heading):
    """GitHub's anchor for a heading: formatting dropped, lowercase, punctuation removed, spaces to '-'."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading)
    text = re.sub(r"[`*_]", "", text).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def outside_code(lines):
    code = False
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            code = not code
            continue
        if not code:
            yield n, line


anchors = {}


def anchors_of(path):
    if path not in anchors:
        seen, found = {}, set()
        with open(path, encoding="utf-8") as f:
            for _, line in outside_code(f.read().splitlines()):
                m = re.match(r"#{1,6} (.+?)\s*#*$", line)
                if m:
                    base = slug(m.group(1))
                    k = seen.get(base, 0)
                    found.add(base if k == 0 else f"{base}-{k}")
                    seen[base] = k + 1
        anchors[path] = found
    return anchors[path]


LINK = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)|(?:src|srcset)=\"([^\"]+)\"")
files = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True, check=True).stdout.split()
errors = 0
for md in files:
    with open(md, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for n, line in outside_code(lines):
        for m in LINK.finditer(line):
            target = m.group(1) or m.group(2)
            if re.match(r"[a-z]+:", target):
                continue
            path, _, anchor = target.partition("#")
            full = os.path.normpath(os.path.join(os.path.dirname(md), unquote(path))) if path else md
            if not os.path.exists(full):
                print(f"{md}:{n}: missing file {target}")
                errors += 1
            elif anchor and full.endswith(".md") and anchor not in anchors_of(full):
                print(f"{md}:{n}: no heading for #{anchor} in {full}")
                errors += 1
print(f"{'FAIL' if errors else 'ok'}    {len(files)} Markdown files, {errors} broken links")
sys.exit(1 if errors else 0)
PY
