#!/usr/bin/env python3
"""Prints the CHANGELOG section for one version, for the in-app update window."""
import re, sys
version = sys.argv[1]
text = open(sys.argv[2] if len(sys.argv) > 2 else "CHANGELOG.md").read()
m = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
sys.stdout.write((m.group(1).strip() + "\n") if m else "")
