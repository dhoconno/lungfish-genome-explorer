# Docs refresh, the user manual brought up to Phases 1 to 5

Plan of the docs-refresh job for the Lungfish Genome Explorer (LGE) user manual, written 2026-11-21. Program worktree `.claude/worktrees/sc-embed-plan-847ab2`, branch `claude/docs-refresh-2a62c1`, base `e62b1dd62` on that branch, where every repo citation below was read. The branch's `features.yaml` refresh and `ARCHITECTURE.md` scopes reach main with the first chapter batch, since `docs/user-manual` needs unit-tier evidence and this plan does not. SCR is `~/lungfish-phase-records/docs-refresh/`, which holds the inventories, briefs, lane reports, decision logs and pilot results. This is a documentation job. The plan shape of `docs/contracts/SCOPE-AND-DELIVERY.md:44-49` binds, and its lane rules for code do not.

## Pick-up for the next session (written 2026-11-26)

The docs-refresh session that wrote this plan has ended, and its worktree is archived. This section stands alone. It points only at main and at the records folder SCR, `~/lungfish-phase-records/docs-refresh/`. A fresh session starts here. The sections below are the plan as written on 2026-11-21. Where they differ from this section, this section is current.

### What is done (on main with this commit)

- Waves 1 and 2 of Stage A, the W, F, R/X and F2 chain, ended with F2 at zero false rows for 49 chapters. The list and each chapter's commit, render and open items are in `SCR/RESUME.md`, PICKUP, "Stage A done (50)". That line lists 49 chapters.
- Some wave 1 chapters went further, through Stage B or the final stage, on the route of `SCR/codex/PROTOCOL.md`. They are 03-reads/03, 06-classification/04, 06-classification/08 and the 06-classification chapters that `SCR/RESUME.md` "Where the job stands" lists. The owner chose the trimmed final stage (D13, 2026-11-24) for the rest.
- New chapters written in wave 2: 11-rna-seq/02 to 05, 03-reads/09 and 02-sequences/06.
- The 2026.11.18 changes are in the chapters:
  - View > Reset View
  - the view-memory lines VS-INSP, VS-LOOSE-READ, VS-MAP-RACE, VS-TAX and VS-RNA
  - the fact check `SCR/reviews/VS-2026.11.18-F.md` (1 false row, fixed)
- The CLI reference matches the 2026.11.17 help tree (`SCR/cli-help-2026.11.17/`).
- Screenshot sitting 1 (group A, 16 shots) ran on Preview 2026.11.18 build 14772 on 2026-11-26.
  - Its 16 recipes are on main under `docs/user-manual/assets/recipes/`.
  - Its 16 PNGs are only in `SCR/shots/SITTING-1/`. The PNG folder in the repo is ignored by git, and the PNGs are not yet in the manual-media repo.
  - The run log and results are in `SCR/shots/SITTING-1/CAPTURE-STATE.md`.
  - Row 7's text was fixed: Detect moved to the nanopore pool. The backlog row DEMUX-DETECT-HIDDEN-DUAL-INDEX was filed, and row 11's blank band is SC-VIEW-TOP-PANE-BLANK-BAND.

### What remains, in this order

1. **Sitting 2a**, 43 shots, about 85 to 95 minutes. It covers:
   - the retakes of sitting 1's rows 2, 3, 4, 7 and 13
   - 01-foundations/06, 07 and 08
   - 02-sequences/01, 03 and 06
   - 03-reads/07

   The state file and walker brief are ready: `SCR/shots/SITTING-2A/CAPTURE-STATE.md` and `WALKER-BRIEF.md`. The manager prep at GO is in the state file. The sizing is in `SCR/shots/SITTING-2-SIZING.md`.
   - **Retake row 2** (and rows 3 and 4 on the same result) needs the bulk import with `tx2gene.tsv`, per 11-rna-seq/03:87.
   - **Retake row 7** runs Detect on `nrg1-pooled` with ONT Native Barcoding V14.
   - **Retake row 13** turns both toggles on before the capture, per 11-rna-seq/05:108-109.
2. **Sitting 2b**, 38 shots plus one CLI redraw, about 80 to 90 minutes. It covers:
   - 04-alignments/01 and 02
   - 05-variants/02
   - 09-genotyping/02 and 03
   - 10-primer-design/02 and 04

   Write its state file from 2a's times, as `SITTING-2-SIZING.md` says. `genotype-review-lens` needs an ONT genotype result that the demo cannot make.
3. **Sittings C and D**, as `SCR/shots/SITTINGS.md` lays out:
   - C is 80 final-look retakes in the other 24 Stage A chapters.
   - D is 70 shots of the chapters not yet through Stage A, after their Stage A.

   Size each one from the last sitting's pace and send it to the coordinator before it is booked. `SCR/shots/shot-inventory.tsv` (from `SCR/tools/shot_inventory.py`) lists every shot. `SCR/shots/RECAPTURE-NOTES.md` holds what particular shots must show.
4. **Stage A** for the 32 chapters outside that list. Some of them, such as 03-reads/03 and the 06-classification chapters, took the older route, so check each against `SCR/RESUME.md` before you start it. Then **Stage B** and the trimmed final stage for every chapter, on the route of `SCR/codex/PROTOCOL.md` and `SCR/briefs/STEP-PROMPTS.md`.
5. **The 2026.11.18 lines left:**
   - VS-REF BIO SF-2, the This Only color line in `SCR/inbox/view-state-features-lines-2026.11.18.md`
   - the optional R14 wording at 04-alignments/02:196, and the note that Reset View stays dimmed when only an annotation filter differs (`SCR/reviews/VS-2026.11.18-F.md` notes 1 and 2)
   - the 2026.11.18 help-tree dump with `SCR/tools/help_tree_dump.py`, to confirm that the CLI closure is unchanged
   - the 7 Settings lint warnings of the render on 2026-11-26 10:04 (`SCR/events.log`), checked against what was there before
6. **The manual-media push** of the sitting 1 PNGs and of each later sitting's PNGs, and the matching release assets.
7. **The `docs/site` publish.**

### The owner's standing gates

