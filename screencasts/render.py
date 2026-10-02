#!/usr/bin/env python3
"""Render an LGE quick video from its video.yaml.

Overlays (cards, captions, placeholders) are HTML rendered to transparent PNGs with
headless Chromium, because Homebrew ffmpeg on the dev Mac has no drawtext filter.
ffmpeg then composites app footage onto a Cream canvas and joins the beats.

    python3 screencasts/render.py screencasts/01-lge-overview/video.yaml [--only wide]
"""
from __future__ import annotations

import argparse
import hashlib
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


# ---------------------------------------------------------------- spec

def filmed_with_text(cfg: dict) -> str:
    """'Filmed with Lungfish Preview 2026.9.75' from the spec's version tag."""
    fw = cfg["filmed_with"]
    versions = fw["versions"]
    shown = versions[0] if len(versions) == 1 else ", ".join(versions[:-1]) + " and " + versions[-1]
    return f"Filmed with {fw['app']} {shown}"


def validate_spec(cfg: dict) -> list[str]:
    """Every video records what it was filmed with and what each beat shows, so it can be remade."""
    problems = []
    fw = cfg.get("filmed_with") or {}
    if not fw.get("app") or not fw.get("versions"):
        problems.append("filmed_with needs app and versions (the release the takes were filmed on)")
    for key in ("title", "purpose"):
        if not cfg.get(key):
            problems.append(f"missing top-level {key}")
    for beat in cfg["beats"]:
        if not beat.get("shows"):
            problems.append(f"{beat['id']}: missing shows (what the beat demonstrates)")
        if beat["kind"] == "take" and not beat.get("capture"):
            problems.append(f"{beat['id']}: missing capture (how to film it again)")
    return problems


def current_app_version() -> str:
    text = (REPO / "Sources/LungfishCore/AppVersion.swift").read_text()
    return re.search(r'static let short = "([^"]+)"', text).group(1)


def print_status():
    """List every video with the versions it was filmed on, against the current app version."""
    current = current_app_version()
    key = lambda v: tuple(int(x) for x in v.split("."))
    print(f"current app version {current}")
    for spec in sorted(HERE.glob("*/video.yaml")):
        cfg = yaml.safe_load(spec.read_text())
        versions = (cfg.get("filmed_with") or {}).get("versions") or []
        state = "untagged" if not versions else ("current" if key(min(versions, key=key)) >= key(current) else "behind")
        print(f"  {cfg.get('slug', spec.parent.name):<28} filmed {', '.join(versions) or '-':<24} {state}")


# ---------------------------------------------------------------- narration
# A narrated video sets top-level `narration: {engine: say, voice, words_per_minute, lead, tail,
# lexicon}` and a `narration` line on each beat that speaks. Each line is synthesised with the
# macOS `say` command (an on-device voice, so a remake sounds the same), cached by its text and
# voice, and placed `lead` seconds into its beat. A beat is lengthened to fit its line.

def narration_settings(cfg: dict) -> dict | None:
    n = cfg.get("narration")
    return n if isinstance(n, dict) else None


def installed_voices() -> set[str]:
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    return {re.split(r"\s{2,}", line.strip())[0] for line in out.splitlines() if line.strip()}


def spoken_text(text: str, lexicon: dict[str, str]) -> str:
    """Apply the spec's pronunciation lexicon to the words the voice reads."""
    for word, spoken in sorted(lexicon.items(), key=lambda kv: -len(kv[0])):
        text = re.sub(rf"(?<![\w-]){re.escape(word)}(?![\w-])", spoken, text)
    return " ".join(text.split())


def api_key(name: str) -> str:
    """An API key from the environment or ~/.env, read only into this process."""
    import os
    if os.environ.get(name):
        return os.environ[name]
    env = Path.home() / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            m = re.match(rf"^(?:export\s+)?{name}=(.*)$", line.strip())
            if m:
                return m.group(1).strip().strip('"').strip("'")
    sys.exit(f"{name} is not set (environment or ~/.env)")


