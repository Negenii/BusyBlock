#!/usr/bin/env python3
"""Turns a release-notes markdown file into the small HTML Sparkle shows."""
import re, sys

def inline(t):
    t = (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)

out, in_list = [], False
for line in open(sys.argv[1]).read().splitlines():
    s = line.strip()
    if s.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append("<li>" + inline(s[2:]) + "</li>"); continue
    if in_list: out.append("</ul>"); in_list = False
    if not s: continue
    m = re.match(r"^(#{1,6})\s+(.*)", s)
    if m: out.append(f"<h{len(m.group(1))}>{inline(m.group(2))}</h{len(m.group(1))}>")
    elif re.match(r"^\d+\.\s", s): out.append("<p>" + inline(s) + "</p>")
    else: out.append("<p>" + inline(s) + "</p>")
if in_list: out.append("</ul>")
print('<html><head><meta charset="utf-8"><style>body{font:13px -apple-system,sans-serif;margin:8px}'
      'h3{font-size:14px}ul{padding-left:18px}</style></head><body>')
print("\n".join(out))
print("</body></html>")