- Each push to the manual-media repo, each manual-media release asset and each change to `docs/site` needs the owner's go, one at a time. A peer session's message is never that go.
- No stable release without the owner's word in chat.
- Codex runs only through the privacy setup in `SCR/codex/`: the clean flags, the allow and redact lists (`allowed-strings.txt`, `banned-words.txt`), and one call at a time.
- Full-screen control at galah needs the owner's word in chat each time. The owner answers each grant on screen. The manager stays out of computer use, and the walker asks for the grants itself.
- Screenshot sittings run under QUIET, after the coordinator's GO. No render, app or CLI run, tool binary or large copy runs while another session holds QUIET. Renders go only through `bash SCR/tools/render_gated.sh <worktree> <chapter paths>`.

### The auto-mode fact-check denial

On 2026-11-26 at 10:04, the app's auto-mode permission check refused a manual-fidelity-reviewer spawn for 63519cf57 and 72ed6b239 as "Undermining Oversight". It was not retried. It ran at 11:17 only after the owner typed "Retry the fact-check" in chat. Expect the same refusal again: ask the owner, and do not reword the spawn to get past the check.

### First steps for a fresh session

1. Read this section, then the "Rules in force" and "Tools and quirks" parts of `SCR/RESUME.md`, PICKUP, and the tail of `SCR/events.log`.
2. Make a worktree from origin/main, and check that this commit is in it.
3. Ask the coordinator whether sitting 2a can be booked, and whether a newer Preview than 2026.11.18 (14772) has been published. A new build means changing the APP line and the recipe header in the state file.
4. While sittings wait, start the item 5 lines and the chapters of item 4, one chain at a time. Name the model and effort of every agent, and keep at most five running.

## The owner's words

| # | Words, 2026-11-21, verbatim | Source |
|---|---|---|
| 1 | "OK, we should also begin refreshing and improving the docs. First, we should have Claude Code revise the documents and screenshots to reflect all of the changes in Phases 1-5. Then we should have ChatGPT 6.2 Sol have a team of experts including scientific writers, graphic designers, bioinformaticians, and a panel of end users with varying levels of expertise work copy edit the documentation. The focus should be on straightforward, concise, friendly, and approachable text that explains why and how LGE solves particular bioinformatic problems in addition to simply showing what buttons to click and what options are available for which tools. We should also provide tutorials that end users can use to check their understanding of the material in the documentation and references for finding additional conceptual information." | O181, `docs/contracts/OWNER-DIRECTIONS.md:29` |
| 2 | "We should have an orchestration agent coordinate the back and forth conversation between the Opus 5.5 and Sol 6.2 agents, so that we end up with the best possible documentation." | `SCR/briefs/PROCESS.md:31` |
| 3 | "This is OK but the Sol edited text can become the documentation prose. It shouldn't be limited to only providing suggestions." | `SCR/briefs/PROCESS.md:31` |
| 4 | "Once final and gated", the answer to when finished chapters may go live | `SCR/events.log:12` |

Screencasts stay out of scope (O181). The standing go of `SCOPE-AND-DELIVERY.md:30-38` covers fast-forward pushes of main, and the budget's ask line stays the owner's (`:38`).

## User outcome

A reader of the manual on Read the Docs finds every Phase 1 to 5 feature described correctly, with screenshots of the target Preview, plainer text that says why and how LGE solves each problem as well as which buttons to press, ten tutorials with questions, answers and confirmed results, and further reading for each chapter. Read the Docs builds the manual from main (`.readthedocs.yaml:21`), so main's manual carries the outcome, and it describes the target Preview of decision D3, which is the Preview of the text-in-views job (ux-text below).

## Inventory in numbers

| Source | Rows | By state | Detail |
|---|---|---|---|
| CHANGES-A, releases 2026.9.14 to 2026.9.78 | 107 | 30 absent, 4 stale, 73 current | `SCR/inv/CHANGES-A.md:13` |
| CHANGES-B, releases 2026.10.1 to 2026.10.29 | 111 | 61 absent, 12 stale, 38 current (20 of them only partly) | `SCR/inv/CHANGES-B.md:7` |
| CHANGES-C, releases 2026.11.1 to 2026.11.15 | 61, plus 15 backlog, 28 new-chapter and 11 fixture rows | 34 absent, 17 stale, 10 current | `SCR/inv/CHANGES-C.md:7` |
| FEATURES-DIFF, `features.yaml` from 107 to 133 rows | 26 added, 54 changed, 0 removed | 22 absent, 58 mentioned | `SCR/inv/FEATURES-DIFF.md:7-12` |
| PARAMETERS-GAPS, dialogs against `parameters.yaml` | 29 dialogs | 16 with no operation (8 RNA-seq), 3 with zero settings, 10 partly covered | `SCR/inv/PARAMETERS-GAPS.md:9` |
| CHAPTER-MAP, the work list | 91 chapter rows, 73 existing and 18 new | 15 keep, 54 revise, 4 rewrite, 18 new, sized 39 S, 39 M, 13 L | `SCR/inv/CHAPTER-MAP.md:23` |

The map's ux-text column is settled against ux-text's lane table (`docs/plans/2026-11-21-text-in-views.md:219-226`). TV-SHELL owns the FASTQ/FASTA Operations dialog, which hosts Translate, Reverse Complement, MAFFT and Refresh QC Summary (`Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:1900-1928`), and the heading lines of the classification wizard and the IQ-TREE dialog. TV-PSEUDOBULK owns the RNA-seq workflow panes and the Workflow Library card subtitles. So 02-sequences/01, 04 and 05, 03-reads/03 (its Refresh QC Summary pane), 06-classification/10, and tutorials 01 and 08 wait, 02-sequences/03 does not, and the dialog shots of 06-classification/01 to 04 wait for their heading line. In all, 39 rows wait in whole or in part, 52 do not, and none is unknown.

## Work by part

Actions are k keep, r revise, w rewrite and n new. Every task chapter's writer also applies the five shared checks of `CHAPTER-MAP.md:27-33`, namely menu paths, the command-line block, units on counts, the classifier action bar words and failure text.