def synthesize_cloud(engine: str, spoken: str, settings: dict, out: Path):
    """Calls ElevenLabs or OpenAI text to speech and writes WAV audio to `out`."""
    import json as _json
    import urllib.request
    if engine == "elevenlabs":
        url = (f"https://api.elevenlabs.io/v1/text-to-speech/{settings['voice_id']}"
               f"?output_format={settings.get('output_format', 'wav_24000')}")
        body = {"text": spoken, "model_id": settings.get("model", "eleven_v4"), "seed": int(settings.get("seed", 4242)),
                "voice_settings": settings.get("voice_settings", {"stability": 0.6, "similarity_boost": 0.75, "style": 0, "speed": 0.95})}
        if settings.get("pronunciation_dictionaries"):
            body["pronunciation_dictionary_locators"] = settings["pronunciation_dictionaries"]
        headers = {"xi-api-key": api_key("ELEVENLABS_API_KEY"), "Content-Type": "application/json"}
    elif engine == "openai":
        url = "https://api.openai.com/v1/audio/speech"
        body = {"model": settings.get("model", "gpt-4o-mini-tts"), "voice": settings["voice"], "input": spoken,
                "response_format": "wav"}
        if settings.get("instructions"):
            body["instructions"] = settings["instructions"]
        headers = {"Authorization": f"Bearer {api_key('OPENAI_API_KEY')}", "Content-Type": "application/json"}
    else:
        sys.exit(f"unknown narration engine '{engine}'")
    request = urllib.request.Request(url, data=_json.dumps(body).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(request, timeout=120) as response:
        out.write_bytes(response.read())


def narration_identity(settings: dict) -> str:
    """Everything that changes the audio, so a cached line is reused only when it would sound the same."""
    keys = ["engine", "voice", "voice_id", "model", "words_per_minute", "seed", "voice_settings",
            "instructions", "pronunciation_dictionaries", "output_format"]
    return json.dumps({k: settings.get(k) for k in keys}, sort_keys=True)


def synthesize(text: str, settings: dict, cache: Path) -> tuple[Path, float]:
    """WAV for one narration line, cached by its spoken text and every voice setting.

    Engines: `say` (macOS voices, drafts only: Apple's license limits system voices to
    personal, non-commercial use), `elevenlabs` (ELEVENLABS_API_KEY) and `openai`
    (OPENAI_API_KEY). Keys come from the environment or ~/.env and are never printed.
    """
    spoken = spoken_text(text, settings.get("lexicon") or {})
    engine = settings.get("engine", "say")
    key = hashlib.sha256(f"{narration_identity(settings)}|{spoken}".encode()).hexdigest()[:20]
    wav = cache / f"{key}.wav"
    if not wav.exists():
        cache.mkdir(parents=True, exist_ok=True)
        raw = cache / f"{key}.raw"
        if engine == "say":
            raw = cache / f"{key}.aiff"
            subprocess.run(["say", "-v", settings["voice"], "-r", str(int(settings.get("words_per_minute", 145))),
                            "-o", str(raw), spoken], check=True)
        else:
            synthesize_cloud(engine, spoken, settings, raw)
        ffmpeg(["-i", str(raw), "-ar", "48000", "-ac", "1", str(wav)])
        raw.unlink()
    seconds = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                    "-of", "csv=p=0", str(wav)], capture_output=True, text=True).stdout)
    return wav, seconds


def vtt_time(t: float) -> str:
    h, rem = divmod(max(t, 0.0), 3600)
    m, sec = divmod(rem, 60)
    return f"{int(h):02d}:{int(m):02d}:{sec:06.3f}"


def narration_cues(text: str, start: float, seconds: float) -> list[tuple[float, float, str]]:
    """Split a line into sentence cues, timed in proportion to their length."""
    sentences = [s.strip() for s in re.split(r"(?<=[.])\s+", " ".join(text.split())) if s.strip()]
    total = sum(len(s) for s in sentences) or 1
    cues, t = [], start
    for sentence in sentences:
        span = seconds * len(sentence) / total
        cues.append((t, t + span, sentence))
        t += span
    return cues


