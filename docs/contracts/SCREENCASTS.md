# Screencasts

This contract covers the short videos about Lungfish Genome Explorer (LGE) in `screencasts/`. Read it before you make a new video, change an existing one after review, or publish one to the website. The spec reference (every key in `video.yaml`) is `screencasts/README.md`. The voice decision and its licensing are in `screencasts/VOICES.md`. The checklist to copy into a plan is `docs/contracts/screencast-checklist.md`.

## What a video is made of

| File | Holds | Committed |
|---|---|---|
| `screencasts/<slug>/video.yaml` | The whole recipe, from purpose, setup and honesty limits to every beat with its take, timing, zoom, caption and narration | yes |
| `screencasts/<slug>/feedback.md` | Every piece of human feedback and what was done about it | yes |
| `screencasts/<slug>/captions.vtt`, `transcript.md` | The captions and transcript of the published render | yes, written by `publish.py` |
| `screencasts/<slug>/published.yaml` | Length, checksums and voice of the published render | yes, written by `publish.py` |
| `screencasts/<slug>/large-files.tsv` | Every file stored in the LabKey folders for this video | yes |
| `screencasts/<slug>/takes/` | Raw window recordings | no, internal LabKey area |
| `screencasts/<slug>/out/` | Renders, posters, contact sheets and render fingerprints | no |
| `docs/site/videos.qmd`, `docs/site/videos/<slug>.vtt` | The Videos page and its caption tracks | yes, generated |
| `docs/site/index.qmd`, between `videos:begin` and `videos:end` | The video list at the bottom of the home page, where most visitors land | yes, generated (the rest of the page is hand-written) |

Shared pieces live in `screencasts/_shared/`. These are the brand tokens, the overlay templates, the window recorder, `site.yaml` (page intro and section order) and `video-template.yaml` (a commented spec to copy).

## Binding rules

| Rule | What it means |
|---|---|
| App footage only | Every beat shows the app, filmed from a released build. A command-line replay is allowed only in a beat about a command-line feature, and the beat says so. Surfaces that only draw while LGE is frontmost are filmed with the owner present. |
| Never film a claim the output does not support | Each spec lists `honesty` limits. Re-read them before every remake and every narration change. |
| Licensed voice for anything public | `engine: say` is for drafts. Published narration uses ElevenLabs with the voice Matilda (`VOICES.md`). `publish.py` refuses a draft voice. |
| Spoken forms come from the lexicon | Abbreviations, accessions, units, genotypes and lone base letters are rewritten in `narration.lexicon`, never misspelled in the narration text. See Pronunciation. |
| Prose rules everywhere | Captions, narration and page text follow the documentation prose rules. `render.py` lints every on-screen and spoken string. |
| Public area holds the current cut only | One wide render and one poster per video, overwritten in place. Scan the contact sheet for home-folder paths and unrelated rows before publishing. |
| The pages are generated | Never edit `docs/site/videos.qmd` or the home page video list by hand. Change `site.yaml` or the spec and run `publish.py --page`. |

## Making a new video

1. Pick the video from `screencasts/CATALOGUE.md` or agree a new one with the owner. Copy `screencasts/_shared/video-template.yaml` to `screencasts/<slug>/video.yaml` and fill in purpose, audience, honesty, setup and the `site` entry.
2. Write every beat with `shows`, `capture`, `verify`, a caption of 4 to 9 words and, for a narrated video, the narration line. Render with no takes. Missing takes render as labelled placeholders, so timing and narration can be settled first.
3. Have the narration read by a domain expert and a reader at the audience's level. Ask the expert for the spoken form of every abbreviation and add it to the lexicon.
4. Install the release to film from, recreate the setup projects, and record each take with `wincap` as `capture` says (README, Making a video). Check every `verify` fact on screen.
5. Render and review the contact sheet and the full video. Send the render to the owner, log their comments in `feedback.md`, and publish once they approve (see Publishing).

## Changing a video after feedback

Log each comment in `screencasts/<slug>/feedback.md` before changing anything. Keep one row per comment, with the time in the video it refers to.

```markdown
# Feedback on <slug>

| # | Date | From | At | Comment | Change | Status |
|---|---|---|---|---|---|---|
| 1 | 2026-10-03 | owner | 0:42 | "kb" sounds like letters | lexicon `500 kb slice` | published 2026-10-03 |
```

Status is one of open, changed (rendered, not yet published), published with a date, or declined with a reason. Then make the smallest change that answers the comment.

| Feedback about | Edit | Re-film | Re-render | Re-publish |
|---|---|---|---|---|
| How a word is said | `narration.lexicon` (a phrase key if the word is said differently in different places) | no | yes, only changed lines call the voice again | yes |
| What the narrator says | the beat's `narration`, then re-check `honesty` | no | yes | yes |
| Caption or card text | `caption`, `title`, `sub` or `lines` | no | yes | yes |
| Pace, a frozen frame, framing | `in`, `duration`, `zoom`, `crop`, `highlights`, `blur` | no | yes | yes |
| Voice or delivery overall | `narration` settings in every learner spec, and `VOICES.md` | no | yes, every line | yes |
| Wrong or outdated app footage | re-film the beat as its `capture` says, update `filmed_with` | yes | yes | yes |
| Page wording or order | `site.summary`, `site.heading`, `site.section`, `_shared/site.yaml` | no | no | `publish.py --page` |

A narrated beat grows to fit its line, and the picture holds its last frame until the line ends. When narration outruns the footage by more than a few seconds, record a longer take or shorten the line rather than leaving a long frozen frame.

## Pronunciation

The lexicon replaces a key with its spoken form wherever the key stands as a whole token. Longest keys go first and case matters. It changes only what the voice reads. Captions and transcripts keep the written form.

1. Spell letters out with spaces (`HBB: H B B`, `NCBI: N C B I`). Say the digits of an accession as they appear on screen.
2. Use a phrase key when one abbreviation needs different forms in different sentences (`"500 kb slice": 500 kilobase slice`).
3. A lone base letter read as a word sounds like the article "a". Fix it with a phrase key that adds what a lecturer would say (`"carry A": carry an A`).
4. Listen to every changed line after rendering. Use an ElevenLabs pronunciation dictionary only when respelling fails, and pin its version.

## Publishing

```bash
python3 screencasts/render.py screencasts/<slug>/video.yaml
python3 screencasts/publish.py screencasts/<slug>/video.yaml          # checks and writes out/<slug>-contact.png
python3 screencasts/publish.py screencasts/<slug>/video.yaml --yes    # uploads and updates the repository files
```

The dry run refuses a render made from a different spec or from re-filmed takes (it compares the fingerprint `render.py` writes beside each render), a render made with a draft voice, a spec without a `site` entry, and page text that breaks the prose rules. Review the contact sheet before `--yes`. With `--yes` the script uploads the render and poster over the public copies, checks an anonymous download byte for byte, and rewrites `published.yaml`, `large-files.tsv`, the captions, the transcript, the Videos page and the home page video list. Raw takes go to the internal area separately with `scripts/lge-files/lge-files.sh --internal sync`.

Commit the video folder and `docs/site`, then push `main`. The site workflow redeploys when `docs/site` changes. Until it does, the new render plays with the old caption timings, so publish and push in one sitting.

## How this contract is kept honest

`python3 screencasts/publish.py --check` runs in the pre-push hook. It fails when the Videos page or the home page video list is not what the specs generate, when a site caption track differs from the video's `captions.vtt` or belongs to no published video, when `large-files.tsv` has no public row with the published checksums, or when a published video used the draft voice. It reads the working tree, so commit every file `publish.py` wrote before pushing.
