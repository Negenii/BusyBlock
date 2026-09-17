#!/usr/bin/env python3
"""Turns a release-notes markdown file into the small HTML Sparkle shows.

Handles what the changelog actually uses: headings, bullet lists whose items
wrap over several lines, paragraphs, links, bold and code.
"""
import re, sys

def inline(t):
    t = t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)

blocks = []          # ("h", level, text) | ("p", text) | ("ul", [items])
for raw in open(sys.argv[1]).read().splitlines():
    line, stripped = raw.rstrip(), raw.strip()
    if not stripped:
        blocks.append(("gap",))
        continue
    heading = re.match(r"^(#{1,6})\s+(.*)", stripped)
    bullet = re.match(r"^[-*]\s+(.*)", stripped)
    if heading:
        blocks.append(("h", len(heading.group(1)), heading.group(2)))
    elif bullet:
        if blocks and blocks[-1][0] == "ul":
            blocks[-1][1].append(bullet.group(1))
        else:
            blocks.append(("ul", [bullet.group(1)]))
    elif blocks and blocks[-1][0] in ("ul", "p") and line.startswith((" ", "\t")) or \
         (blocks and blocks[-1][0] in ("ul", "p")):
        # a wrapped continuation of the previous item or paragraph
        if blocks[-1][0] == "ul":
            blocks[-1][1][-1] += " " + stripped
        else:
            blocks[-1] = ("p", blocks[-1][1] + " " + stripped)
    else:
        blocks.append(("p", stripped))

out = []
for b in blocks:
    if b[0] == "h":
        out.append(f"<h{b[1]}>{inline(b[2])}</h{b[1]}>")
    elif b[0] == "p":
        out.append("<p>" + inline(b[1]) + "</p>")
    elif b[0] == "ul":
        out.append("<ul>" + "".join("<li>" + inline(i) + "</li>" for i in b[1]) + "</ul>")
print('<html><head><meta charset="utf-8"><style>body{font:13px -apple-system,sans-serif;margin:8px}'
      'h3{font-size:14px}ul{padding-left:18px}</style></head><body>')
print("\n".join(out))
print("</body></html>")