def mix_narration(video: Path, clips: list[tuple[Path, float]], length: float, out: Path):
    """Lay each clip at its start time over silence, normalise to -16 LUFS, and mux with the video."""
    inputs = ["-i", str(video)]
    graph, labels = [], []
    for i, (wav, at) in enumerate(clips, start=1):
        inputs += ["-i", str(wav)]
        ms = int(round(at * 1000))
        graph.append(f"[{i}:a]adelay={ms}|{ms}[n{i}]")
        labels.append(f"[n{i}]")
    graph.append(f"{''.join(labels)}amix=inputs={len(labels)}:normalize=0,apad=whole_dur={length:.3f},"
                 f"atrim=0:{length:.3f},loudnorm=I=-16:TP=-1:LRA=11,aresample=48000[a]")
    ffmpeg([*inputs, "-filter_complex", ";".join(graph), "-map", "0:v", "-map", "[a]",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", str(out)])


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
        strings = [beat.get("caption"), beat.get("title"), beat.get("sub"), beat.get("kicker"), beat.get("narration")]
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


# ---------------------------------------------------------------- focus (zoom and highlight)
# Regions are [x, y, w, h] fractions of the footage after crop. A zoom keeps the footage's
# aspect, so it shows the smallest window with equal width and height fractions that holds
# the region. Highlights are placed in the zoomed view, so they must start once the zoom ends.

def zoom_window(zoom: dict) -> tuple[float, float, float]:
    x, y, w, h = zoom["region"]
    wf = max(w, h)
    left = min(max(x + w / 2 - wf / 2, 0.0), 1.0 - wf)
    top = min(max(y + h / 2 - wf / 2, 0.0), 1.0 - wf)
    return left, top, wf


def footage_scaler(beat: dict, fw: int, fh: int, fps: int) -> str:
    """Scale the cropped take to the footage box, with an eased punch-in when `zoom` is set."""
    zoom = beat.get("zoom")
    if not zoom:
        return f"scale={fw}:{fh}:flags=lanczos"
    left, top, wf = zoom_window(zoom)
    at, d = float(zoom["at"]), float(zoom.get("dur", 0.8))
    u = f"clip((on/{fps}-{at})/{d},0,1)"
    ease = f"({u})*({u})*(3-2*({u}))"
    # Upscale first so zoompan's whole-pixel panning does not shimmer.
    return (f"scale={fw * 3}:{fh * 3}:flags=lanczos,"
            f"zoompan=z='1/(1-{1 - wf}*{ease})':x='iw*{left}*{ease}':y='ih*{top}*{ease}'"
            f":d=1:s={fw}x{fh}:fps={fps}")


def highlight_png(beat: dict, hl: dict, size: tuple[int, int], unit: float, brand: dict, path: Path) -> Path:
    """Accent outline around each region, with the rest of the footage washed toward Cream."""
    zoom = beat.get("zoom")
    left, top, wf = zoom_window(zoom) if zoom else (0.0, 0.0, 1.0)
    if zoom and float(hl["at"]) < float(zoom["at"]) + float(zoom.get("dur", 0.8)) - 0.01:
        sys.exit(f"{beat['id']}: a highlight starts before the zoom ends")
    k = 4
    w, h = size[0] * k, size[1] * k
    hexrgb = lambda c: tuple(int(c.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    img = Image.new("RGBA", (w, h), (*hexrgb(brand["colors"]["cream"]), int(255 * hl.get("wash", 0.45))))
    draw = ImageDraw.Draw(img)
    pad, radius, line = 8 * unit * k, 10 * unit * k, 3 * unit * k
    boxes = hl["regions"] if "regions" in hl else [hl["region"]]
    rects = []
    for x, y, bw, bh in boxes:
        x0, y0 = (x - left) / wf * w - pad, (y - top) / wf * h - pad
        x1, y1 = (x + bw - left) / wf * w + pad, (y + bh - top) / wf * h + pad
        rects.append([x0, y0, x1, y1])
        draw.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=(0, 0, 0, 0))
    for r in rects:
        draw.rounded_rectangle(r, radius=radius, outline=(*hexrgb(brand["colors"]["accent"]), 255), width=int(line))
    img.resize(size, Image.LANCZOS).save(path)
    return path


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
        # `segments: [[in, out], ...]` splices parts of the take together (jump cuts over dead
        # time such as a loading spinner); otherwise the beat plays from `in` for `duration`.
        segments = beat.get("segments")
        if segments:
            spliced = sum(b - a for a, b in segments)
            if dur < spliced - 0.05:
                sys.exit(f"{beat['id']}: duration {dur} is shorter than the spliced segments ({spliced:.2f} s)")
            inputs += ["-i", str(take)]
        else:
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
        # A beat longer than its footage holds the last frame (tpad), for example while
        # narration finishes over a panel that has stopped changing.
        hold = f"tpad=stop_mode=clone:stop_duration={dur},"
        if segments:
            parts = []
            for k, (a, b) in enumerate(segments):
                pre.append(f"[0:v]trim=start={a}:end={b},setpts=PTS-STARTPTS[seg{k}]")
                parts.append(f"[seg{k}]")
            pre.append(f"{''.join(parts)}concat=n={len(segments)}:v=1:a=0,fps={fps},{hold}{crop}null[src0]")
        else:
            pre.append(f"[0:v]fps={fps},{hold}{crop}null[src0]")
        # blur: [[x, y, w, h], ...] (fractions of the cropped footage) hides private or
        # distracting parts of the window, such as home-folder paths or unrelated rows.
        src = "src0"
        for k, (bx, by, bw, bh) in enumerate(beat.get("blur", [])):
            x0, y0 = int(src_w * bx) // 2 * 2, int(src_h * by) // 2 * 2
            w0, h0 = max(int(src_w * bw) // 2 * 2, 2), max(int(src_h * bh) // 2 * 2, 2)
            pre.append(f"[{src}]split[ba{k}][bb{k}]")
            pre.append(f"[bb{k}]crop={w0}:{h0}:{x0}:{y0},gblur=sigma=24[bl{k}]")
            pre.append(f"[ba{k}][bl{k}]overlay={x0}:{y0}[src{k + 1}]")
            src = f"src{k + 1}"
        pre.append(f"[{src}]{footage_scaler(beat, fw_, fh_, fps)},format=rgba[foot]")
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

    # highlights: [{at, until?, region | regions, wash?}] draw the eye to one part of the footage.
    foot = "foot"
    for k, hl in enumerate(beat.get("highlights", [])):
        png = highlight_png(beat, hl, (fw_, fh_), layout["unit"], brand, work / f"{beat['id']}-{layout['name']}-hl{k}.png")
        idx = inputs.count("-i")
        inputs += ["-loop", "1", "-framerate", str(fps), "-t", str(dur), "-i", str(png)]
        fades = f"fade=t=in:st={hl['at']}:d=0.35:alpha=1"
        if hl.get("until"):
            fades += f",fade=t=out:st={hl['until']}:d=0.3:alpha=1"
        pre.append(f"[{idx}:v]format=rgba,{fades}[hl{k}]")
        pre.append(f"[{foot}][hl{k}]overlay=0:0:shortest=1[foot{k}]")
        foot = f"foot{k}"
    mask_idx = inputs.count("-i")
    mask = rounded_mask((fw_, fh_), brand["canvas"]["footage_radius"], work / f"{beat['id']}-{layout['name']}-mask.png")
    inputs += ["-loop", "1", "-framerate", str(fps), "-t", str(dur), "-i", str(mask)]
    pre.append(f"[{mask_idx}:v]format=gray[mask]")
    pre.append(f"[{foot}][mask]alphamerge[rounded]")
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
        cap_idx = inputs.count("-i")
        inputs += ["-loop", "1", "-framerate", str(fps), "-t", str(dur), "-i", str(png)]
        pre.append(f"[{cap_idx}:v]format=rgba,fade=t=in:st={start}:d={t['caption_in']}:alpha=1,"
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
    # A beat replays one command (command + output_file) or a session of several, in order.
    session = beat.get("session") or [{"command": beat["command"], "output_file": beat["output_file"],
                                       "max_lines": beat.get("max_lines", 14)}]
    cps = beat.get("type_cps", 42)
    t_type, line_dt = beat.get("start_delay", 0.6), beat.get("line_interval", 0.18)
    states = []  # (history, typed, lines, caret, seconds)
    history = []
    for k, entry in enumerate(session):
        cmd = entry["command"]
        out_lines = (video_dir / entry["output_file"]).read_text().rstrip("\n").splitlines()[: entry.get("max_lines", 14)]
        hist = list(history)
        states.append((hist, "", [], True, t_type if k == 0 else entry.get("pause", 1.2)))
        step = max(1, round(cps / 15))  # redraw 15 times a second while typing
        for i in range(step, len(cmd) + step, step):
            states.append((hist, cmd[:i], [], True, step / cps))
        states.append((hist, cmd, [], False, 0.35))
        for n in range(1, len(out_lines) + 1):
            states.append((hist, cmd, out_lines[:n], False, line_dt))
        history.append({"command": cmd, "output": out_lines})
    total = sum(s[-1] for s in states)
    hold = float(beat.get("in", 0)) + float(beat["duration"]) - total
    states[-1] = (*states[-1][:4], states[-1][4] + max(hold, 0.5))

    listing = work / f"term-{beat['id']}.txt"
    rows = []
    for i, (hist, typed, lines, caret, dur) in enumerate(states):
        png = ov.render(f"term-{beat['id']}-{i:04d}", size, {
            "kind": "terminal", "unit": 2, "title": beat.get("title", ""), "prompt": beat.get("prompt", "$ "),
            "history": hist, "typed": typed, "output": lines, "caret": caret})
        rows.append(f"file '{png}'\nduration {dur:.4f}")
    rows.append(f"file '{png}'")  # concat demuxer needs the last file repeated
    listing.write_text("\n".join(rows) + "\n")
    out = work / f"term-{beat['id']}.mov"
    ffmpeg(["-f", "concat", "-safe", "0", "-i", str(listing), "-vf", f"fps={fps},format=yuv420p", *ENCODE, str(out)])
    return out


def render_document(beat, video_dir: Path, ov: Overlays, work: Path, fps: int) -> Path:
    """Show real exported files as pages, one after another, each for an equal share of the beat."""
    size = (2880, 1620)
    pages = beat["pages"]
    share = (float(beat.get("in", 0)) + float(beat["duration"])) / len(pages)
    rows = []
    for i, page in enumerate(pages):
        lines = (video_dir / page["file"]).read_text().splitlines()
        lines = lines[page.get("from", 1) - 1: page.get("to", len(lines))]
        if page.get("style", "prose") == "prose":
            lines = [l for l in lines if l.strip()]
        png = ov.render(f"doc-{beat['id']}-{i}", size, {"kind": "document", "unit": 2, "title": page.get("title", ""),
                                                        "style": page.get("style", "prose"), "lines": lines})
        rows.append(f"file '{png}'\nduration {share:.4f}")
    rows.append(f"file '{png}'")
    listing = work / f"doc-{beat['id']}.txt"
    listing.write_text("\n".join(rows) + "\n")
    out = work / f"doc-{beat['id']}.mov"
    ffmpeg(["-f", "concat", "-safe", "0", "-i", str(listing), "-vf", f"fps={fps},format=yuv420p", *ENCODE, str(out)])
    return out


def join(segments: list[tuple[Path, float, str]], xfade: float, out: Path, fps: int, metadata: dict[str, str] | None = None):
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
    tags = sum((["-metadata", f"{k}={v}"] for k, v in (metadata or {}).items()), [])
    ffmpeg([*inputs, "-filter_complex", ";".join(graph), "-map", cur, *ENCODE, "-r", str(fps), *tags, "-movflags", "+faststart", str(out)])
    return length


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video", type=Path, nargs="?")
    ap.add_argument("--status", action="store_true", help="list each video's filmed version against the current app")
    ap.add_argument("--draft-voice", help="narrate with this installed voice instead of the spec's (drafts only)")
    ap.add_argument("--only", choices=list(LAYOUTS))
    ap.add_argument("--lint-only", action="store_true")
    args = ap.parse_args()
    if args.status:
        print_status()
        return
    if not args.video:
        ap.error("give a video.yaml, or --status")

    video_dir = args.video.resolve().parent
    cfg = yaml.safe_load(args.video.read_text())
    brand = json.loads((SHARED / "brand.json").read_text())
    fps = brand["canvas"]["fps"]

    spec_problems = validate_spec(cfg)
    if spec_problems:
        print("The video spec is incomplete:")
        print("\n".join(f"  {p}" for p in spec_problems))
        sys.exit(1)
    for beat in cfg["beats"]:
        for line in beat.get("lines", []):
            line["text"] = line["text"].replace("{filmed_with}", filmed_with_text(cfg))

    problems = lint_text(cfg["beats"])
    if problems:
        print("On-screen text breaks the prose rules:")
        print("\n".join(f"  {p}" for p in problems))
        sys.exit(1)
    if args.lint_only:
        print("lint: no issues found")
        return

    # Narration: synthesise every line first, so each beat can be lengthened to fit its words.
    narration = narration_settings(cfg)
    spoken: dict[str, tuple[Path, float]] = {}
    if narration:
        if args.draft_voice:
            narration = {**narration, "engine": "say", "voice": args.draft_voice}
            print(f"draft narration with {args.draft_voice}, not the spec's voice")
        if narration.get("engine", "say") == "say" and narration["voice"] not in installed_voices():
            sys.exit(f"voice '{narration['voice']}' is not installed. Download it in System Settings > Accessibility > "
                     "Read & Speak > System voice > Manage Voices, or render a draft with --draft-voice.")
        lead, tail = float(narration.get("lead", 0.5)), float(narration.get("tail", 0.6))
        for beat in cfg["beats"]:
            if not beat.get("narration"):
                continue
            wav, seconds = synthesize(beat["narration"], narration, video_dir / ".narration")
            spoken[beat["id"]] = (wav, seconds)
            need = round(lead + seconds + tail, 2)
            if float(beat["duration"]) < need:
                print(f"  {beat['id']}: lengthened to {need} s for its narration ({float(beat['duration'])} s in the spec)")
                beat["duration"] = need

    out_dir = video_dir / "out"
    work = video_dir / ".work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    out_dir.mkdir(exist_ok=True)

    missing = [b["id"] for b in cfg["beats"] if b["kind"] == "take" and not (video_dir / b["take"]).exists()]
    missing += [b["id"] for b in cfg["beats"] if b["kind"] == "terminal" and not all(
        (video_dir / e["output_file"]).exists() for e in (b.get("session") or [b]))]
    if missing:
        print(f"placeholders for uncaptured takes: {', '.join(missing)}")

    ov = Overlays(work)
    terminals: dict[str, Path] = {}
    try:
        for name in [args.only] if args.only else cfg.get("outputs", ["wide"]):
            layout = {**LAYOUTS[name], "name": name}
            segments = []
            starts, t = [], 0.0
            for beat in cfg["beats"]:
                starts.append(t)
                t += float(beat["duration"]) - (brand["timing"]["crossfade"] if beat.get("transition") == "fade" else 0.0)
            for i, beat in enumerate(cfg["beats"]):
                seg = work / f"{i:02d}-{beat['id']}-{name}.mp4"
                print(f"[{name}] {beat['id']}")
                if beat["kind"] == "card":
                    render_card(beat, layout, ov, work, fps, seg)
                elif beat["kind"] == "document":
                    if beat["id"] not in terminals:
                        terminals[beat["id"]] = render_document(beat, video_dir, ov, work, fps)
                    render_take({**beat, "take": str(terminals[beat["id"]]), "trim_top": 0}, cfg, layout, brand, ov, video_dir, work, fps, seg)
                elif beat["kind"] == "terminal" and not all((video_dir / e["output_file"]).exists() for e in (beat.get("session") or [beat])):
                    render_take({**beat, "take": "missing"}, cfg, layout, brand, ov, video_dir, work, fps, seg)
                elif beat["kind"] == "terminal":
                    if beat["id"] not in terminals:
                        terminals[beat["id"]] = render_terminal(beat, video_dir, ov, work, fps)
                    render_take({**beat, "take": str(terminals[beat["id"]]), "trim_top": 0}, cfg, layout, brand, ov, video_dir, work, fps, seg)
                else:
                    render_take(beat, cfg, layout, brand, ov, video_dir, work, fps, seg)
                segments.append((seg, float(beat["duration"]), beat.get("transition", "cut")))
            final = out_dir / f"{cfg['slug']}-{name}.mp4"
            silent = work / f"silent-{name}.mp4" if spoken else final
            length = join(segments, brand["timing"]["crossfade"], silent, fps, metadata={
                "title": cfg["title"],
                "comment": f"{filmed_with_text(cfg)}. Spec: screencasts/{video_dir.name}/video.yaml",
            })
            if spoken:
                lead = float(narration.get("lead", 0.5))
                clips, cues, transcript = [], [], [f"# {cfg['title']}", "", f"{filmed_with_text(cfg)}. The narration is a synthetic voice.", ""]
                for beat, start in zip(cfg["beats"], starts):
                    if beat["id"] in spoken:
                        wav, seconds = spoken[beat["id"]]
                        clips.append((wav, start + lead))
                        cues += narration_cues(beat["narration"], start + lead, seconds)
                        transcript += [" ".join(beat["narration"].split()), ""]
                mix_narration(silent, clips, length, final)
                vtt = ["WEBVTT", ""] + [f"{vtt_time(a)} --> {vtt_time(b)}\n{text}\n" for a, b, text in cues]
                (out_dir / f"{cfg['slug']}-{name}.vtt").write_text("\n".join(vtt))
                (out_dir / f"{cfg['slug']}-transcript.md").write_text("\n".join(transcript))
            poster = out_dir / f"{cfg['slug']}-{name}-poster.png"
            ffmpeg(["-ss", "1.6", "-i", str(final), "-frames:v", "1", str(poster)])
            shown = final.relative_to(REPO) if final.is_relative_to(REPO) else final
            print(f"wrote {shown} ({length:.1f}s) and poster")
    finally:
        ov.close()


if __name__ == "__main__":
    main()
