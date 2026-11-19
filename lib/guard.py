"""Training-guard configuration and run-output mention scanning.

The guard builds an OpenCode permission config that denies reads of secret-like
paths and denies the tools that can read files indirectly. It is a data-flow
filter, not a sandbox: write access is outside its scope.
"""

import fnmatch
import json
import os
import re
import sys

SCHEMA = "https://opencode.ai/config.json"

# Action names follow OpenCode's permission schema. Verify them against the
# OpenCode version pinned for a run before relying on these deny rules.
DENY_ALL_ACTIONS = ("shell", "grep", "subagent", "execute", "webfetch", "websearch")

_TOKEN_RE = re.compile(r"[A-Za-z0-9_.~/\\:-]+")
_DRIVE_RE = re.compile(r"^([A-Za-z]):(?:/(.*))?$")
_MSYS_RE = re.compile(r"^/([A-Za-z])(?:/(.*))?$")
_ABS_RE = re.compile(r"^(?:[A-Za-z]:/|/)")


def _forms(p):
    """Return the forward-slash, backslash and drive spellings of one path."""
    p = str(p).replace("\\", "/")
    if len(p) > 1:
        p = p.rstrip("/")
    out = [p]
    m = _DRIVE_RE.match(p)
    if m:
        tail = "/" + m.group(2) if m.group(2) else ""
        alt = "/" + m.group(1).lower() + tail
        if alt not in out:
            out.append(alt)
    else:
        m = _MSYS_RE.match(p)
        if m:
            tail = "/" + m.group(2) if m.group(2) else ""
            alt = m.group(1).upper() + ":" + tail
            if alt not in out:
                out.append(alt)
    for item in list(out):
        back = item.replace("/", "\\")
        if back not in out:
            out.append(back)
    return out


def path_forms(root):
    """Spell a root every way an OpenCode process may see it.

    Windows drive roots appear as C:/x, C:\\x and /c/x. Plain paths get a
    forward-slash and a backslash spelling. Duplicates are dropped.
    """
    return _forms(root)


def _windows_root(root):
    p = str(root).replace("\\", "/")
    return bool(_DRIVE_RE.match(p) or _MSYS_RE.match(p))


def variants(glob, root):
    """Expand one glob into the forms a deny rule needs.

    The list keeps the glob as written, anchors it under every root spelling,
    and adds an unanchored **/ form for relative globs. Order is stable and
    duplicates are dropped.
    """
    g = str(glob).replace("\\", "/").strip()
    out = [g]

    def add(value):
        if value not in out:
            out.append(value)

    if g.startswith("~/"):
        home = os.path.expanduser("~")
        for form in path_forms(home):
            add(form + g[1:])
    elif _ABS_RE.match(g):
        for form in path_forms(g):
            add(form)
    else:
        for form in path_forms(root):
            add(form + "/" + g)
        if not g.startswith("**/"):
            add("**/" + g)

    if g.startswith("**/"):
        add(g[3:])
        if not _ABS_RE.match(g[3:]):
            for form in path_forms(root):
                add(form + "/" + g[3:])

    for value in list(out):
        add(value.replace("/", "\\"))
    if _windows_root(root):
        for value in list(out):
            add(value.lower())
    return out


def make_config(globs, root):
    """Build the OpenCode permission document for the given guard globs."""
    rules = []
    seen = set()
    for glob in globs:
        for value in variants(glob, root):
            for action in ("read", "glob"):
                key = (action, value)
                if key in seen:
                    continue
                seen.add(key)
                rules.append({"action": action, "resource": value, "effect": "deny"})
    for action in DENY_ALL_ACTIONS:
        rules.append({"action": action, "resource": "*", "effect": "deny"})
    return {"$schema": SCHEMA, "permissions": rules}


def scan_mentions(text, globs, root):
    """Return concrete paths in text that the generated guard config would deny."""
    windows = _windows_root(root)
    patterns = []
    for glob in globs:
        for value in variants(glob, root):
            patterns.append(value)
            if windows:
                patterns.append(value.lower())

    hits = []
    seen = set()
    for token in _TOKEN_RE.findall(text or ""):
        if "*" in token or token in (".", "..") or token.endswith(("/", ":")):
            continue
        normalized = token.replace("\\", "/")
        candidates = [normalized]
        if windows:
            candidates.append(normalized.lower())
        if any(
            fnmatch.fnmatchcase(candidate, pattern)
            for candidate in candidates
            for pattern in patterns
        ):
            if token not in seen:
                seen.add(token)
                hits.append(token)
    return hits


def _usage():
    print("usage: guard.py config <out.json> <root> <glob>...", file=sys.stderr)
    print("       guard.py mentions <run-output-file> <root> <glob>...", file=sys.stderr)
    return 2


def main(argv):
    if len(argv) < 3:
        return _usage()
    command, target, root, globs = argv[0], argv[1], argv[2], argv[3:]
    if command == "config":
        with open(target, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(make_config(globs, root), handle, indent=2)
            handle.write("\n")
        return 0
    if command == "mentions":
        try:
            with open(target, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            return 0
        hits = scan_mentions(text, globs, root)
        for hit in hits:
            print("guard: run output mentions excluded path: " + hit, file=sys.stderr)
        return 1 if hits else 0
    return _usage()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