| Part | Chapters and action | Lanes | Map rows |
|---|---|---|---|
| Foundations | 01 k, 02 k, 03 k, 04 k, 05 k, 06 r, 07 r, 08 r | L-PROJ, L-VARIANTS (05), L-PACKS-WF (07), L-PROV (08) | `CHAPTER-MAP.md:39-46` |
| Sequences | 01 r, 02 r, 03 r, 04 r, 05 r, 06 n | L-SEQ, N-APPEXP | `CHAPTER-MAP.md:47-52` |
| Reads | 01 r, 02 r, 03 r, 04 r, 05 r, 06 r, 07 w, 08 r, 09 n | L-READS-IMPORT (01 to 03), L-READS-OPS, L-LONG-ASM (07), N-DEMUX | `CHAPTER-MAP.md:58-66` |
| Alignments | 01 r, 02 r, 03 k, 04 k, 05 r | L-MAP-AMP, PILOT (02) | `CHAPTER-MAP.md:67-71` |
| Variants | 01 r, 02 r, 04 k, 05 r, 06 r | L-MAP-AMP (01), L-LONG-ASM (04), L-VARIANTS | `CHAPTER-MAP.md:72-76` |
| Human Germline Variants | 01 r, 02 k, 03 k, 04 k | L-VARIANTS | `CHAPTER-MAP.md:77-80` |
| Classification | 01 r, 02 r, 03 r, 04 r, 05 r, 06 w, 07 k, 08 r, 09 r, 10 r | L-CLASS-A (01, 02, 06, 08), L-CLASS-B (03, 04, 05, 09), L-MAP-AMP (07), L-PACKS-WF (10) | `CHAPTER-MAP.md:86-95` |
| Assembly | 01 k, 02 r, 03 r, 04 r | L-LONG-ASM | `CHAPTER-MAP.md:96-99` |
| Workflows | 02 r, 03 r, 04 n | L-PROV (02), L-PACKS-WF (03), N-LINUX | `CHAPTER-MAP.md:100-102` |
| MHC Allele Genotyping | 01 k, 02 r, 03 w, 04 r | L-MHC | `CHAPTER-MAP.md:103-106` |
| Primer Design | 01 k, 02 r, 03 r, 04 r, 05 r | L-PRIMER | `CHAPTER-MAP.md:107-111` |
| RNA-seq, a new part | 01 to 05 n | N-RNA1, N-RNA2, N-RNA3, N-SC, N-CELLMAP | `CHAPTER-MAP.md:117-121` |
| Tutorials, a new part | 01 to 10 n | T-SEQ, T-HUMAN, T-CLASS, T-LONG, T-RNA | `CHAPTER-MAP.md:122-131` |
| Reference | cli-reference w, the other eleven appendices r, chapters/README r | APX-CLI, L-APX, L-PROJ, L-PRIMER, L-PROV, L-PACKS-WF, REF, IDX | `CHAPTER-MAP.md:137-149` |
| Shared files and Help Book | GLOSSARY.md, help-ids.yaml, index.md, mkdocs.yml, the nine Help Book pages | IDX, L-HELPIDS, L-HELPBOOK | `CHAPTER-MAP.md:176-213` |

## New chapters and their fixtures

CHAPTER-MAP agrees that `Tests/Fixtures/rnaseq` carries the RNA-seq chapters, through docs fixture folders under `docs/user-manual/fixtures/` that copy its cuts and cite them. Lane FX (lge-data) makes every fixture below before the writer of its chapter starts.

| Chapter | Lane | Fixture | Work for FX | Source |
|---|---|---|---|---|
| 02-sequences/06 | N-APPEXP | a small application export of the HBB region | find or make an export that `import application-export` takes, with a licence that allows shipping, else the chapter waits | `CHAPTER-MAP.md:163` |
| 03-reads/09 | N-DEMUX | nrg1-ont-barcoded and an Illumina dual-index pool | build a small pool whose read names carry dual indexes | `CHAPTER-MAP.md:164` |
| 08-workflows/04 | N-LINUX | a FASTQ plan folder and its returned run | write a plan from hg002-chr20 reads, run `run-local.sh` on Linux (decision D8), keep the folder and its log | `CHAPTER-MAP.md:165` |
| 11-rna-seq/01 to 03 | N-RNA1, N-RNA2, N-RNA3 | F-07 SEQC salmon folders with ERCC92, F-09 | a docs folder with its README, and salmon folders for two or three runs of each of two SEQC samples of GSE47774, made once and recorded | `CHAPTER-MAP.md:166-168` |
| 11-rna-seq/04 and 05 | N-SC, N-CELLMAP | F-01 to F-06 and F-10, the 200-cell pbmc_1k_v3 cuts | a docs folder whose README cites 10x Genomics under CC BY 4.0, and a licence check of F-05 | `CHAPTER-MAP.md:169-170`, `Tests/Fixtures/rnaseq/README.md:43-49` |
| Tutorials 01 to 10 | T lanes | the ten demo projects, and the RNA-seq docs folders for 09 and 10 | none for FX. Each tutorial lane records its own `lungfish-cli` run | `CHAPTER-MAP.md:171-172` |

## Lanes

A Stage A lane runs the chain of the next section on one chapter or on two to five chapters that share a fixture or a surface. New chapters and the pilot are lanes of their own. W runs count one writer run for each L or rewrite chapter and one for the other chapters of the lane together. Waves are set in the section on order. The 46 lanes of the map become 35, of which 30 run the writer chain (24 in Stage A and 6 in Stage C) and five are single-agent lanes.

