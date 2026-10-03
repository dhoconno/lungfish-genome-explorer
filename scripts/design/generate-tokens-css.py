#!/usr/bin/env python3
"""Regenerate docs/design/design-system/tokens.css from tokens.json."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "docs" / "design" / "design-system"


def light(value):
    return value if isinstance(value, str) else value["light"]


def main():
    tokens = json.loads((ROOT / "tokens.json").read_text())
    colors = tokens["color"]["tokens"]
    themed = [c for c in colors if isinstance(c["value"], dict)]
    lines = [':root, [data-theme="light"] {']
    lines += [f"  --{c['name']}: {light(c['value'])};" for c in colors]
    lines += ["}", '[data-theme="dark"] {']
    lines += [f"  --{c['name']}: {c['value']['dark']};" for c in themed]
    lines += ["}", "@media (prefers-color-scheme: dark) {", '  :root:not([data-theme="light"]) {']
    lines += [f"    --{c['name']}: {c['value']['dark']};" for c in themed]
    lines += ["  }", "}", ":root {"]
    for family in ("spacing", "radius", "accent", "opacity"):
        lines += [f"  --{t['name']}: {t['value']};" for t in tokens[family]["tokens"]]
    lines += [f"  --font-{key}: {stack};" for key, stack in tokens["type"]["families"].items()]
    lines.append("}")
    header = "/* Generated from tokens.json by scripts/design/generate-tokens-css.py. Do not edit by hand. */\n"
    (ROOT / "tokens.css").write_text(header + "\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
