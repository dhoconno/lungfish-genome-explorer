#!/usr/bin/env python3
"""Write a screenshot recipe YAML for one captured shot.

    write-recipe.py <part-dir> <chapter-file> <shot-id> [--crop window|region|viewport]
                    [--region x y w h] [--fixture demo-project|mhc-cohort|<name>]
                    [--window 1400x900] [--state "one sentence"] [--step "prose step"]...
                    [--viewport-class sequence|alignment|variant|assembly|taxonomy|none]

Reads the caption from the chapter's front matter `shots:` list and writes
docs/user-manual/assets/recipes/<part-dir>/<shot-id>.yaml matching
build/scripts/shot/schema.json. Every click that drove the app is recorded
as a `# PROSE-ONLY:` comment line under steps, since the runner's action
vocabulary has no click. Also marks the shot `captured` in
reviews/fidelity-2026-09/SHOTS.md when a row for it exists.
"""
import argparse
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = {
    "demo-project": "{demo_project}",
    "mhc-cohort": "{mhc_cohort_project}",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("part")
    ap.add_argument("chapter")
    ap.add_argument("shot")
    ap.add_argument("--crop", default="window", choices=["window", "region", "viewport"])
    ap.add_argument("--region", nargs=4, type=int)
    ap.add_argument("--fixture", default="demo-project")
    ap.add_argument("--window", default="1400x900")
    ap.add_argument("--state", default="")
    ap.add_argument("--step", action="append", default=[])
    ap.add_argument("--viewport-class", default="none")
    ap.add_argument("--open", action="append", default=[], help="open_files entry as key=value")
    a = ap.parse_args()

    ch = ROOT / "chapters" / a.part / a.chapter
    text = ch.read_text()
    fm = yaml.safe_load(re.match(r"^---\n(.*?)\n---", text, re.S).group(1))
    caps = {s["id"]: s["caption"] for s in fm.get("shots") or [] if isinstance(s, dict)}
    if a.shot not in caps:
        sys.exit(f"shot {a.shot} not in {ch} front matter")
    w, h = (int(x) for x in a.window.lower().split("x"))
    fixture = FIXTURES.get(a.fixture, a.fixture)
    open_files = [dict([e.split("=", 1)]) for e in a.open]
    recipe = {
        "id": a.shot,
        "chapter": f"{a.part}/{ch.stem}",
        "caption": caps[a.shot],
        "viewport_class": a.viewport_class,
        "app_state": {
            "fixture": fixture,
            "open_files": open_files,
            "window_size": [w, h],
            "appearance": "light",
        },
        "steps": [
            {"action": "open_application", "app": "Lungfish Preview"},
            {"action": "wait_ready", "signal": "main_window_visible"},
            {"action": "resize_window", "size": [w, h]},
        ],
        "crop": {"mode": a.crop} | ({"region": a.region} if a.region else {}),
        "post": {"retina": True, "format": "png"},
    }
    out_dir = ROOT / "assets" / "recipes" / a.part
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{a.shot}.yaml"
    body = yaml.safe_dump(recipe, sort_keys=False, allow_unicode=True, width=100)
    prose = "".join(f"  # PROSE-ONLY: {s}\n" for s in a.step)
    if prose:
        body = body.replace("crop:\n", prose + "crop:\n", 1)
    header = f"# Captured from Lungfish Preview 2026.9.13 with capture-window.sh (2026-09 campaign).\n"
    if a.state:
        header += f"# App state: {a.state}\n"
    out.write_text(header + body)
    shots_md = ROOT / "reviews" / "fidelity-2026-09" / "SHOTS.md"
    if shots_md.exists():
        s = shots_md.read_text()
        pat = re.compile(rf"^(\| {re.escape(a.part)} \| {re.escape(a.chapter)} \| \d+ \| `{re.escape(a.shot)}` \| .*? \| )(new|stale|existing)( \|)", re.M)
        s2, n = pat.subn(lambda m: m.group(1) + "captured" + m.group(3), s)
        if n:
            shots_md.write_text(s2)
    print(out)


if __name__ == "__main__":
    main()