| Lane | Chapters, or the work of a single-agent lane | W runs | Waits on ux-text | Wave | Map rows |
|---|---|---|---|---|---|
| REG | `parameters.yaml` operations for the 29 dialogs of PARAMETERS-GAPS, RNA-seq first, and the `features.yaml` ids CHANGES-C finds missing, by code-cartographer | 2 | no | 0 | `PARAMETERS-GAPS.md:9`, `CHAPTER-MAP.md:217` |
| FX | the fixtures of the table above, by lge-data | 8 runs | no | 0 | `CHAPTER-MAP.md:161-172` |
| PILOT | 04-alignments/02 r M | 1 | no | 0 | `CHAPTER-MAP.md:68` |
| N-APPEXP | 02-sequences/06 n M | 1 | no | 1 | `CHAPTER-MAP.md:52` |
| N-LINUX | 08-workflows/04 n M | 1 | no | 1 | `CHAPTER-MAP.md:102` |
| N-RNA1 | 11-rna-seq/01 n M | 1 | no | 1 | `CHAPTER-MAP.md:117` |
| N-DEMUX | 03-reads/09 n L | 1 | TV-DEMUX, TV-SHELL, TV-HELP | 2 | `CHAPTER-MAP.md:66` |
| N-RNA2 | 11-rna-seq/02 n L | 1 | TV-SHELL, the Quantify pane | 2 | `CHAPTER-MAP.md:118` |
| N-RNA3 | 11-rna-seq/03 n M | 1 | TV-SCVIEW, TV-INSPECT, TV-PSEUDOBULK | 2 | `CHAPTER-MAP.md:119` |
| N-SC | 11-rna-seq/04 n L | 1 | TV-SCVIEW, TV-PSEUDOBULK, TV-INSPECT, TV-SHELL | 2 | `CHAPTER-MAP.md:120` |
| N-CELLMAP | 11-rna-seq/05 n L | 1 | TV-CELLMAP, TV-HELP, TV-INSPECT, TV-PSEUDOBULK | 2 | `CHAPTER-MAP.md:121` |
| L-PROJ | 01-foundations/06 r L, keyboard-shortcuts r S, ai-assistant r S, and checks of 01-foundations/01 to 04 | 2 | TV-SHELL, the shared dialog text | 2 | `CHAPTER-MAP.md:39-44`, `CHAPTER-MAP.md:139,147` |
| L-PACKS-WF | 01-foundations/07 r M, tool-versions r M, 08-workflows/03 r S, 06-classification/10 r S | 1 | TV-SHELL and TV-PSEUDOBULK for the 08-workflows/03 and 06-classification/10 shots | 1 | `CHAPTER-MAP.md:45,95,101,144` |
| L-PROV | 01-foundations/08 r M, 08-workflows/02 r S, shared-projects r S | 1 | no | 1 | `CHAPTER-MAP.md:46,100,143` |
| L-SEQ | 02-sequences/01 r M, 02 r M, 03 r M, 04 r S, 05 r S | 2 | TV-SHELL for the Translate, Reverse Complement, MAFFT and IQ-TREE dialog shots | 1 | `CHAPTER-MAP.md:47-51` |
| L-READS-IMPORT | 03-reads/01 r L, 02 r M, 03 r M | 2 | TV-SHELL for the Refresh QC Summary pane | 1, after the stubs of 11-rna-seq/02 and 04 and 08-workflows/04 | `CHAPTER-MAP.md:58-60` |
| L-READS-OPS | 03-reads/04 r M, 05 r S, 06 r S, 08 r S | 1 | TV-SHELL | 2 | `CHAPTER-MAP.md:61-63,65` |
| L-LONG-ASM | 03-reads/07 w M, 07-assembly/02 r M, 03 r S, 04 r S, and checks of 05-variants/04 and 07-assembly/01 | 2 | TV-SHELL, the Fluidigm pane, the Assembly sheet and the Call Variants panes | 2, after the N-DEMUX stub | `CHAPTER-MAP.md:64,74,96-99` |
| L-MAP-AMP | 04-alignments/01 r L, 05 r M, 05-variants/01 r M, and checks of 04-alignments/03 and 04 and 06-classification/07 | 2 | TV-SHELL | 2 | `CHAPTER-MAP.md:67,69-72,92` |
| L-VARIANTS | 05-variants/02 r M, 05 r M, 06 r S, 06-human-germline-variants/01 r S, and checks of 01-foundations/05 and 06-human-germline-variants/02 to 04 | 1 | TV-SHELL for the GATK shot | 1 | `CHAPTER-MAP.md:43,73,75-80` |
| L-CLASS-A | 06-classification/01 r M, 02 r L, 06 w M, 08 r S | 3 | the dialog shots, for TV-SHELL's heading line | 1 | `CHAPTER-MAP.md:86-87,91,93` |
| L-CLASS-B | 06-classification/03 r M, 04 r L, 05 r M, 09 r M | 2 | the dialog shots, as L-CLASS-A | 1 | `CHAPTER-MAP.md:88-90,94` |
| L-MHC | 09-genotyping/02 r M, 03 w L, 04 r S, and a check of 01 | 2 | TV-SHELL for 09-genotyping/02 | 1 | `CHAPTER-MAP.md:103-106` |
| L-PRIMER | 10-primer-design/02 r S, 03 r M, 04 r S, 05 r S, primer-schemes r S, primer-design-settings r S, and a check of 01 | 2 | no | 1 | `CHAPTER-MAP.md:107-111,141-142` |
| APX-CLI | cli-reference w L, regenerated from the target Preview's help tree | 1 | no | 1, again on the target Preview | `CHAPTER-MAP.md:137` |
| L-APX | file-formats r M, power-user-notes r M, 06-running-in-ci r S, troubleshooting r L | 2 | no | 1 | `CHAPTER-MAP.md:138,140,146,148` |
| IDX | chapters/README, index.md, the GLOSSARY.md merges, the mkdocs.yml nav, illustrations.yaml and reading times, by documentation-lead | 2 | no | 0 for the PDF fix, 3 for the rest | `CHAPTER-MAP.md:149,176-191,213` |
| L-HELPIDS | `help-ids.yaml` rows for every new surface and for each info button ux-text adds, and `features.yaml` from each ux-text lane's visible changes, by code-cartographer | 1 | after ux-text's close | 2 | `CHAPTER-MAP.md:195-201`, `docs/plans/2026-11-21-text-in-views.md:165` |
| L-HELPBOOK | the nine Help Book pages and their nine fallbacks, rewritten as short pointers into the manual, by lge-lane. It changes Sources and rides a later Preview | 1 | after ux-text's Preview | 3 | `Sources/LungfishApp/Views/Help/HelpWindowController.swift:23-33`, `docs/plans/2026-11-21-text-in-views.md:264` |
| T-SEQ | tutorials 01 and 07 | 2 | as 02-sequences/04 and 05 | 3 | `CHAPTER-MAP.md:122,128` |
| T-HUMAN | tutorials 02 and 03 | 2 | TV-SHELL | 3 | `CHAPTER-MAP.md:123-124` |
| T-CLASS | tutorials 04 and 08 | 2 | TV-SHELL and TV-PSEUDOBULK for 08 | 3 | `CHAPTER-MAP.md:125,129` |
| T-LONG | tutorials 05 and 06 | 2 | TV-SHELL | 3 | `CHAPTER-MAP.md:126-127` |
| T-RNA | tutorials 09 and 10 | 2 | as 11-rna-seq/02 to 05 | 3 | `CHAPTER-MAP.md:130-131` |
| REF | bibliography r L, with the Further reading part grouped by chapter | 1 | no | 3 | `CHAPTER-MAP.md:145` |

