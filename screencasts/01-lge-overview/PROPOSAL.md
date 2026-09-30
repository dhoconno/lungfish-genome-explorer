# Quick video 01: LGE overview (proposal, pending owner answers)

Panel: bench genomics scientist, competitive analyst, screencast producer, brand copy editor.

## Consensus

- Lead with **recorded provenance on standard files**. All four panelists independently put it first. It is the one contrast with Geneious, IGV, CLC and SnapGene that an expert cannot dismiss, and it is honest against Galaxy (LGE does it locally, on a plain folder, and exports engine-neutral scripts).
- Never name a competitor on screen. Let the footage make the comparison.
- Say "recorded" and "exportable", never "reproducible". Do not lead with "free" or "native" (IGV, UGENE and Galaxy are free, and Geneious is now native ARM64).
- Keep out: Docker-backed pipelines (Viral Recon, TaxTriage), GATK, Freyja, the AI assistant, AI haplotyping, feature counts, prices.
- Silent, captioned, no voiceover. Human data (HG002, chr20), not viral.

## Storyboard (45 s, 1920x1080 60 fps, plus a 1080x1080 cut)

Anchor project: **Human Mapping and Variants (with results)**.

| Time | On screen | Caption |
|---|---|---|
| 0.0–2.5 | Title card, Deep Ink, Creamsicle bar | Lungfish Genome Explorer / Sequence analysis, native to the Mac |
| 2.5–10 | chr20 pileup, click a variant row, viewport recentres | Reads, alignments and variants in one window |
| 10–17 | Finder beside the app, `Analyses/minimap2-…/HG002.sorted.bam` | Your project is a folder of standard files |
| 17–26 | Inspector > Provenance > Lineage, bcftools step expanded (command + conda build) | Each result records its tool, version and command |
| 26–33 | File > Export > Methods Section paragraph, then Snakemake export | Export the history as a script or methods text |
| 33–40 | Operations panel row > Copy CLI Command, same step in a terminal | The same analysis from the app or terminal |
| 40–45 | End card | Free and open source for Apple Silicon Macs / github.com/dhoconno/lungfish-genome-explorer / manual URL |

## Production system (reusable for the series)

- `screencasts/<slug>/video.yaml` (build, fixture project, window size, beats with take, in/out, caption, punch-in rect, square focus rect).
- `screencasts/_shared/brand.json` + HTML/CSS templates for title, lower third, end card, click ring. Brand fonts (OFL woff2) committed so renders are deterministic.
- Overlays rendered to transparent PNG with headless Chrome (this Mac's ffmpeg lacks `drawtext`), composited with ffmpeg `overlay`/`fade`.
- Capture: Preview build launched by path, window fixed at 1440x810 pt, window-only `screencapture -v -l <id>`, one take per beat, synthetic Creamsicle click rings instead of the system cursor.
- Captions pass the manual prose lint before render.
