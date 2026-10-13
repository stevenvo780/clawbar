#!/usr/bin/env python3
# ===========================================================================
# merge_waybar.py — idempotent JSONC-aware merge of the clawbar waybar module.
#
# Usage: merge_waybar.py <config.jsonc> <modules.jsonc>
#   (modules.jsonc may equal config.jsonc if definitions live in the bar file)
#
# Reads click commands from the environment:
#   CLICK_LEFT, CLICK_RIGHT, CLICK_MIDDLE, BAR_ARRAY (default "modules-right")
#
# Strategy (textual, comment-preserving):
#   1. Insert a "custom/claw": {...} definition right after the opening "{" of
#      the modules object, unless one already exists.
#   2. Add "custom/claw" to the FIRST <BAR_ARRAY> array found in the config that
#      doesn't already include it (so the icon shows on your main bar).
#   3. Validate by stripping comments + trailing commas and json.loads()-ing
#      both files. Exit non-zero on any failure so install.sh can revert.
# ===========================================================================
import json
import os
import re
import sys


def strip_jsonc(text):
    """Remove // and /* */ comments and trailing commas; return parseable JSON.
    String-aware so we never touch comment-like sequences inside strings."""
    out = []
    i, n = 0, len(text)
    in_str = False
    esc = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        # not in string
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    cleaned = "".join(out)
    # remove trailing commas: ,] or ,}
    cleaned = re.sub(r",(\s*[\]}])", r"\1", cleaned)
    return cleaned


def validate(path):
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()
    json.loads(strip_jsonc(raw))


def has_definition(text):
    # A commented-out example must not suppress the live definition.
    return re.search(r'"custom/claw"\s*:', strip_jsonc(text)) is not None


def build_definition_block(indent="    "):
    left = os.environ.get("CLICK_LEFT", "claw-talk toggle")
    right = os.environ.get("CLICK_RIGHT", "chat-claw.sh")
    middle = os.environ.get("CLICK_MIDDLE",
                            'kitty bash -lc "docker exec -it claw openclaw tui"')
    obj = {
        "format": "{}",
        "return-type": "json",
        "exec": "clawbar-status",
        "interval": 2,
        "signal": 8,
        "tooltip": True,
        "on-click": left,
        "on-click-right": right,
        "on-click-middle": middle,
    }
    body = json.dumps(obj, ensure_ascii=False)
    return '%s"custom/claw": %s,' % (indent, body)


def insert_definition(text):
    """Insert the custom/claw definition right after the first top-level '{'."""
    if has_definition(text):
        return text, False
    idx = text.find("{")
    if idx < 0:
        raise RuntimeError("modules file has no opening brace")
    block = build_definition_block()
    return text[: idx + 1] + "\n" + block + text[idx + 1 :], True


def add_to_bar_array(text, array_name):
    """Add "custom/claw" to the first <array_name> that lacks it."""
    # match  "modules-right": [ ... ]  (single bracket level, no nested arrays)
    pattern = re.compile(r'("%s"\s*:\s*\[)([^\]]*)(\])' % re.escape(array_name))
    changed = {"v": False}

    def repl(m):
        if changed["v"]:
            return m.group(0)
        head, inner, tail = m.group(1), m.group(2), m.group(3)
        if "custom/claw" in inner:
            return m.group(0)  # already present in this array; leave it
        sep = ", " if inner.strip() else ""
        # insert at the front so it sits at the left edge of modules-right
        new_inner = ' "custom/claw",' + inner if inner.strip() else ' "custom/claw" '
        changed["v"] = True
        return head + new_inner + tail

    new_text = pattern.sub(repl, text, count=0)
    return new_text, changed["v"]


def already_in_some_array(text, array_name):
    for m in re.finditer(r'"%s"\s*:\s*\[([^\]]*)\]' % re.escape(array_name), text):
        if "custom/claw" in m.group(1):
            return True
    return False


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: merge_waybar.py <config.jsonc> <modules.jsonc>\n")
        return 2
    config_path, modules_path = argv[0], argv[1]
    bar_array = os.environ.get("BAR_ARRAY", "modules-right")

    # 1) definition into modules file
    with open(modules_path, "r", encoding="utf-8") as fh:
        mtext = fh.read()
    mtext2, def_added = insert_definition(mtext)
    if def_added:
        with open(modules_path, "w", encoding="utf-8") as fh:
            fh.write(mtext2)

    # 2) reference into a bar array in the config file
    with open(config_path, "r", encoding="utf-8") as fh:
        ctext = fh.read()
    if already_in_some_array(ctext, bar_array):
        ref_added = False
    else:
        ctext2, ref_added = add_to_bar_array(ctext, bar_array)
        if ref_added:
            with open(config_path, "w", encoding="utf-8") as fh:
                fh.write(ctext2)

    # 3) validate both
    try:
        validate(modules_path)
        validate(config_path)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("validation failed after merge: %s\n" % e)
        return 3

    sys.stderr.write("merge: definition_added=%s reference_added=%s array=%s\n"
                     % (def_added, ref_added, bar_array))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