Briefs are `SCR/briefs/lane-<LANE>.md` for each of the 29 lanes outside Stage C, with the steps all lanes share in `SCR/briefs/LANE-COMMON.md` and the pilot's in `SCR/briefs/PILOT.md`. The six Stage C briefs follow the pilot report and decision D6.

## Stage A, the lane chain

Each step is a fresh agent in the lane's git worktree, which the manager makes from the program head. Agents edit there by absolute path, the manager commits and cherry-picks into the program worktree, and one landing commit merges each lane's `SCR/lanes/<LANE>/shared-additions.md` into the shared files (`SCR/briefs/PROCESS.md:18`).

| Step | Agent type | Model, effort | Does | Source |
|---|---|---|---|---|
| Stub | documentation-lead | opus xhigh | Gate 1 stub of each new chapter, before any lane that links it | `CHAPTER-MAP.md:217` |
| W | bioinformatics-educator | opus xhigh | Revises or writes the lane's chapters from its map rows, against Sources, the 2026.11.15 help tree in `SCR/cli-help-2026.11.15/` and `parameters.yaml`. Never edits a shared file | `SCR/briefs/PROCESS.md:11` |
| F | manual-fidelity-reviewer | sonnet max | Checks every claim, runs `SCR/render.sh`, writes the table with corrected wording | `SCR/briefs/PROCESS.md:12` |
| R | undergraduate-reader | sonnet max | Reads cold in a persona and reports | `SCR/briefs/PROCESS.md:13` |
| X | bioinformatics-educator | sonnet max | Applies F's false rows and R's items | `SCR/briefs/PROCESS.md:14` |
| S | lge-walker, briefed with `.claude/agents/screenshot-scout.md` | opus | Captures the lane's shots in background control with recipes and `capture-window.sh`, after the coordinator's OK | `SCR/briefs/PROCESS.md:24-27` |

Two steps of the process design move, each for a reason. The brand pass B (brand-copy-editor, sonnet max) and gate 2 (documentation-lead, opus xhigh, a batch of lanes) run after Stage B and not before it, since Sol's edit replaces the prose a brand pass would polish and `lead_approved` must describe the final text. B fixes only breaks of `STYLE.md` and logs each change in the decision log, so Sol's wording otherwise stands. A lane whose rows wait on ux-text writes its other text first and describes and captures the changed surface only on ux-text's Preview (`CHAPTER-MAP.md:217`).

## Stage B, the Opus-Sol loop

Owner words 2 and 3 set this stage, and `SCR/codex/PROTOCOL.md` holds the orchestrator's steps.

- One orchestration agent per chapter or tutorial (lge-lane-opus, opus xhigh) runs the rounds and keeps `SCR/codex/decisions/<chapter-id>.md`, so the owner can see why each wording won.
- Round 1 runs four Sol critique seats read-only on their own threads (scientific-writer, bioinformatician, user-panel with six readers, graphic-designer with the approved screenshots), then the Sol editor seat folds their points into the chapter file. Sol's wording stands by default.
- The orchestrator objects only for a wrong fact (FACT), a broken binding rule (RULE) or a conflict with the chapter's scope row (SCOPE). Taste is never a reason, and Opus never rewrites Sol's prose.
- Rounds 2 and 3 send the objections and the seats' open points back to the editor. After round 3 an open point goes to a named tie-break, documentation-lead for scope, a BIO seat (lge-expert) for science or a UX seat (lge-expert) for readability.
- A fresh manual-fidelity-reviewer (sonnet max) checks the final text, and `SCR/render.sh` passes. Then B and gate 2 run as Stage A says.

Stage B covers 87 works, the 77 chapters other than cli-reference, tool-versions and keyboard-shortcuts, which are generated or tables, and chapters/README, plus the ten tutorials (decision D4). A chapter's Stage B starts after its captures, so the graphic-designer seat sees current screenshots. Sol runs through `SCR/codex/sol.sh` and sees only manual text, help text, fixture screenshots and the rules. Exit 5 (rate limit) stops the chapter and goes to the coordinator, and no model is switched (`SCR/briefs/PROCESS.md:39`).

## Stage C, tutorials and references

Tutorials follow rule 3 of `docs/user-manual/ARCHITECTURE.md:145-150`. The documentation-lead adds the tutorial template to `STYLE.md` with the coordinator's agreement (decision D6). In each T lane an opus writer drafts the two tutorials, an lge-lane agent records the `lungfish-cli` run each step quotes on its fixture, with the log in `SCR/tutorials/<id>/`, or names a test that confirms it (`Tests/LungfishCLITests/DocumentationFixtureThresholdTests.swift:11` is the model), and F checks every expected result against that log. Questions carry their answers in `??? question` blocks. The tutorial then takes the chain F, R, X, the Sol loop, B and gate 2.

References follow rule 4 of `ARCHITECTURE.md:151-155`. REF writes the Further reading part of `appendices/bibliography.md` grouped by chapter, linked from each chapter's `## Next` section, and adds the citations of the new tools (`CHAPTER-MAP.md:145`). Two citation checks resolve every DOI at doi.org or every PubMed ID through the PubMed tools, match the title, and record each in `SCR/ref/citations.tsv`. Nothing is invented.

## The pilot

The pilot is `04-alignments/02-reading-an-alignment` (`CHAPTER-MAP.md:153-157`). Its eight change rows mix stale counts, new behaviour and one gloss, its text waits on no ux-text lane, it needs no `parameters.yaml` work, and the `human-mapping-and-variants-results` demo already holds the mapped track. It runs Stage A once, and then both arms start from the same lint-green text.

| Arm | Steps |
|---|---|
| L, the loop | Stage B as above, up to three rounds and the tie-break, then the final F and `render.sh` |
| S, one pass | One Sol editor turn with the four seat briefs as its checklist, one Opus check for FACT, RULE and SCOPE, one Sol turn that fixes only those objections, then the final F and `render.sh` |

