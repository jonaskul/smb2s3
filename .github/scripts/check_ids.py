#!/usr/bin/env python3
"""Fail if app.js looks up an element id that index.html does not define.

A missing id makes getElementById return null; the first property access on it
throws and kills the whole IIFE, leaving a blank page. Since smb2s3-update
pulls straight from main and restarts the service, that breaks every install.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

html = (ROOT / "web/static/index.html").read_text()
js = (ROOT / "web/static/app.js").read_text()

defined = set(re.findall(r'\bid="([^"]+)"', html))
used = set(re.findall(r'getElementById\(\s*"([^"]+)"\s*\)', js))

missing = sorted(used - defined)
if missing:
    print("app.js references element ids that index.html does not define:")
    for name in missing:
        print(f"  - {name}")
    sys.exit(1)

print(f"OK — {len(used)} referenced ids all present in index.html")
