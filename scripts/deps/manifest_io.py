#!/usr/bin/env python3
"""Load and write ``third-party-tools-lock.json`` in the repo's own style.

The manifest is hand-maintained and read in code review, so a bump must not
reflow it. This module reproduces the checked-in formatting exactly:

* 2-space indent, one top-level key per line, keys in their existing order
* entries of the object-list sections (``tools``, ``packTools``,
  ``managedData``, ``pipelines``, ``databases``) on a single line each, written
  as ``{ "k": v, ... }`` with a space inside the braces
* ``bootstrap`` fully inline, nested objects included
* every other container pretty-printed the way ``json.dumps(indent=2)`` does
* a trailing newline at end of file

``dump`` is byte-for-byte round-trip safe against the current manifest, which
is asserted by ``scripts/tests/test_bump.py``.

Stdlib only; no third-party imports.
"""

import json
import pathlib

# Top-level list sections whose entries are written one per line.
INLINE_ENTRY_SECTIONS = ("tools", "packTools", "managedData", "pipelines", "databases")

# Top-level keys written fully inline, nested objects included.
INLINE_SECTIONS = ("bootstrap",)

INDENT = "  "


def load(path):
    """Read the manifest at ``path`` into a dict (key order preserved)."""
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def _scalar(value):
    """Render a leaf value (or a flat list of leaves) the way the file does."""
    return json.dumps(value, ensure_ascii=False)


def _inline(value):
    """One-line rendering: ``{ "k": v }`` / ``[a, b]``, recursing into nesting."""
    if isinstance(value, dict):
        if not value:
            return "{}"
        body = ", ".join(
            f"{json.dumps(k, ensure_ascii=False)}: {_inline(v)}" for k, v in value.items()
        )
        return "{ " + body + " }"
    if isinstance(value, list):
        if not value:
            return "[]"
        return "[" + ", ".join(_inline(item) for item in value) + "]"
    return _scalar(value)


def _is_flat(value):
    """True when ``value`` holds no nested containers."""
    if isinstance(value, dict):
        return all(not isinstance(v, (dict, list)) for v in value.values())
    if isinstance(value, list):
        return all(not isinstance(v, (dict, list)) for v in value)
    return True


def _render(value, depth):
    """Render ``value`` at ``depth`` levels of indentation."""
    pad = INDENT * depth
    inner_pad = INDENT * (depth + 1)

    if isinstance(value, dict):
        if not value:
            return "{}"
        if _is_flat(value):
            return _inline(value)
        parts = [
            f"{inner_pad}{json.dumps(k, ensure_ascii=False)}: {_render(v, depth + 1)}"
            for k, v in value.items()
        ]
        return "{\n" + ",\n".join(parts) + "\n" + pad + "}"

    if isinstance(value, list):
        if not value:
            return "[]"
        if _is_flat(value):
            return _scalar(value)
        parts = [f"{inner_pad}{_render(item, depth + 1)}" for item in value]
        return "[\n" + ",\n".join(parts) + "\n" + pad + "]"

    return _scalar(value)


def _render_section(key, value, depth):
    """Apply the per-section layout rules to a top-level key."""
    if key in INLINE_SECTIONS:
        return _inline(value)
    if key in INLINE_ENTRY_SECTIONS and isinstance(value, list):
        if not value:
            return "[]"
        inner_pad = INDENT * (depth + 1)
        parts = [f"{inner_pad}{_inline(item)}" for item in value]
        return "[\n" + ",\n".join(parts) + "\n" + INDENT * depth + "]"
    return _render(value, depth)


def dumps(manifest):
    """Serialize ``manifest`` to the repo's manifest style, trailing newline included."""
    parts = [
        f"{INDENT}{json.dumps(key, ensure_ascii=False)}: {_render_section(key, value, 1)}"
        for key, value in manifest.items()
    ]
    return "{\n" + ",\n".join(parts) + "\n}\n"


def dump(manifest, path):
    """Write ``manifest`` to ``path`` in the repo's manifest style."""
    pathlib.Path(path).write_text(dumps(manifest), encoding="utf-8")