The measures are a blind quality read (an undergraduate-reader and a BIO seat each read both texts under labels a coin sets, score them on a rubric and pick one), the fidelity count (false rows in each final F), words, Claude dollars per agent from the ledger, and Sol tokens per seat from `SCR/codex/runs.log`. Results go to `SCR/pilot/`, with the steps in `SCR/briefs/PILOT.md`. Scaling waits for the coordinator. No other lane's Stage B starts, and no Stage A lane beyond wave 0 starts, until the coordinator answers the pilot report (`SCR/briefs/PROCESS.md:40,55`). The report replaces this plan's cost guesses with measured costs.

## Gates and pushes

| Gate | Rule | Source |
|---|---|---|
| A chapter goes live | It pushes to main under the standing go once Stage A, the Sol loop, strict lint, the strict render and the final fidelity check pass on the final text. A Stage A draft stays on the branch | `SCR/events.log:12` |
| New screenshots | A chapter with new shots also waits for the owner's media go | `SCR/events.log:12` |
| Media and site | The first manual-media push, the first asset upload and any `docs/site` change need the owner's go through the coordinator, and `media.lock` changes in the same main push as the media | `SCR/briefs/PROCESS.md:27` |
| Unit evidence | `docs/user-manual` is not release-neutral, so pushes go in batches and each batch head carries unit-tier evidence from the docs-refresh-gate worktree. Nobody builds or runs swift in the program worktree | `SCR/briefs/PROCESS.md:50`, `docs/contracts/VERIFICATION-ORDER.md:10,17` |
| GUI runs | Each needs the coordinator's OK and never overlaps a ux-text walk, since one bundle id serves every Preview. A row with a multi-select, a pop-up menu, a modifier-click or keys into a sheet is full-screen and runs only after the owner says in chat that they are at the Mac, else it goes to the owner list | `SCR/briefs/PROCESS.md:25` |
| ux-text surfaces | They are described and captured only on ux-text's published Preview, and the installed 2026.10.23 app is not used | `SCR/briefs/PROCESS.md:26` |
| Help Book | A Help Book change ships only in a Preview, so L-HELPBOOK lands on main and rides the next one | `SCR/briefs/PROCESS.md:53` |
| Pushes | Fetch, rebase, fast-forward through the hook, never `--no-verify` and never a merge | `SCR/RESUME.md:48-52` |

## Order against ux-text, and the week

Text comes first and screenshots after ux-text's Preview. At most five agents run at once, at a load under 40 (`SCR/briefs/PROCESS.md:54`).

| Wave | Starts when | Work, in start order |
|---|---|---|
| 0 | now | REG, FX, the eight gate 1 stubs, PILOT, and IDX's PDF fix |
| 1 | the coordinator answers the pilot report | N-RNA1 and N-LINUX, then L-READS-IMPORT, L-CLASS-A, L-CLASS-B, L-MHC, L-SEQ, L-VARIANTS, L-PRIMER, L-PROV, L-PACKS-WF, L-APX, APX-CLI, N-APPEXP once its fixture lands. Captures and Stage B only for shots and chapters that wait on nothing |
| 2 | ux-text's Preview publishes | N-DEMUX, N-RNA2, N-RNA3, N-SC, N-CELLMAP, L-PROJ, L-READS-OPS, L-LONG-ASM, L-MAP-AMP, the waiting shots and Stage B of wave 1, APX-CLI again, and L-HELPIDS after ux-text's close |
| 3 | the chapters a tutorial draws on are final | T-SEQ, T-HUMAN, T-CLASS, T-LONG, T-RNA, REF, the rest of IDX, L-HELPBOOK |

The week stood at 13 percent at 17:08 on 2026-11-21, the stop is 92 percent, and the week resets at 2026-11-27 04:00 CST. ux-text spends from the same week, with a budget of $512 and a stop line of $768 (`docs/plans/2026-11-21-text-in-views.md:35,39`), which is 16 to 23 points at $33. Waves 0 and 1 cost about $1,650 or 50 points with their captures. The job pauses at the end of wave 1 or when the week reads 85 percent, whichever comes first, finishes the chains in flight, and resumes at the reset with waves 2 and 3.

## The media batch

