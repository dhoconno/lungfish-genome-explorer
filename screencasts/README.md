# LGE quick videos

Short, silent, captioned screencasts. Some show one function or application. Others, like 01, show what sets the app apart. Each video is one folder with a `video.yaml` and its takes.

```
screencasts/
  render.py                 video.yaml -> out/<slug>-wide.mp4, -square.mp4, posters
  _shared/brand.json        palette, canvas, timing tokens
  _shared/templates/        overlay.html (cards, lower thirds, placeholders, click rings)
  _shared/fonts/            Space Grotesk, Inter, IBM Plex Mono (OFL, licences alongside)
  _shared/capture/wincap.swift   single-window ScreenCaptureKit recorder
  01-lge-overview/          video.yaml, PROPOSAL.md, takes/ (not committed), out/ (not committed)
```

## Footage rule (binding, owner 2026-10-01)

Every beat shows the app itself, filmed from a released Lungfish build. The only exception is a beat whose point is a command-line feature, for example that every app feature is backed by `lungfish-cli`; such a beat may replay a real CLI session and must say so in its kicker. Never substitute a CLI replay, Finder, a text editor, or a rendered file page for something the app can show. If a surface cannot be filmed in the background (panels and sheets that only draw while the app is frontmost), film it with the owner present rather than working around it.

## Style

- Brand fonts and palette from the Lungfish style guide, with the app's own orange `#D47B3A` as the accent so cards match the footage.
- Captions are 4 to 9 words, sentence case, and follow the manual's prose rules (no em dashes, semicolons, mid-sentence colons, `!`, `?`, or words on `ai-tells-words.txt`). `render.py` refuses to render text that breaks them.
- No voiceover and no music by default. Cards and captions carry the story in silent autoplay.
- Never name another product on screen. Say "recorded" rather than "reproducible".

## Making a video

1. Copy a demo project into `~/Desktop/lge-docs/screencast/` and open it in the app. Set the window to 1440x810 points.
2. Build the recorder once, then find the window.
   ```bash
   swiftc -O -parse-as-library -swift-version 5 -o screencasts/.bin/wincap screencasts/_shared/capture/wincap.swift
   screencasts/.bin/wincap --list Lungfish
   ```
3. Record one take per beat while driving the app, then trim with `in` and `duration` in `video.yaml`.
   ```bash
   screencasts/.bin/wincap --window <id> --out screencasts/<slug>/takes/<beat>.mov --seconds 10
   ```
4. Render. Takes that do not exist yet render as labelled placeholders, so timing can be settled before capture.
   ```bash
   python3 screencasts/render.py screencasts/<slug>/video.yaml
   ```

The recorder only ever captures the window it is given. Never record the full screen.

Rendering needs Python with `playwright` (Chromium), `PyYAML` and `Pillow`, plus Homebrew `ffmpeg`.
