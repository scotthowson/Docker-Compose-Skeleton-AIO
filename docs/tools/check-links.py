#!/usr/bin/env python3
"""check-links.py — every relative link and image in the README and docs/ must resolve.

Checks Markdown links, images and HTML src/href attributes in README.md and docs/**/*.md:
the file or folder must exist, and a #fragment must match a heading of the target page
(GitHub's anchor rules) or an explicit <a id>/<a name>. Links inside code are ignored;
external links are listed with --external, not fetched.

usage: docs/tools/check-links.py [--external]      exit status 1 when a link is broken
"""
import pathlib
import re
import sys
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[2]
PAGES = [ROOT / "README.md"] + sorted((ROOT / "docs").rglob("*.md"))

FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"`[^`\n]*`")
MD_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
HTML_ATTR = re.compile(r"""\b(?:src|href)\s*=\s*["']([^"']+)["']""")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
EXPLICIT = re.compile(r"""<a\s+(?:id|name)\s*=\s*["']([^"']+)["']""")


def strip_code(lines):
    """The page's lines with fenced blocks blanked and inline code removed."""
    out, fenced = [], False
    for line in lines:
        if FENCE.match(line):
            fenced = not fenced
            out.append("")
            continue
        out.append("" if fenced else INLINE_CODE.sub("", line))
    return out


def slug(text):
    """GitHub's anchor for a heading: lower case, letters, digits, spaces, hyphens, underscores."""
    text = re.sub(r"<[^>]+>", "", text)                      # HTML tags
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)    # links and images keep their text
    text = text.replace("`", "").replace("*", "")
    kept = "".join(c for c in text.lower() if c in " -_" or unicodedata.category(c)[0] in "LN")
    return kept.replace(" ", "-")


_anchor_cache = {}


def anchors(page):
    if page not in _anchor_cache:
        found, seen, fenced = set(), {}, False
        for line in page.read_text(encoding="utf-8").splitlines():
            if FENCE.match(line):
                fenced = not fenced
                continue
            if fenced:
                continue
            found.update(EXPLICIT.findall(line))
            m = HEADING.match(line)
            if m:
                base = slug(m.group(2))
                n = seen.get(base, 0)
                seen[base] = n + 1
                found.add(base if n == 0 else f"{base}-{n}")
        _anchor_cache[page] = found
    return _anchor_cache[page]


def main():
    show_external = "--external" in sys.argv[1:]
    broken, external, checked = [], set(), 0
    for page in PAGES:
        lines = strip_code(page.read_text(encoding="utf-8").splitlines())
        for number, line in enumerate(lines, 1):
            targets = MD_LINK.findall(line) + HTML_ATTR.findall(line)
            for target in targets:
                if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):   # http:, https:, mailto:
                    external.add(target)
                    continue
                checked += 1
                path_part, _, fragment = target.partition("#")
                dest = page if not path_part else (page.parent / path_part).resolve()
                where = f"{page.relative_to(ROOT)}:{number}"
                if not dest.exists():
                    broken.append(f"{where}: {target} (no such file)")
                    continue
                if fragment and dest.suffix == ".md" and fragment not in anchors(dest):
                    broken.append(f"{where}: {target} (no heading #{fragment} in {dest.relative_to(ROOT)})")
    for b in broken:
        print("BROKEN", b)
    if show_external:
        for e in sorted(external):
            print("external", e)
    print(f"{checked} relative links checked in {len(PAGES)} pages, {len(broken)} broken, {len(external)} external")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
