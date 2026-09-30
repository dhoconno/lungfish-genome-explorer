#!/usr/bin/env python3
"""Render an LGE quick video from its video.yaml.

Overlays (cards, captions, placeholders) are HTML rendered to transparent PNGs with
headless Chromium, because Homebrew ffmpeg on the dev Mac has no drawtext filter.
ffmpeg then composites app footage onto a Cream canvas and joins the beats.

    python3 screencasts/render.py screencasts/01-lge-overview/video.yaml [--only wide]
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import yaml
from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
SHARED = HERE / "_shared"
REPO = HERE.parent
BANNED_WORDS = REPO / "docs/user-manual/build/scripts/lint/rules/ai-tells-words.txt"
APP_ICON = REPO / "docs/site/assets/app-icon.png"

# Per output: canvas size and the CSS unit that scales type (square reuses the wide template, smaller).
LAYOUTS = {
    "wide": {"size": (1920, 1080), "unit": 1.0, "caption_left": 110, "caption_bottom": 96},
    "square": {"size": (1080, 1080), "unit": 0.78, "caption_left": 64, "caption_bottom": 72},
}


# ---------------------------------------------------------------- lint

def lint_text(beats: list[dict]) -> list[str]:
    """Apply the docs prose rules to every on-screen string."""
    words = []
    for line in BANNED_WORDS.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            words.append(line.lower())
    problems = []
    for beat in beats:
        strings = [beat.get("caption"), beat.get("title"), beat.get("sub"), beat.get("kicker")]
        strings += [l["text"] for l in beat.get("lines", [])]
        for s in filter(None, strings):
            if re.search(r"[\u2014\u2013;!?]", s) or re.search(r"\w:\s", s):
                problems.append(f"{beat['id']}: banned punctuation in {s!r}")
            low = s.lower()
            for w in words:
                if re.search(rf"\b{re.escape(w)}(s|es|ed|d|ing|ly)?\b", low):
                    problems.append(f"{beat['id']}: overused word {w!r} in {s!r}")
        cap = beat.get("caption")
        if cap and not 4 <= len(cap.split()) <= 9:
            problems.append(f"{beat['id']}: caption should be 4 to 9 words ({len(cap.split())})")
    return problems


# ---------------------------------------------------------------- overlays

class Overlays:
    def __init__(self, work: Path):
        self.work = work
        self._pw = sync_playwright().start()
        self._browser = self._pw.chromium.launch()
        self._pages: dict[str, object] = {}

    def close(self):
        self._browser.close()
        self._pw.stop()

    def _page(self, w: int, h: int):
        key = f"{w}x{h}"
        if key not in self._pages:
            page = self._browser.new_page(viewport={"width": w, "height": h}, device_scale_factor=1)
            page.goto((SHARED / "templates/overlay.html").as_uri())
            self._pages[key] = page
        return self._pages[key]

    def render(self, name: str, size: tuple[int, int], spec: dict) -> Path:
        out = self.work / f"{name}.png"
        page = self._page(*size)
        page.evaluate("spec => window.render(spec)", spec)
        page.wait_for_timeout(50)
        page.screenshot(path=str(out), omit_background=True)
        return out


def rounded_mask(size: tuple[int, int], radius: int, path: Path) -> Path:
    img = Image.new("L", size, 0)
    ImageDraw.Draw(img).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    img.save(path)
    return path


# ---------------------------------------------------------------- ffmpeg

def ffmpeg(args: list[str]):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"ffmpeg failed:\n{' '.join(cmd)}\n{result.stderr}")


ENCODE = ["-c:v", "libx264", "-preset", "medium", "-crf", "16", "-pix_fmt", "yuv420p"]


def fit(box_w: int, box_h: int, src_w: float, src_h: float) -> tuple[int, int]:
    scale = min(box_w / src_w, box_h / src_h)
    return int(src_w * scale) // 2 * 2, int(src_h * scale) // 2 * 2


def probe_size(path: Path) -> tuple[int, int]:
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height", "-of", "csv=p=0", str(path)],
                         capture_output=True, text=True, check=True).stdout.strip()
    w, h = out.split(",")
    return int(w), int(h)


def render_card(beat, layout, ov: Overlays, work: Path, fps: int, out: Path):
    spec = {"kind": "card", "unit": layout["unit"], "title": beat["title"], "sub": beat.get("sub"),
            "lines": beat.get("lines", []), "icon": APP_ICON.as_uri() if beat.get("icon") else None}
    png = ov.render(f"{beat['id']}-{layout['name']}", layout["size"], spec)
    ffmpeg(["-loop", "1", "-framerate", str(fps), "-t", str(beat["duration"]), "-i", str(png),
            "-vf", "format=yuv420p", *ENCODE, "-r", str(fps), str(out)])


def render_take(beat, cfg, layout, brand, ov: Overlays, video_dir: Path, work: Path, fps: int, out: Path):
    cw, ch = layout["size"]
    margin = brand["canvas"]["footage_margin"] * (1 if layout["name"] == "wide" else 0.6)
    cream = brand["colors"]["cream"].lstrip("#")
    dur = float(beat["duration"])
    take = video_dir / beat["take"]
    window_aspect = tuple(cfg.get("window_points", (1440, 810)))
    cfg_trim_top = cfg.get("trim_top", 0)

    inputs, pre = [], []
    if take.exists():
        tw, th = probe_size(take)
        inputs += ["-ss", str(beat.get("in", 0)), "-t", str(dur), "-i", str(take)]
        # trim_top drops the window title bar (points, scaled to the take's pixels).
        # crop [x, y, w, h] (fractions of the take) keeps part of a window, e.g. a Finder file list.
        left = 0
        if beat.get("crop"):
            cx, cy, cw_, ch_ = beat["crop"]
            left, top = int(tw * cx) // 2 * 2, int(th * cy) // 2 * 2
            tw, th = int(tw * cw_) // 2 * 2, int(th * ch_) // 2 * 2
        else:
            top = int(th * beat.get("trim_top", cfg_trim_top) / window_aspect[1]) // 2 * 2
            th -= top
        src_w, src_h = tw, th
        crop = f"crop={tw}:{th}:{left}:{top}," if (top or left or beat.get("crop")) else ""
        if layout["name"] == "square" and beat.get("square_focus"):
            fx, fy, fw, fh = beat["square_focus"]
            src_w, src_h = int(tw * fw) // 2 * 2, int(th * fh) // 2 * 2
            crop = f"crop={src_w}:{src_h}:{left + int(tw * fx)}:{top + int(th * fy)},"
        fw_, fh_ = fit(int(cw - 2 * margin), int(ch - 2 * margin), src_w, src_h)
        pre.append(f"[0:v]fps={fps},{crop}scale={fw_}:{fh_}:flags=lanczos,format=rgba[foot]")
    else:
        # Placeholder sized like the window (or its square crop), so layout matches the real cut.
        src_w, src_h = window_aspect
        if layout["name"] == "square" and beat.get("square_focus"):
            src_w, src_h = src_w * beat["square_focus"][2], src_h * beat["square_focus"][3]
        fw_, fh_ = fit(int(cw - 2 * margin), int(ch - 2 * margin), src_w, src_h)
        png = ov.render(f"{beat['id']}-{layout['name']}-ph", (fw_, fh_),
                        {"kind": "placeholder", "unit": layout["unit"], "id": beat["id"], "text": beat.get("placeholder", "")})
        inputs += ["-loop", "1", "-framerate", str(fps), "-t", str(dur), "-i", str(png)]
        pre.append("[0:v]format=rgba[foot]")

    mask = rounded_mask((fw_, fh_), brand["canvas"]["footage_radius"], work / f"{beat['id']}-{layout['name']}-mask.png")
    inputs += ["-loop", "1", "-framerate", str(fps), "-t", str(dur), "-i", str(mask)]
    pre.append("[1:v]format=gray[mask]")
    pre.append("[foot][mask]alphamerge[rounded]")
    pre.append(f"color=c=0x{cream}:s={cw}x{ch}:r={fps}:d={dur}[bg]")
    x, y = (cw - fw_) // 2, (ch - fh_) // 2
    pre.append(f"[bg][rounded]overlay={x}:{y}:shortest=1[base]")
    last = "base"

    if beat.get("caption"):
        t = brand["timing"]
        png = ov.render(f"{beat['id']}-{layout['name']}-cap", layout["size"],
                        {"kind": "caption", "unit": layout["unit"], "text": beat["caption"], "kicker": beat.get("kicker"),
                         "left": layout["caption_left"], "bottom": layout["caption_bottom"],
                         "light": beat["kind"] == "terminal" or beat.get("caption_style") == "light"})
        start, end = t["caption_lead"], dur - t["caption_out"] - 0.35
        hold = end - start
        need = len(beat["caption"].split()) / t["words_per_second"] + t["min_caption_hold"]
        if hold < need:
            print(f"  warning: {beat['id']} caption holds {hold:.1f}s, needs {need:.1f}s")
        inputs += ["-loop", "1", "-framerate", str(fps), "-t", str(dur), "-i", str(png)]
        pre.append(f"[2:v]format=rgba,fade=t=in:st={start}:d={t['caption_in']}:alpha=1,"
                   f"fade=t=out:st={end}:d={t['caption_out']}:alpha=1[cap]")
        pre.append(f"[{last}][cap]overlay=0:0:shortest=1[withcap]")
        last = "withcap"

    ffmpeg([*inputs, "-filter_complex", ";".join(pre), "-map", f"[{last}]", "-t", str(dur), *ENCODE, "-r", str(fps), str(out)])


def render_terminal(beat, video_dir: Path, ov: Overlays, work: Path, fps: int) -> Path:
    """Turn a captured CLI session into footage: the command types out, then the real output appears.

    The output lines come from a file captured when the command actually ran, so the replay shows
    what the tool printed, only paced for reading.
    """
    size = (2880, 1620)  # same shape as a 1440x810 pt window at 2x
    out_lines = (video_dir / beat["output_file"]).read_text().rstrip("\n").splitlines()
    out_lines = out_lines[: beat.get("max_lines", 14)]
    cmd, cps = beat["command"], beat.get("type_cps", 42)
    t_type, line_dt = beat.get("start_delay", 0.6), beat.get("line_interval", 0.18)
    states = []  # (typed, n_lines, caret, seconds)
    states.append(("", 0, True, t_type))
    step = max(1, round(cps / 15))  # redraw 15 times a second while typing
    for i in range(step, len(cmd) + step, step):
        states.append((cmd[:i], 0, True, step / cps))
    states.append((cmd, 0, False, 0.35))
    for n in range(1, len(out_lines) + 1):
        states.append((cmd, n, False, line_dt))
    total = sum(d for *_, d in states)
    hold = float(beat.get("in", 0)) + float(beat["duration"]) - total
    states[-1] = (*states[-1][:3], states[-1][3] + max(hold, 0.5))

    listing = work / f"term-{beat['id']}.txt"
    rows = []
    for i, (typed, n, caret, dur) in enumerate(states):
        png = ov.render(f"term-{beat['id']}-{i:04d}", size, {
            "kind": "terminal", "unit": 2, "title": beat.get("title", ""), "prompt": beat.get("prompt", "$ "),
            "typed": typed, "output": out_lines[:n], "caret": caret})
        rows.append(f"file '{png}'\nduration {dur:.4f}")
    rows.append(f"file '{png}'")  # concat demuxer needs the last file repeated
    listing.write_text("\n".join(rows) + "\n")
    out = work / f"term-{beat['id']}.mov"
    ffmpeg(["-f", "concat", "-safe", "0", "-i", str(listing), "-vf", f"fps={fps},format=yuv420p", *ENCODE, str(out)])
    return out


def join(segments: list[tuple[Path, float, str]], xfade: float, out: Path, fps: int):
    """Join segments, crossfading after a beat marked transition: fade and hard-cutting otherwise."""
    inputs, graph = [], []
    for i, (p, _, _) in enumerate(segments):
        inputs += ["-i", str(p)]
        # xfade needs every input on one timebase.
        graph.append(f"[{i}:v]fps={fps},format=yuv420p,settb=AVTB[s{i}]")
    cur, length = "[s0]", segments[0][1]
    for i in range(1, len(segments)):
        prev_transition = segments[i - 1][2]
        label = f"[j{i}]"
        if prev_transition == "fade":
            graph.append(f"{cur}[s{i}]xfade=transition=fade:duration={xfade}:offset={length - xfade:.3f}{label}")
            length += segments[i][1] - xfade
        else:
            graph.append(f"{cur}[s{i}]concat=n=2:v=1:a=0,settb=AVTB{label}")
            length += segments[i][1]
        cur = label
    ffmpeg([*inputs, "-filter_complex", ";".join(graph), "-map", cur, *ENCODE, "-r", str(fps), "-movflags", "+faststart", str(out)])
    return length


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video", type=Path)
    ap.add_argument("--only", choices=list(LAYOUTS))
    ap.add_argument("--lint-only", action="store_true")
    args = ap.parse_args()

    video_dir = args.video.resolve().parent
    cfg = yaml.safe_load(args.video.read_text())
    brand = json.loads((SHARED / "brand.json").read_text())
    fps = brand["canvas"]["fps"]

    problems = lint_text(cfg["beats"])
    if problems:
        print("On-screen text breaks the prose rules:")
        print("\n".join(f"  {p}" for p in problems))
        sys.exit(1)
    if args.lint_only:
        print("lint: no issues found")
        return

    out_dir = video_dir / "out"
    work = video_dir / ".work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    out_dir.mkdir(exist_ok=True)

    missing = [b["id"] for b in cfg["beats"] if b["kind"] == "take" and not (video_dir / b["take"]).exists()]
    missing += [b["id"] for b in cfg["beats"] if b["kind"] == "terminal" and not (video_dir / b["output_file"]).exists()]
    if missing:
        print(f"placeholders for uncaptured takes: {', '.join(missing)}")

    ov = Overlays(work)
    terminals: dict[str, Path] = {}
    try:
        for name in [args.only] if args.only else cfg.get("outputs", ["wide"]):
            layout = {**LAYOUTS[name], "name": name}
            segments = []
            for i, beat in enumerate(cfg["beats"]):
                seg = work / f"{i:02d}-{beat['id']}-{name}.mp4"
                print(f"[{name}] {beat['id']}")
                if beat["kind"] == "card":
                    render_card(beat, layout, ov, work, fps, seg)
                elif beat["kind"] == "terminal" and not (video_dir / beat["output_file"]).exists():
                    render_take({**beat, "take": "missing"}, cfg, layout, brand, ov, video_dir, work, fps, seg)
                elif beat["kind"] == "terminal":
                    if beat["id"] not in terminals:
                        terminals[beat["id"]] = render_terminal(beat, video_dir, ov, work, fps)
                    render_take({**beat, "take": str(terminals[beat["id"]]), "trim_top": 0}, cfg, layout, brand, ov, video_dir, work, fps, seg)
                else:
                    render_take(beat, cfg, layout, brand, ov, video_dir, work, fps, seg)
                segments.append((seg, float(beat["duration"]), beat.get("transition", "cut")))
            final = out_dir / f"{cfg['slug']}-{name}.mp4"
            length = join(segments, brand["timing"]["crossfade"], final, fps)
            poster = out_dir / f"{cfg['slug']}-{name}-poster.png"
            ffmpeg(["-ss", "1.6", "-i", str(final), "-frames:v", "1", str(poster)])
            shown = final.relative_to(REPO) if final.is_relative_to(REPO) else final
            print(f"wrote {shown} ({length:.1f}s) and poster")
    finally:
        ov.close()


if __name__ == "__main__":
    main()
