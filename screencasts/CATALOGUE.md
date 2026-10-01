# Quick video catalogue (proposal, 2026-10-01)

Brainstormed by a four-expert panel (bioinformatics educator, competitive analyst, CLI-first genomics researcher, series producer). Every video follows the footage rule in README.md: in-app footage only, CLI replays only in videos about a CLI feature. Nothing here is filmed until its claims are checked against the released Preview.

## Series structure

- Folders `<track><nn>-<slug>/`: **B** beginners and learners, **S** switching from other apps, **C** command-line users. `01-lge-overview` stays the unprefixed flagship.
- Lengths: B 45 to 75 s (4 to 6 beats), S 30 to 60 s (one familiar task each), C 30 to 60 s.
- Every `video.yaml` gains `manual:` (chapter id) and `demo:` (demo project) keys, and each manual chapter lists its videos, so they link both ways.
- Shared 2 s title card naming the track and a 3 s end card naming the manual chapter and demo project.
- Publish: wide MP4 and poster embedded in the matching Read the Docs chapter (from the media repo pinned per release), a grid on the site, 01 only in the README, new videos listed in release notes, square cuts for social posts.

## B: beginners and learners (ranked)

| # | Video | Demo project | Beats (on screen) | Chapter |
|---|---|---|---|---|
| B01 | Your first project | Human Mapping and Variants (with results) | Help > Demo Projects, Download & Open; sidebar groups; select the reads to see the Inspector; Operations panel; results under Analyses | 01-foundations/06 |
| B02 | Find the sickle cell codon | Genes and Sequences (human beta-globin, NG_000007.3) | Go to Location to NG_000007:70613-70615; the GAG codon; Translate overlay; add an annotation | 02-sequences/01 |
| B03 | Reading a read pileup | Human Mapping and Variants (with results) | coverage curve and hover depth; zoom to bases; sort reads by base; the matching called variant | 04-alignments/02, 05-variants/02 |
| B04 | Is my sequencing run any good | Human Reads | summary cards; Mean Q and Q20; open a chart full size; Refresh QC Summary | 03-reads/03 |
| B05 | Build a primate family tree | Genes and Sequences (five primate mitogenomes) | MAFFT alignment; Build Tree with IQ-TREE; root on the macaques | 02-sequences/04, 05 |
| B06 | Design PCR primers for a macaque gene | Primer Design (Mamu-A1) | Primer3 on one allele with a target region; candidate pairs | 10-primer-design/02 |

## S: switching from other apps

Never name another product on screen. Each video shows where a familiar task lives in LGE.

| # | Video | Demo project | Beats |
|---|---|---|---|
| S01 | Open a GenBank record and annotate it | Genes and Sequences | Import Center drop; features with the record; Go to Gene; Translate; Add Annotation; export FASTA, GenBank or GFF3 |
| S02 | Align sequences with MAFFT | Genes and Sequences (primate mito) | select rows; Tools > Multiple Sequence Alignment > MAFFT; Operations log; Variable Sites; pairwise identity; export PHYLIP, NEXUS or Clustal |
| S03 | Build and root a tree | same alignment | IQ-TREE with model test and bootstrap; support colouring; Root on Selected Branch; extract a clade |
| S04 | Map reads and call variants | Human Mapping and Variants (with results) | Tools > Mapping; pileup; Tools > Call Variants (bcftools or LoFreq); click a variant; provenance |
| S05 | Assemble reads de novo | Long Reads and Assembly | Tools > Assembly; assembler choice; contig table and Nx; open a contig |
| S06 | Design PCR primers | Primer Design | MAFFT then Primer3; binding inspection; order sheet |

Not yet: cloning and plasmid maps, Sanger chromatograms, general BLAST of any sequence, importing other apps' files, the visual workflow builder (experimental), GATK, in-place sequence editing.

## C: command-line users

| # | Video | Point | CLI shown? |
|---|---|---|---|
| C01 | Copy the command that ran | Operations log and Copy CLI Command; each provenance step keeps command, version and exit status | no |
| C02 | Terminal first, app second | `lungfish-cli map` and `variants call` write into the open project, the app shows the results | yes (real session) |
| C03 | Export the history as a pipeline | File > Export > Provenance: methods text, Nextflow and Snakemake, each read in the viewer; optional `provenance export` and `provenance bibliography` tail | optional tail |
| C04 | Tools are pinned conda builds | Plugin Manager packs and environments; provenance names the exact package build | optional tail |
| C05 | Fast visual QC of BAM and VCF | chromosome to pileup; variant row to its reads; table filters; alignment stats | no |
| C06 | Run nf-core Viral Recon from the app | wizard; live log; Copy CLI Command; completed result (names Docker) | no |

Deferred: pointing coding agents at a project (owner said its own later video), RAM accounting from `ops stats` (prints "Peak RAM unknown"), the AI Assistant (needs the user's API key).

## Checks before filming (flagged by the panel)

- Is the IQ-TREE "Build Tree" item really in the app's context menu? (features.yaml lists only CLI entry points.)
- Does a result written by `lungfish-cli` appear in the sidebar of an already open project?
- features.yaml says eight demo projects (the manifest has ten) and lists the Viral Recon entry point as Tools > Multiple Sequence Alignment.
- MAFFT, IQ-TREE and Primer3 may need plugin packs installed first.
- The MHC genotyping demo is simulated data, so it stays out of the learner track.

## Tooling to build for the series

- Menu capture (open menus are not filmed by wincap today).
- `setup-demo.sh <demo> <slug>`: fetch, copy, open, size the window, print the window id.
- An attended-beat queue so one short session with the owner films every sheet, panel and alert of a release.
- A path-leak check that scans frames for `/Users/` before encoding.
- A `poster_beat:` key, shared card templates, and click rings from axdrive press coordinates.

## Questions for the owner

1. Host videos only in the media repo and Read the Docs, or also on a video platform for discoverability?
2. May switcher captions allude to other apps without naming them (for example "Where your alignment view lives")?
3. When a release changes the UI, pull a stale video until it is re-filmed, or label it "as of version X"?
