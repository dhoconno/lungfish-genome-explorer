# Screencast checklist

Copy this list into the plan for a new video, or into a feedback round on an existing one, and tick each box as it is done. The reasons behind every box are in `docs/contracts/SCREENCASTS.md`. A box that does not apply gets a one-line reason instead of a tick.

## Spec

- [ ] `video.yaml` started from `screencasts/_shared/video-template.yaml`, with purpose, audience, setup, honesty and a `site` entry.
- [ ] Every beat has `shows`, `capture` and `verify`. Every caption is 4 to 9 words.
- [ ] `python3 screencasts/render.py screencasts/<slug>/video.yaml --lint-only` passes.

## Narration (learner videos)

- [ ] The narration engine is `elevenlabs` with the voice in `VOICES.md`, not `say`.
- [ ] A domain expert listed the spoken form of every abbreviation, accession, unit, genotype and lone base letter, and each is in the lexicon.
- [ ] Every narration claim fits the spec's `honesty` limits.
- [ ] No beat holds a frozen frame for long because its line outruns the footage.

## Footage

- [ ] Filmed from a released build, named in `filmed_with`.
- [ ] Every `verify` fact checked on screen.
- [ ] The contact sheet shows no home-folder paths, personal accounts or unrelated rows.

## Review and publishing

- [ ] The owner reviewed the render, and every comment is a row in `feedback.md`.
- [ ] `python3 screencasts/publish.py screencasts/<slug>/video.yaml --yes` ran, and its rows in `feedback.md` say published.
- [ ] Raw takes are in the internal LabKey area and listed in `large-files.tsv`.
- [ ] `python3 screencasts/publish.py --check` passes, the commit holds the video folder and `docs/site`, and `main` is pushed.
