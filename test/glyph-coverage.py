#!/usr/bin/env python3
"""Every icon this panel draws must exist in the Nerd Font, or it renders tofu.

Why this is a TEST and not a release checklist item: a Nerd Font codepoint is an
opaque five-digit number, so an invented or mistyped one looks exactly like a
correct one in the source. Nothing else catches it — `./check` passes, the QML
loads without error, and the only symptom is a box on screen that whoever
changed the file may never look at.

WHY ONLY ONE FONT IS CHECKED, when Omarchy offers five:

    omarchy-font-list -> Adwaita Mono, iA Writer Mono S, JetBrainsMono Nerd
                         Font, Liberation Mono, Nimbus Mono PS

Measured 2026-08-16: four of those five cover ZERO of this panel's glyphs. They
render anyway because fontconfig substitutes for missing characters, and every
one of them resolves to JetBrainsMono Nerd Font:

    fc-match "Liberation Mono:charset=f01ea"  ->  JetBrainsMono Nerd Font

That font is in `omarchy-base.packages`, so it is present on every Omarchy
install, and the first-party panels (network, tailscale, dropbox) depend on the
same fallback for their own icons. So the real risk is never "the user picked a
different font" — it is "this codepoint does not exist anywhere", which is what
this checks.

Run standalone to look a glyph up by name instead:

    test/glyph-coverage.py --find eject
"""

import struct
import subprocess
import sys
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parent.parent
# The Private Use Area starts here; anything above is an icon, not text.
PUA_START = 0xE000


def font_path(family="JetBrainsMono Nerd Font"):
    try:
        out = subprocess.run(["fc-match", "-f", "%{file}", family],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def _tables(data):
    # A .ttc collection points at its first face; .ttf/.otf start at 0.
    offset = struct.unpack(">I", data[12:16])[0] if data[:4] == b"ttcf" else 0
    count = struct.unpack(">H", data[offset + 4:offset + 6])[0]
    found = {}
    for i in range(count):
        entry = offset + 12 + i * 16
        tag = data[entry:entry + 4].decode("latin-1")
        start, length = struct.unpack(">II", data[entry + 8:entry + 16])
        found[tag] = (start, length)
    return found


def covered(path, codepoints):
    """Which of `codepoints` the font actually maps.

    Reads the cmap directly rather than depending on fontTools: this has to run
    on any machine that can run the plugin, and adding a Python package to the
    test path for one lookup is a worse trade than 30 lines of struct parsing.
    """
    data = Path(path).read_bytes()
    tables = _tables(data)
    if "cmap" not in tables:
        return set()
    start, _ = tables["cmap"]
    subtables = struct.unpack(">H", data[start + 2:start + 4])[0]
    hits = set()
    for i in range(subtables):
        record = start + 4 + i * 8
        sub = start + struct.unpack(">I", data[record + 4:record + 8])[0]
        fmt = struct.unpack(">H", data[sub:sub + 2])[0]
        if fmt == 4:
            # Format 4 is BMP only, so it can never hold an icon above U+FFFF.
            seg_x2 = struct.unpack(">H", data[sub + 6:sub + 8])[0]
            segs = seg_x2 // 2
            ends = struct.unpack(">%dH" % segs, data[sub + 14:sub + 14 + seg_x2])
            starts = struct.unpack(">%dH" % segs,
                                   data[sub + 16 + seg_x2:sub + 16 + 2 * seg_x2])
            for lo, hi in zip(starts, ends):
                hits.update(c for c in codepoints if lo <= c <= hi)
        elif fmt == 12:
            groups = struct.unpack(">I", data[sub + 12:sub + 16])[0]
            for g in range(groups):
                o = sub + 16 + g * 12
                lo, hi, _ = struct.unpack(">III", data[o:o + 12])
                hits.update(c for c in codepoints if lo <= c <= hi)
    return hits


def glyph_names(path):
    """gid -> PostScript name, from the `post` table (format 2.0 only)."""
    data = Path(path).read_bytes()
    tables = _tables(data)
    if "post" not in tables:
        return {}
    start, _ = tables["post"]
    if struct.unpack(">I", data[start:start + 4])[0] != 0x00020000:
        return {}
    count = struct.unpack(">H", data[start + 32:start + 34])[0]
    indices = struct.unpack(">%dH" % count, data[start + 34:start + 34 + 2 * count])
    pos = start + 34 + 2 * count
    extra = []
    while len(extra) < max(indices, default=0) - 257:
        length = data[pos]
        extra.append(data[pos + 1:pos + 1 + length].decode("latin-1"))
        pos += 1 + length
    return {gid: extra[ix - 258]
            for gid, ix in enumerate(indices)
            if ix >= 258 and ix - 258 < len(extra)}


def panel_glyphs():
    """Every PUA character appearing in the plugin's QML, with its file."""
    used = {}
    for qml in sorted(PLUGIN_DIR.glob("*.qml")):
        for line in qml.read_text(encoding="utf-8").splitlines():
            for ch in line:
                if ord(ch) >= PUA_START:
                    used.setdefault(ord(ch), qml.name)
    return used


def find(term):
    path = font_path()
    names = glyph_names(path)
    matches = {gid: nm for gid, nm in names.items() if term.lower() in nm.lower()}
    if not matches:
        print("  no glyph name contains %r" % term)
        return 0
    # Names come from `post`, codepoints from `cmap`, so the two are joined
    # through the glyph id — which means walking the PUA once to build the
    # inverse map. Bounded to the PUA because that is where every icon lives.
    gid_to_cp = {}
    data = Path(path).read_bytes()
    tables = _tables(data)
    start, _ = tables["cmap"]
    subtables = struct.unpack(">H", data[start + 2:start + 4])[0]
    for i in range(subtables):
        record = start + 4 + i * 8
        sub = start + struct.unpack(">I", data[record + 4:record + 8])[0]
        if struct.unpack(">H", data[sub:sub + 2])[0] != 12:
            continue
        groups = struct.unpack(">I", data[sub + 12:sub + 16])[0]
        for g in range(groups):
            o = sub + 16 + g * 12
            lo, hi, first_gid = struct.unpack(">III", data[o:o + 12])
            if hi < PUA_START:
                continue
            for cp in range(max(lo, PUA_START), hi + 1):
                gid_to_cp.setdefault(first_gid + (cp - lo), cp)
    for gid, nm in sorted(matches.items(), key=lambda kv: kv[1]):
        cp = gid_to_cp.get(gid)
        if cp:
            print("  U+%05X  %s  %s" % (cp, chr(cp), nm))
    return 0


def main():
    if "--find" in sys.argv:
        return find(sys.argv[sys.argv.index("--find") + 1])

    path = font_path()
    if not path or not Path(path).exists():
        print("  (skipped: no font file resolved)")
        return 0

    used = panel_glyphs()
    if not used:
        print("  (no glyphs found in the QML — has the panel changed shape?)")
        return 0

    present = covered(path, set(used))
    missing = sorted(cp for cp in used if cp not in present)
    if missing:
        for cp in missing:
            print("  MISSING U+%05X (%s) — not in %s"
                  % (cp, used[cp], Path(path).name))
        print("  %d of %d panel glyphs are missing" % (len(missing), len(used)))
        return 1
    print("  %d panel glyphs, all present in %s" % (len(used), Path(path).name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
