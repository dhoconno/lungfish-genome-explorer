# LGE quick videos

Short, captioned screencasts. Some show one function or application. Others, like 01, show what sets the app apart. Each video is one folder with a `video.yaml` and its takes. The `video.yaml` is the whole recipe, so any video can be remade against a newer app version.

```
screencasts/
  render.py                 video.yaml -> out/<slug>-wide.mp4, -square.mp4, posters
  _shared/brand.json        palette, canvas, timing tokens
  _shared/templates/        overlay.html (cards, lower thirds, placeholders, click rings)
  _shared/fonts/            Space Grotesk, Inter, IBM Plex Mono (OFL, licences alongside)
  _shared/capture/wincap.swift   single-window ScreenCaptureKit recorder
  01-lge-overview/          video.yaml, drive-v2/ (axdrive steps), terminal-v2/, takes-v2/ and out/ (not committed)
```

## The video spec

Every `video.yaml` records what the video is for, what it was filmed with, and how to film each beat again. `render.py` refuses a spec without these keys.

| Key | What it holds |
|---|---|
| `slug`, `title`, `track`, `purpose`, `audience` | What the video is and who it is for. `purpose` is the brief a remake has to meet. |
| `filmed_with` | `app` (for example Lungfish Preview), `versions` (every release a take was filmed on) and `date`. A beat filmed on a different release sets its own `filmed_with`. |
| `setup` | The window size and each project the takes need, with where it came from (a demo project, or the steps that built it). |
| `honesty` | Claims the video must not overstate. Re-read before every remake. |
| `narration` | `none`, or the voice settings for a narrated video (see Narration). |
| per beat `shows` | What the beat demonstrates, in words that stay true when the UI changes. |
| per beat `capture` | How to film the take again: the axdrive file, or the steps for an attended take. |
| per beat `verify` | Facts on screen to re-check on a new version, such as sizes, labels or version strings. |
| per beat `narration` | The spoken line for a narrated video. The beat is lengthened to fit it. |
| per beat `zoom`, `highlights` | An eased punch-in to a region, and accent outlines around the items that matter. |
| per beat `blur` | Regions of the footage to blur, for home-folder paths or rows from unrelated work. |

A beat longer than its footage holds the last frame. Narrated renders also write `<slug>-wide.vtt` and `<slug>-transcript.md`. Copy both next to the spec as `captions.vtt` and `transcript.md`, since caption tracks are served beside the page that embeds the video. `--draft-voice <name>` renders a draft with another installed voice.

The version tag is written three ways: in `filmed_with`, in the MP4's title and comment metadata, and as a small "Filmed with ..." line on the end card (write `"{filmed_with}"` as a card line with `style: version`). The public render keeps its plain name. Its row in `large-files.tsv` names the version too.

### Remaking a video

1. `python3 screencasts/render.py --status` lists every video with the versions it was filmed on and whether it is behind the current app.
2. Install the release to film from, then recreate the `setup` projects.
3. Re-film each beat as its `capture` says, check every `verify` fact, and adjust `in`, `duration`, `zoom` and `highlights` to the new takes.
4. Update `filmed_with`, render, review a frame per second, then replace the public render and update `large-files.tsv`.

## Footage rule (binding, owner 2026-10-01)

Every beat shows the app itself, filmed from a released Lungfish build. The only exception is a beat whose point is a command-line feature, for example that every app feature is backed by `lungfish-cli`; such a beat may replay a real CLI session and must say so in its kicker. Never substitute a CLI replay, Finder, a text editor, or a rendered file page for something the app can show. Installing LGE happens before the app exists on the Mac, so the install video (B00) films the website, the disk image window and the Applications folder, and its spec says so under `footage_exception`. If a surface cannot be filmed in the background (panels and sheets that only draw while the app is frontmost), film it with the owner present rather than working around it.

## Storage

Renders, posters and raw takes are not committed. The public LGE LabKey folder holds only the current wide render of each video, `screencasts/<slug>/renders/<slug>.mp4`, and its poster. Raw takes go to the internal folder (`--internal`). Use `scripts/lge-files/lge-files.sh` (contract: `docs/development/large-files.md`); each video's `large-files.tsv` lists what is stored with size, SHA-256 and URL. Videos render wide only (`outputs: [wide]`).

## Style

- Brand fonts and palette from the Lungfish style guide, with the app's own orange `#D47B3A` as the accent so cards match the footage.
- Captions are 4 to 9 words, sentence case, and follow the manual's prose rules (no em dashes, semicolons, mid-sentence colons, `!`, `?`, or words on `ai-tells-words.txt`). `render.py` refuses to render text that breaks them.
- No music. Overview and social videos stay silent, with captions carrying the story in muted autoplay.
- Tutorial videos (the B track, starting with B01) are narrated with an on-device Apple Premium voice (owner and focus group, 2026-10-01). Captions stay on every video. The burned-in caption is the short takeaway, and the narration adds one clause of context. The narration names each control by its label and says what happens, so it also serves as audio description. It never says "click here" or relies on the orange outline alone. Pace is about 2.4 words per second, with a short pause after each zoom lands, and loudness is -16 LUFS.
- A narrated video ships a WebVTT captions track and a transcript generated from the same spec, and the page says the voice is synthetic.
- Zoom in with `zoom` and outline the item that matters with `highlights` whenever a detail is too small to read at full window size.
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
