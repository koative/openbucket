#!/usr/bin/env python3
"""Writes App/Resources/Credits.html, which macOS shows in the standard About window: every resolved package with
its version, NOTICE file and license, each distinct license text once. Apache 2.0 requires shipping these.

Run after `swift package resolve` (it reads Packages/OpenBucket/.build/checkouts). With --check it only verifies
that the committed file is current; scripts/package-release.sh runs it that way.
"""
import html
import json
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
package = root / "Packages/OpenBucket"
checkouts = package / ".build/checkouts"
output = root / "App/Resources/Credits.html"
LICENSE_NAMES = re.compile(r"^(LICEN[CS]E|COPYING)(\.(txt|md))?$", re.I)


def read(path):
    return path.read_text(encoding="utf-8", errors="replace").strip()


def normalized(text):
    return re.sub(r"\s+", " ", text)


pins = json.loads((package / "Package.resolved").read_text())["pins"]
texts = {}  # normalized license text -> (text, [component names])
components = []
for pin in sorted(pins, key=lambda p: p["identity"]):
    name = pin["identity"]
    folder = checkouts / name
    if not folder.is_dir():
        sys.exit(f"{folder} is missing; run `swift package resolve --package-path Packages/OpenBucket` first.")
    licenses = [p for p in sorted(folder.iterdir()) if LICENSE_NAMES.match(p.name)]
    # Code vendored inside a package (e.g. llhttp in SwiftNIO) ships its own license under Sources/.
    licenses += [p for p in sorted((folder / "Sources").rglob("*")) if p.is_file() and LICENSE_NAMES.match(p.name)]
    if not licenses:
        sys.exit(f"No license file found for {name}.")
    for path in licenses:
        label = name if path.parent == folder else f"{name} ({path.parent.name})"
        texts.setdefault(normalized(read(path)), (read(path), []))[1].append(label)
    notices = [read(p) for p in sorted(folder.iterdir()) if p.name.upper().startswith("NOTICE")]
    version = pin["state"].get("version") or pin["state"]["revision"][:7]
    components.append((name, version, pin["location"].removesuffix(".git"), notices))

parts = [
    "<!doctype html><meta charset=utf-8>",
    "<style>body{font:11px -apple-system,sans-serif}h2{font-size:12px;margin:14px 0 4px}"
    "pre{font:10px ui-monospace,monospace;white-space:pre-wrap}</style>",
    "<p>OpenBucket is free software under the MIT License. It is built with these open-source components:</p>",
]
for name, version, url, notices in components:
    parts.append(f"<h2>{html.escape(name)} {html.escape(version)}</h2><p>{html.escape(url)}</p>")
    parts += [f"<pre>{html.escape(notice)}</pre>" for notice in notices]
for text, users in texts.values():
    parts.append(f"<h2>License used by {html.escape(', '.join(users))}</h2><pre>{html.escape(text)}</pre>")
credits = "\n".join(parts) + "\n"

if "--check" in sys.argv:
    if not output.exists() or output.read_text(encoding="utf-8") != credits:
        sys.exit("App/Resources/Credits.html is out of date; run scripts/generate-credits.py and commit it.")
else:
    output.write_text(credits, encoding="utf-8")
    print(f"Wrote {output.relative_to(root)}: {len(components)} components, {len(texts)} distinct license texts.")