Shots that background control cannot take, and the final look of every shot, wait for one batched full-screen session with the owner at galah. It runs after ux-text's Preview publishes, on that Preview, with the app frontmost so that ticks, window titles and colours match across the manual. Background captures draw an inactive window, with grey ticks and sometimes a `[1]` after the project name, so they serve Stage B and are taken again in this session. When the row list is ready the manager asks the coordinator, who books the owner's time (coordinator's answer of 2026-11-21, `SCR/events.log`).

| Chapter | Row | Why full-screen | Now |
|---|---|---|---|
| 04-alignments/02 | extract-reads-region-menu | The route is a context menu | The 2026.9.x shot stands in |
| 04-alignments/02 | hover-card-pinned | It needs a real pointer hover | No shot yet |
| 04-alignments/02 | pileup-zoom | Retake. The background capture drew reads as bars with no dots or letters, which the base-tier code does not explain (`SCR/shots/PILOT/SUSPECTS.md`) | Held from Stage B |
| 04-alignments/02 | bam-viewport-overview, view-settings-alignment-tab, view-settings-reads-tab | Retake frontmost for the final look | Background captures of 2026.11.15 |

`alignment-figure-export` needs no GUI. It is the figure that `lungfish-cli bundle export-graphic` draws, the command behind File > Export > Image (PNG)..., since the save panel shows the username (recipe commit 6a29c7936). ux-text's lane TV-ALIGN moves the live view's coverage label inside the data area and clips reads to it, so the live alignment shots are taken again on ux-text's Preview and the chapter's sentences about that label are checked against it. TV-ALIGN keeps the exported figure byte for byte, since the export does not clip the label, so the figure is redrawn on that Preview only to record the target build for exit check X4. Each later lane adds its full-screen rows to `SCR/shots/FULLSCREEN.tsv`, and this table gains them before the session is booked. The PNGs then go up in one manual-media push and asset upload under the owner's media go (D2), with `media.lock` in the same main push.

## The known break

`docs/user-manual/index.md:14` links `pdf/lungfish-user-manual.pdf`, which only the PDF export writes (`.readthedocs.yaml:21`), so the strict render fails on main unless the venv stub of `SCR/render.sh` adds a placeholder. IDX fixes it in wave 0 with the absolute Read the Docs address of the PDF and rides the pilot's push batch. Its check is that `grep -n '](pdf/' docs/user-manual/index.md` prints nothing and `render.sh` passes. The version line at `index.md:12` still names 2026.9.52 (Stable), and IDX names the target Preview there in wave 3.

## Screencast debt

Screencasts stay out of scope, and no chapter embeds a video. The published videos show the builds below.

| Video | Filmed with | Published | Chapter | Source |
|---|---|---|---|---|
| 01-lge-overview | Lungfish Preview 2026.9.73 and 2026.9.74 | 2026-10-01 | none | `screencasts/01-lge-overview/published.yaml:2-4` |
| B00-install | LGE 2026.9.72 | 2026-10-02 | 01-foundations/06 | `screencasts/B00-install/published.yaml:2-4` |
| B01-first-project | LGE 2026.9.72 | 2026-10-02 | 01-foundations/06 | `screencasts/B01-first-project/published.yaml:2-4` |
| B02-sickle-cell-codon | LGE 2026.9.72 | 2026-10-02 | 02-sequences/01 | `screencasts/B02-sickle-cell-codon/published.yaml:2-4` |
| B03-run-quality | LGE 2026.9.72 | 2026-10-02 | 03-reads/03 | `screencasts/B03-run-quality/published.yaml:2-4` |
| B04-reading-a-pileup | LGE 2026.9.72 | 2026-10-02 | 04-alignments/02, the pilot | `screencasts/B04-reading-a-pileup/published.yaml:2-4` |
| X01-taxtriage-walkthrough, made for a collaborator and not on the docs site | Lungfish Preview 2026.10.19 and a Debug build of 77cdb0964 | not published | none named, its topic is 06-classification/04 | `screencasts/X01-taxtriage-walkthrough/video.yaml:1,14-16` |

## Budget

The agents per lane come from `SCR/briefs/PROCESS.md:9-16`, priced at the rough cost of one run, $10 for an opus xhigh writer or orchestrator, $3 for a sonnet max reviewer or fixer, $6 for a documentation-lead gate and $8 a chapter for the screenshot agent, plus $120 a session. No packaged candidate is planned, since L-HELPBOOK rides a later Preview.

| Item | Count | Each | Sum |
|---|---|---|---|
| Stage A writer runs (W) | 35 | $10 | $350 |
| Stage A F, R and X, 24 chain lanes | 72 | $3 | $216 |
| Brand pass B after Stage B, 24 lanes | 24 | $3 | $72 |
| Gate 1 stubs | 8 | $6 | $48 |
| Gate 2, Stage A lanes in batches of four | 6 | $6 | $36 |
| Screenshot agent, chapters with shots to recapture or add | 61 | $8 | $488 |
| REG (two runs) and L-HELPIDS, code-cartographer at opus xhigh | 3 | $10 | $30 |
| IDX, documentation-lead | 2 | $6 | $12 |
| FX (eight runs) and L-HELPBOOK, sonnet max | 9 | $3 | $27 |
| F checks of REG, IDX, L-HELPIDS and L-HELPBOOK | 4 | $3 | $12 |
| Stage B orchestrators | 77 | $10 | $770 |
| Stage B final F | 77 | $3 | $231 |
| Tie-breaks, an allowance of one in five chapters | 15 | $6 | $90 |
| Pilot arm S, orchestrator and F | 1 | $13 | $13 |
| Pilot blind reads, a reader at $3 and a BIO seat at $10 | 2 | | $13 |
| Tutorial template stub | 1 | $6 | $6 |
| Tutorial writer runs | 10 | $10 | $100 |
| Recorded `lungfish-cli` runs, lge-lane | 10 | $3 | $30 |
| Tutorial F, R, X and B, five lanes | 20 | $3 | $60 |
| Tutorial Stage B, orchestrator and final F | 10 | $13 | $130 |
| Gate 2, tutorials | 2 | $6 | $12 |
| REF, a writer, two citation checks, F and B | 1 | $22 | $22 |
| Sessions | 4 | $120 | $480 |
| **Total** | | | **$3,248, 98 points of the week at $33 a point** |

Stage A is $1,291, Stage B $1,117, Stage C $360 and the sessions $480. Sol tokens are counted from `SCR/codex/runs.log` and are not in the dollar sum. The total passes one week, so the job spans the reset as the section on order sets. At one and a half times the budget, $4,872, the manager starts no new lane (`SCOPE-AND-DELIVERY.md:49`). The ask line is the owner's (`SCOPE-AND-DELIVERY.md:38`), and the owner set it at $750 (O78), so decision D1 carries the ask with the pilot's measured costs, which replace every guess in this table.

## Exit checks

Each check is Met or Moved to a named backlog row with its severity (`SCOPE-AND-DELIVERY.md:45`). The commands run in the primary checkout at origin/main, with `SCR` set to the records folder and `T` to the target Preview. The manager writes `SCR/works.txt` (one work id a line) and `SCR/shots.txt` (a part folder and a shot id a line) from CHAPTER-MAP when wave 1 starts.

| Id | Check |
|---|---|
| X1 | Every chapter passes strict lint, and the whole manual passes the strict render |
| X2 | Every chapter file carries `lead_approved: true` and `brand_reviewed: true` |
| X3 | Each of the 87 works in `SCR/works.txt` has its decision log and a final fidelity report with no false row, which for a tutorial includes every expected result checked against its recorded log |
| X4 | Every shot the plan names in `SCR/shots.txt` has a recipe that records a capture on the target Preview |
| X5 | Every Further reading citation resolved with a matching title |
| X6 | The last docs push carries unit-tier evidence |

```bash
# X1
bash "$SCR/render.sh" . $(git ls-files 'docs/user-manual/chapters/*.md' 'docs/user-manual/chapters/*/*.md')
# X2, prints nothing
find docs/user-manual/chapters -name '*.md' ! -name README.md -exec awk '/^lead_approved: true$/{a=1} /^brand_reviewed: true$/{b=1} END{if(!(a&&b))print FILENAME}' {} \;
# X3, prints nothing
while read w; do test -f "$SCR/codex/decisions/$w.md" && grep -qx 'FALSE ROWS: 0' "$SCR/reviews/$w-F-final.md" || echo "$w"; done < "$SCR/works.txt"
# X4, prints nothing (each line of shots.txt is a part folder and a shot id)
while read p s; do head -1 "docs/user-manual/assets/recipes/$p/$s.yaml" | grep -q "Lungfish Preview $T" || echo "$s"; done < "$SCR/shots.txt"
# X5, prints nothing
awk -F'\t' 'NR>1 && $5!="resolved"' "$SCR/ref/citations.tsv"
# X6, prints exact or inherited
python3 scripts/release/gate_evidence.py unit-evidence --root . --commit origin/main
```

## Owner list

These rows need the owner, full-screen control or a live service, so none is an exit check.

| Row | Why it is the owner's |
|---|---|
| Read the Docs `latest` shows the target Preview's version line and the RNA-seq and Tutorials parts | a live service, run as a smoke with its time |
| The media go for the first manual-media push and asset upload | `SCR/briefs/PROCESS.md:27` |
| Captures that need full-screen control | the owner answers each time and says in chat that they are at the Mac |
| Spend past the ask line | decision D1 |
| An RNA-seq demo project archive | a release asset upload, decision D7 |

## Decisions open

A question with no answer after 15 minutes takes the default below (`SCOPE-AND-DELIVERY.md:36`), except D1, D2 and D7, which stay the owner's.

| Id | Decision | Who | Default if no answer comes |
|---|---|---|---|
| D1 | Spending past the $750 ask line toward $3,248 | owner | Answered 2026-11-21, "Approve with reports". The job may spend up to about $3,550 (the pilot report's measured total). $750 spent and the end of wave 1 are progress reports to the coordinator (spent, chapters done, false rows, Sol tokens), not stops. If the measured total heads past about $3,550, start no new chain and tell the coordinator first |
| D2 | The media go | owner | Chapters with new shots stay on the branch, and final text-only chapters push |
| D3 | The target Preview | coordinator | ux-text's Preview for the whole manual, with unchanged surfaces captured on 2026.11.15 where they match. If it has not published by the reset, the target is 2026.11.15 and ux-text's surfaces keep waiting |
| D4 | The scope of Stage B | coordinator | The 87 works above |
| D5 | The pilot arm that scales | coordinator | Answered 2026-11-21 with the combination of `SCR/pilot/REPORT.md` (round 1 of the loop with a length target, the Opus check and one fix turn, a second critique round only if a FACT or SCOPE objection survives, two final F reviews merged and fix turns to `FALSE ROWS 0`), now `SCR/codex/PROTOCOL.md` Version 2. Stage A gains step F2. Measured on the first wave 1 chapter before it scales Refined at 23:29 after the measure on N-RNA1 (P1): the BIO read runs beside the two final F reviews, and all three merge into one fix turn, then one check. A narrow P2 also applies. The orchestrator makes token-level fact swaps itself, without a Sol turn: a number, name, menu path, flag, file name or unit. It logs each as FACT-DIRECT in the decision log, and any other wording change goes to Sol. The owner hears of the narrow P2 and may widen or drop it. |
| D6 | The tutorial template in `STYLE.md` | coordinator | The documentation-lead writes it from `ARCHITECTURE.md:145-150` as gate 1 of T-SEQ |
| D7 | An RNA-seq demo project archive | owner | None. T-RNA runs on the docs fixture folders |
| D8 | The Linux run of the N-LINUX fixture | coordinator | `run-local.sh` in a Linux container on galah, else F-10's returned runs and `Tests/Fixtures/htcondor` |
| D9 | B and gate 2 after Stage B, a change to the process design | coordinator | As this plan sets |
| D10 | The method for the remaining chapters, after the A/B pilot (`SCR/ab/RESULTS.md`: on 03-reads/03 a source-cited Claude pass at $7.01 rated 21/25 blind against the gold's 17/25 at about $54) | owner | Answered 2026-11-22: "It is fine to not use Sol if the agents judged the Claude-only content to be just as good." The next session runs the method study first (arm 1, arm 1 plus a rules pass, arm 1 plus one Sol copy edit, against the gold, on four chapter kinds), then uses the cheapest arm the blind judges find equivalent. Sol stays out unless its version is judged better. `SCR/codex/PROTOCOL.md`, "Method choice rule" |
| D11 | The method for the remaining chapters, after the method study (`SCR/study/RESULTS.md`: no cheaper arm was equivalent to the gold on 3 of 4 chapters, and every miss was an A1 fact error that one F1 check let through; the Sol arm A1S scored above the Claude-only arm on 4 of 4) | owner | Answered 2026-11-23 in the docs-refresh session: "Option 1". That is A1S plus F2, a second full fact and rules check of the final text with its fixes applied by script, at about $14 to $17 a chapter. It is first confirmed blind on the same four chapters (about $35 to $45) and adopted if the judges find it equivalent to the gold on at least 3 of 4. Otherwise the manager reports back to the owner, and the current loop stays meanwhile |
| D12 | The method after the Option 1 confirmation (`SCR/study/CONFIRM.md` section 6: A1S plus F2 equivalent to the gold on 1 of 4 chapters; the app-behaviour A errors of 06/02 and 04/02 survived the second check, and 11/01 failed on rule breaks) | owner | Answered 2026-11-23 in the docs-refresh session: "Current process". The remaining chapters run the current loop at about $54 a chapter. The manager reports spend at each $750 step and asks the owner before the job passes the $3,550 of D1 |
| D13 | Backing off the final stage, after the 06/05 and 06/09 final stages (about $74 of session spend on 2026-11-23 evening for two chapters plus the Not judged fixes, with 10 review agents and 4 Sol fix turns per chapter after its Sol stage) | owner | Answered 2026-11-24 in the docs-refresh session: "I think that's good. Let's use the trimmed final stage." For the remaining chapters, starting with 06/03: one final F review instead of two, plus the BIO read (skipped where a chapter has little science); gate 2's rules review runs on the same text at the same time, with the brand pass folded into it; one merged fix turn for facts, science and rules; one check, whose rows go in as exact replacements confirmed by script; gate 2's recheck of the changed lines. Caps 80 tool calls for the F review and 40 for checks. About 5 review agents and 2 Sol fix turns per chapter after the Sol stage, about half the Claude spend of that stage. The optional manager-effort change was not part of the answer and is not made |
