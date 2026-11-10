#!/usr/bin/env python3
"""Reject engine errors even when Godot exits zero."""
import argparse
import pathlib
import re
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("log", type=pathlib.Path)
parser.add_argument("--marker", required=True)
parser.add_argument("--physical", action="store_true")
args = parser.parse_args()
text = args.log.read_text(errors="replace")
errors = []
for line in text.splitlines():
    if re.search(r"(^|\s)(ERROR:|SCRIPT ERROR:|USER ERROR:|error(?:\([^)]*\))?:|panic:)", line, re.I):
        errors.append(line)
    elif re.search(r"undefined symbol|error loading extension|failed to load.*(?:gdextension|libnative_video)|leaked at exit|memory address .* leaked|ObjectDB instances leaked|Segmentation fault", line, re.I):
        errors.append(line)
if args.marker not in text:
    errors.append(f"Missing success marker: {args.marker}")
if args.physical:
    devices = re.findall(r"^Vulkan .*Using Device.*$", text, re.M)
    if not devices or any(re.search(r"llvmpipe|lavapipe|swiftshader|software", d, re.I) for d in devices):
        errors.append("Physical Vulkan renderer was not established in engine output")
if errors:
    print(f"LINUX_VALIDATION_LOG_FAIL {args.log}", file=sys.stderr)
    for error in errors[:20]:
        print(error, file=sys.stderr)
    sys.exit(1)
print(f"LINUX_VALIDATION_LOG_PASS {args.log.name}")
