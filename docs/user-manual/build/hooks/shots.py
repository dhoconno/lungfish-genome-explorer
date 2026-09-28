"""MkDocs hook: render `<!-- SHOT: id -->` and `<!-- ILLUSTRATION: id -->` markers.

Chapters carry screenshot markers as HTML comments so that the prose is
independent of capture state. This hook replaces each marker with an image
embed when the asset exists, using the caption recorded in the chapter's
front matter (`shots:` or `illustrations:`), and leaves the comment in place
when it does not, so an uncaptured shot renders as nothing rather than as a
broken image.

Screenshots live at assets/screenshots/<part-dir>/<id>.png and illustrations
at assets/illustrations-imagegen/<part-dir>/<chapter-stem>/<id>.png, both
relative to the manual root (docs/user-manual). The home page, index.md, may
carry illustrations too, at assets/illustrations-imagegen/index/<id>.png.
"""

import re
from pathlib import Path

SHOT = re.compile(r"^(?P<indent>[ \t]*)<!--\s*SHOT:\s*(?P<id>[a-z0-9][a-z0-9-]*)\s*-->[ \t]*$", re.M)
ILLUSTRATION = re.compile(
    r"^(?P<indent>[ \t]*)<!--\s*ILLUSTRATION:\s*(?P<id>[a-z0-9][a-z0-9-]*)\s*-->[ \t]*$", re.M
)


def _captions(meta, key):
    out = {}
    for entry in meta.get(key) or []:
        if isinstance(entry, dict) and entry.get("id"):
            out[entry["id"]] = entry.get("caption") or entry.get("brief") or entry["id"]
    return out


def _embed(indent, rel, alt):
    """Return the image followed by a visible caption paragraph.

    Plain Markdown rather than a figure element, because a marker inside a
    numbered step is indented and an HTML block there is not processed by
    md_in_html. The caption is a paragraph with the shot-caption class,
    styled in css/extra.css.
    """
    caption = " ".join(str(alt).split())
    alt = caption.replace("]", "").replace("[", "")
    lines = [f"![{alt}]({rel}){{ .screenshot }}", "", caption, "{ .shot-caption }"]
    return "\n".join(indent + line if line else "" for line in lines)


def on_page_markdown(markdown, page, config, files):
    src = Path(page.file.abs_src_path)
    docs_dir = Path(config["docs_dir"]).resolve()
    if "chapters" in src.parts:
        part_dir = src.parent.name
        chapter_stem = src.stem
        illus_dir = f"{part_dir}/{chapter_stem}"
    elif src == docs_dir / "index.md":
        # The home page carries illustrations (registered under `index` in
        # illustrations.yaml) but no screenshots.
        part_dir = "index"
        illus_dir = "index"
    else:
        return markdown
    shots_root = docs_dir / "assets" / "screenshots" / part_dir
    illus_root = docs_dir / "assets" / "illustrations-imagegen" / illus_dir
    shot_caps = _captions(page.meta, "shots")
    illus_caps = _captions(page.meta, "illustrations")
    up = "../" * (len(src.relative_to(docs_dir).parts) - 1)

    def shot(m):
        sid = m.group("id")
        png = shots_root / f"{sid}.png"
        if not png.exists():
            return m.group(0)
        rel = f"{up}assets/screenshots/{part_dir}/{sid}.png"
        return _embed(m.group("indent"), rel, shot_caps.get(sid, sid))

    def illus(m):
        iid = m.group("id")
        png = illus_root / f"{iid}.png"
        if not png.exists():
            return m.group(0)
        rel = f"{up}assets/illustrations-imagegen/{illus_dir}/{iid}.png"
        return _embed(m.group("indent"), rel, illus_caps.get(iid, iid))

    markdown = SHOT.sub(shot, markdown)
    markdown = ILLUSTRATION.sub(illus, markdown)
    return markdown
