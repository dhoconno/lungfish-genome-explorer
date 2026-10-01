# Video 01 v2: longer overview, filmed on Lungfish Preview (plan, 2026-09-30)

Owner request: re-film from Lungfish Preview (not the debug build) after the next Preview release, let it run longer, and add running workflows in containers and Nextflow, saving disk by clumping and quality binning FASTQ, and an easy start for learners with real data including SRA.

Target about 75 to 80 s. Same brand system, silent, captioned. Facts verified 2026-09-30 (research notes in the session).

| # | Beat | On screen | Caption | Kicker |
|---|---|---|---|---|
| 1 | Title | card | Lungfish Genome Explorer / Sequence analysis, native to the Mac | |
| 2 | Learn with real data | Help > Demo Projects sheet listing the ten projects | Start with real public datasets | Help · Demo Projects |
| 3 | SRA | Tools > Search Online Databases > Search SRA, a search for SRR36291587 with its row (21 MB, Illumina, paired) | Search SRA and download runs into a project | Tools · Search Online Databases |
| 4 | Disk | Inspector for the imported HG002 FASTQ bundle in "FASTQ storage.lungfish" (clumped, Illumina 7-level binning) | Clump reads and bin qualities to save space | HG002 reads · 18.0 MB stored as 5.8 MB |
| 5 | Viewer | existing choreography (overview, 3 kb, read pileup) | Reads, alignments and variants in one window | HG002 · chr20 |
| 6 | Pipelines | completed Viral Recon result (SARS-CoV-2 Amplicons copy, viralrecon-2026-09-30T08-44-43): result viewport or Operations entry | Run nf-core pipelines in Docker containers | Viral Recon · Nextflow · Docker |
| 7 | Provenance | existing choreography (Provenance tab, lineage, command) | Each result records its tool, version and command | Inspector · Provenance · Lineage |
| 8 | Folder | Finder on the minimap2 result folder (cropped) | Your project is a folder of standard files | Finder · Analyses/minimap2 |
| 9 | Export | real Methods paragraph and Snakefile rule from the new Preview | Export the history as a script or methods text | File · Export · Provenance |
| 10 | Terminal | real lungfish-cli variants call, re-run with the Preview CLI | The same analysis from the app or terminal | lungfish-cli |
| 11 | End card | | Free and open source, MIT license / For Apple Silicon Macs running macOS 26 / URLs | |

Honesty rules for the new beats:
- Quality binning is lossy and off by default. The kicker states the measured numbers for this dataset only, never a general percentage.
- SRA and demo downloads need a network connection (not claimed otherwise).
- Viral Recon and TaxTriage need Docker Desktop. The caption names Docker. Never say Apple containers.
- Pipelines are filmed from completed results; the video does not imply a pipeline finishes in seconds.

Filming: Lungfish Preview from /Applications after installing the new release, driven by axdrive and recorded by wincap (window only). Work on copies under ~/Desktop/lge-docs/screencast/. No computer-use prompts while the owner is away.
