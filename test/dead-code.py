#!/usr/bin/env python3
"""Find things nothing uses. Run with:  python3 test/dead-code.py

Exists because this plugin has three languages and no compiler between them: a
`Model.js` export, a `Service` property, a `status.py` helper and an `rclone-rc`
verb can all lose their last caller without anything complaining. Two constants
had already gone stale that way — `DEFAULT_ADDR` in status.py after the transport
moved into rcclient, and a duplicated socket default beside it.

What it deliberately does NOT flag:

  * `rclone-rc` verbs, `status.py` flags and `PanelIpc` functions with no caller
    in this repo. They are the documented scripting and diagnostic surface — that
    is what `omarchy-shell <id> buttonState` and `./rclone-rc pin` are FOR — so
    "unused here" is not "unused".
  * Names referenced only from a comment. A comment mentioning a function is a
    reason to keep the comment accurate, not a use.

Prints findings and exits 1 so `check` fails on rot.
"""

import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent

findings = []


def read(name):
    try:
        return (ROOT / name).read_text(encoding="utf-8")
    except OSError:
        return ""


def strip_comments(text, style):
    """Comments are not uses. Without this, a name kept alive only by the note
    explaining why it was removed still counts as referenced."""
    if style == "js":
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        return re.sub(r"^\s*//.*$", "", text, flags=re.M)
    return re.sub(r"^\s*#.*$", "", text, flags=re.M)


QML = sorted(p.name for p in ROOT.glob("*.qml"))
QML_TEXT = {name: strip_comments(read(name), "js") for name in QML}
ALL_QML = "\n".join(QML_TEXT.values())


def check_model_exports():
    src = read("Model.js")
    body = strip_comments(src, "js")
    tail = src[src.index("module.exports"):] if "module.exports" in src else ""
    for name in sorted(set(re.findall(r"^\s*([A-Za-z_]\w*):\s*[A-Za-z_]", tail, re.M))):
        used_in_qml = ("Model." + name) in ALL_QML
        # More than one mention in Model.js means something there calls it too;
        # the declaration itself is the first.
        used_internally = len(re.findall(r"\b%s\s*\(" % re.escape(name), body)) > 1
        if not used_in_qml and not used_internally:
            findings.append("Model.js exports %s(), which nothing calls" % name)


def check_service_members():
    svc = strip_comments(read("Service.qml"), "js")
    others = "\n".join(t for n, t in QML_TEXT.items() if n != "Service.qml")
    pattern = r"^\s*(?:readonly\s+)?(?:property\s+\S+\s+|function\s+)([A-Za-z_]\w*)"
    for name in sorted(set(re.findall(pattern, svc, re.M))):
        inside = len(re.findall(r"\b%s\b" % re.escape(name), svc))
        outside = len(re.findall(r"\b%s\b" % re.escape(name), others))
        if inside <= 1 and outside == 0:
            findings.append("Service.qml declares %s, which nothing reads" % name)


def check_python(module):
    src = strip_comments(read(module), "py")
    # Everything that could legitimately reference it, including the shell scripts
    # and the tests — a helper used only by a test is still used.
    elsewhere = "".join(strip_comments(read(f), "py" if f.endswith(".py") else "sh")
                        for f in ("status.py", "rcclient.py", "rclone-config",
                                  "rclone-rc", "test/status-test.py",
                                  "test/remote-lifecycle-test.sh")
                        if f != module)
    for name in re.findall(r"^def ([a-z_]\w*)", src, re.M):
        if name == "main":
            continue
        if len(re.findall(r"\b%s\s*\(" % name, src)) <= 1 and name not in elsewhere:
            findings.append("%s defines %s(), which nothing calls" % (module, name))
    for const in re.findall(r"^([A-Z_]{2,}) =", src, re.M):
        if len(re.findall(r"\b%s\b" % const, src)) <= 1 and const not in elsewhere:
            findings.append("%s defines %s, which nothing reads" % (module, const))


def check_orphan_components():
    """A .qml nothing instantiates still ships. `check` warns about this too; here
    it is an error, because the warning scrolled past unnoticed for months."""
    manifest = read("manifest.json")
    entry = re.search(r'"barWidget"\s*:\s*"([^"]+)"', manifest)
    entry = entry.group(1) if entry else ""
    for name in QML:
        if name == entry:
            continue
        base = name[:-4]
        others = "\n".join(t for n, t in QML_TEXT.items() if n != name)
        if not re.search(r"\b%s\b" % re.escape(base), others):
            findings.append("%s is never instantiated" % name)


check_model_exports()
check_service_members()
check_python("status.py")
check_python("rcclient.py")
check_orphan_components()

if findings:
    for line in findings:
        print("  " + line)
    sys.exit(1)
print("  nothing unused")
