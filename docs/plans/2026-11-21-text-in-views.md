# Text in views (sub-phase 5.6)

**Status:** active. The planner of the ux-text job drafted this plan on 2026-11-21 from round 1 of its panel meeting and applied round 2 the same day, at base `c2612e446`. Every repository `path:line` is read at that commit. SCR is `~/lungfish-phase-records/ux-text/`. The six inventories are in `SCR/inv/` (UX leads, and `SCR/inv/UX-INVENTORY.md` holds its measure), the rulings in `SCR/rulings/`, round 2 in `SCR/challenge/` (votes in `TALLY.md`, each line's fate in `APPLIED.md`, opposed lines in `SPLITS.md`), the lane briefs in `SCR/briefs/lane-TV-*.md` and the copy-edit files in `SCR/codex/`. The full ranked inventory is `docs/plans/2026-11-21-text-in-views-inventory.md`. The last plan, `docs/plans/2026-11-19-single-cell-embedding-view.md`, binds wherever this file is silent. This file changes its rows 5.5 W1, 5.5 I3 and 5.5 V5 only through the rows under Revisits, each with round 2's vote.

## Owner direction

- 2026-11-21, while watching the walk: "I haven't personally explored the functionality yet but while watching the testing I noticed how much text was in the viewport. Is this desirable? Could some of the text be progressively disclosed as needed, or otherwise presented in an HIG compliant way?"
- 2026-11-21, then: "Make the plan and then implement. You should also use ChatGPT Codex 6.2 Sol Medium as a copy editor. It tends to write better and more concisely than Claude, so perhaps it can help determine better, more straightforward phrasing to use in the dialogs and help. You can use the GUI which is on the screen via computer use or use codex from the command line."
- 2026-11-21, said of the docs job and applied to this job's in-app strings by the coordinator, who told the owner (the owner can narrow it): "This is OK but the Sol edited text can become the documentation prose. It shouldn't be limited to only providing suggestions."
- 2026-11-19, the go for this account, in the parts still in force: the standing go O126 (fast-forward pushes of `main` through the hook, and Preview publishes once the full contract chain passes), "Full-screen control at galah: ask me each time", and "Week limit in this account: start no new work at 92%". No `--no-verify`.
- O159: no stable release. This job ends in a Preview.
- 2026-10-12: docs and screenshots wait until all phases end. In-app help tags, popovers and disclosure are in scope. A user-manual chapter is in scope only if the panel finds a reason, and it finds none (5.6 U6).
- 2026-11-06: the panel decides owner decisions, so it decides the placement (5.6 P1). Biomark X (Phase 6) still waits for the owner's word.

The owner said to implement, so the build starts after round 2 with no further go (`SCR/START-UX-TEXT.md:55`).

## User outcome

A person who opens the cell map, the Demultiplex Barcodes dialog or the pseudobulk dialog sees the controls, the data and the facts true of this result. Each general explanation is one click away, behind an info button beside what it explains. The Inspector names the open RNA-seq result and holds its provenance, the cell map's selection line reads whole and its plot takes the larger share. Every Operations dialog shows one readiness line and no section without a control. Every ruled caveat stays in view or one click away, with the meaning BIO ruled. The next Preview carries this after a packaged walk of the changed screens (`docs/contracts/SCOPE-AND-DELIVERY.md:26`).

At the base:
- Cell map: about 190 words in the control column in the walk's state (`SCR/inv/UX-INVENTORY.md:29`). The column is a fixed 320 pt (`Sources/LungfishRNASeqUI/CellMap/RNASeqCellMapViewController.swift:178`), so the plot gets the view less 368 pt (`:182-183`). The selection label does not wrap (`:78`) and holds an 11-word sentence (`Sources/LungfishRNASeqUI/CellMap/RNASeqEmbeddingSelection.swift:24`).
- Inspector: "No Bundle Loaded" (`Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift:1614-1617`), since `updateRNASeqResultDocument` sets no document state and selects the Bundle tab (`Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift:357-363`).
- Demultiplex: 93 words in the pane, up to 176 with a refusal (`SCR/inv/UX-INVENTORY.md:30-32`). The readiness line shows twice (`Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift:126-133`, `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift:126-130`). Advanced Settings is always listed (`Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:997`) and holds one sentence for demultiplexing (`FASTQOperationToolPanes.swift:949`).
- Pseudobulk: 77 words in the pane and about 110 in the sidebar cards (`SCR/inv/UX-INVENTORY.md:33`), with the readiness line twice (`Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift:42,151-161`).
- The app: 55,919 words in view across 524 surfaces and 5,338 behind help tags (`SCR/inv/UX-INVENTORY.md:117`).

## Budget

| Item | Count | Each | Sum |
|---|---:|---:|---:|
| Lanes | 8 | $24 | $192 |
| Session | 1 | $120 | $120 |
| Packaged candidates | 2 | $100 | $200 |
| **Total** | | | **$512, 25.6 points of the week at $20 a point** |

- Lane cost. TV-HELP adds a public Kit type, which is not a bundle kind, a viewer or a launch, so it costs $24 like the rest (`SCOPE-AND-DELIVERY.md:46`, QA in round 2).
- Session size. Eight lanes is under the 12 of `SCOPE-AND-DELIVERY.md:47`, so the job runs as a short job: no monitor, only the ledger command. Round 2 ran anyway, because the coordinator asked for both rounds (`SCR/briefs/PLAN.md:32`). The week stood at 12% at 16:55 on 2026-11-21 (`SCR/START-UX-TEXT.md:67`), above the 35 free points the row asks.
- Stop line. At $768, one and a half times the budget, the manager starts no new lane (`SCOPE-AND-DELIVERY.md:49`). The ask line stays the owner's (`:38`).
- Cut order, first cut to last: TV-SCVIEW, TV-PSEUDOBULK, TV-DEMUX, TV-SHELL. TV-HELP, TV-INSPECT, TV-CELLMAP and TV-NOTES are not cut, since the owner saw the cell map and the Preview needs its notes.

## Where words go (5.6 U1)

The rule (UX's, `SCR/inv/UX.md:24-49`, with BIO R3 and R8). Words go in one of six places.

1. **In view.**
   - Controls and their labels, and the data.
   - Facts exceptional for this result, true of this result or these settings and not of every one: a count left out, imported rather than computed, computed on other counts, a degraded fact such as "method Not recorded", the reason Run is off.
   - Every refusal, failure and warning (UX 8, UX 2), and the AFFECTED sentence (`SCOPE-AND-DELIVERY.md:107`).
   - An exceptional fact takes one line where it can, at most about 20 words, and its general reason sits one click away. No disclosure that is closed by default holds an exceptional fact.
2. **One click away.** General explanation, true of every result of its kind: how to read t-SNE, what a cluster number is, how an engine works, a file format.
   - Its home is an info button beside the control or the data it explains. The button shows `info.circle` (the round `?` button opens app help), takes keyboard focus, carries the VoiceOver label "About <thing>", and opens a transient popover that Space opens and Esc closes, with no Esc reaching the window behind.
   - Optional settings sit in a disclosure group, closed by default.
   - A general ruled caveat lives here.
3. **Help tag.** A short phrase on a control that says what it does, with the same text as its AXHelp (`.lungfishHelp` and `applyLungfishHelp`, `Sources/LungfishKit/LungfishHelpContent.swift:1026-1029,1048-1051`), at most 20 words (`Tests/LungfishKitTests/LungfishHelpContentTests.swift:76-82`). It is never the only home of a ruled caveat or a refusal, since a keyboard user and a background walk cannot hover. A plot or other data canvas takes no help tag, since its hover shows the data (`RNASeqCellMapViewController.swift:102`).
4. **Inspector.** Provenance goes in the Provenance tab: source files with their sha256, tool and version, parent result and command. A selection's descriptive facts go in their own tab. New rows keep Copy text and VoiceOver order (UX 5).
5. **Dialogs.** One readiness line, in the footer beside Run. No section without a control. No Overview that repeats the selected card. A card subtitle of one line, with the rest in the card's help tag. A field caption of one line, only for a limit the person must act on.
6. **Help Book.** Long teaching. It waits with the manual (2026-10-12), so this job writes no Help Book page and every popover stands on its own.

One fact shows in one place in view.

The HIG pages it rests on, at `https://developer.apple.com/design/human-interface-guidelines/` plus the slug (each answered HTTP 200 on 2026-11-21, `SCR/inv/UX.md:51`): Offering help `offering-help`, Popovers `popovers`, Disclosure controls `disclosure-controls`, Panels `panels`, Split views `split-views`, Layout `layout`, Writing `writing`, Buttons `buttons`, Accessibility `accessibility`. No page has the slug `inspectors` or `help-buttons`. The fact-check reads each claim of the README section against its page.

Where it lives: both. TV-HELP writes the full rule as a section Where words go of `docs/design/design-system/README.md`, after Content fundamentals (`:14-26`). The README has no size cap, and `docs/design/**` is not a release-neutral path (`config/release-contract.json:97-110`), so the section rides that code lane. In the same commit TV-HELP adds after UX 8 (`docs/contracts/EXPERT-PANEL.md:68`) the row `| UX 9 | Placement follows the design-system README, Where words go. |` (71 bytes with its newline). `EXPERT-PANEL.md` is at 10,239 of 10,240 bytes, so the commit frees 77 bytes, measured in `SCR/scratch/PLAN/bytes.txt` and confirmed by ARCH in round 2 (the file ends at 10,233 bytes):
- `:24`, first sentence, becomes "Fresh `lge-review` agents review a lane as SAD Bounded reviews sets, plus the fact-check for user-facing text." (37 bytes; the rule is `SCOPE-AND-DELIVERY.md:70`);
- `:15`, the co-opt sentence drops "for that phase" and writes "its remit" for "the field's remit" (23);
- `:19` drops "and a short job", which `SCOPE-AND-DELIVERY.md:47` already says (13);
- `:67` writes "the notes" for "release notes" (4).
`python3 scripts/checks/contract-size.py` passes after it.

## Placement (5.6 P1)

Sub-phase 5.6. All five seats wrote 5.6 (`SCR/inv/UX.md:5`, `BIO.md:5`, `SWIFT.md:5`, `ARCH.md:5`, `QA.md:7`). Phase now is 5 (`docs/plans/BACKLOG.md:3`). The ranked surfaces are Phase 5 RNA-seq views whose words carry 5.5 rulings, or dialogs the walk met. Phase 6 is Biomark X, which waits for the owner's word, so placing the job there would hold it. A sub-phase with a change a user can see ends in a Preview (`SCOPE-AND-DELIVERY.md:26`).

## Scope: the ranked inventory

UX's script counts the in-view words of every surface's literals, all states summed (`SCR/inv/UX-INVENTORY.md:5-23`). The cell map and the Operations dialogs come first. The full table of 45 viewports, dialogs and Inspector tabs, and the outcome-only surfaces, is in `docs/plans/2026-11-21-text-in-views-inventory.md`, each row with its lane or "no lane" and the reason. Its top rows:

| Rank | Surface | Prose words | Longest line | Lane |
|---:|---|---:|---|---|
| 12 | Cell map view | 461 | `Sources/LungfishRNASeqUI/CellMap/RNASeqEmbeddingWords.swift:39` | TV-CELLMAP |
| 1 | FASTQ/FASTA Operations dialog | 1,715 | `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState+ChanceCaption.swift:109` | TV-SHELL (sections), TV-DEMUX (demultiplex pane) |
| 4 | Workflow Operations dialog | 777 | `Sources/LungfishApp/Views/WorkflowOperations/RNASeqWorkflowPanes.swift:33` | TV-SHELL (sections), TV-PSEUDOBULK (pseudobulk pane, cards) |
| none | Inspector Bundle tab on an RNA-seq result | 12 | `DocumentSection.swift:1614-1617` | TV-INSPECT |
| 14 | Inspector Provenance tab | 365 | `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel+NodeRuntime.swift:32` | TV-INSPECT shows the cell map's provenance there, with no word change |
| 25 | The other five dialogs of the shell | | `Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift:4` | TV-SHELL item 1 (one readiness line in all seven) |
| 28 | Single-cell result view | 154 | `Sources/LungfishRNASeqUI/SingleCell/RNASeqSingleCellSummary.swift:26` | TV-SCVIEW |
| none | Bulk RNA-seq view | 58 | `Sources/LungfishRNASeqUI/Bulk/RNASeqBulkViewController.swift:235,257` | TV-SCVIEW |
| 2 | Inspector shell | 990 | `Sources/LungfishApp/Views/Inspector/InspectorViewController+TrimDuplicateWorkflows.swift:334` | no lane: launch refusals and alerts, which stay (UX 8) |
| 3 | Import Center | 831 | `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel+ActionText.swift:40` | no lane: no walk met it, and the rule binds the next lane that edits it |
| 5 | Genotype result | 656 | `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:3698` | no lane: outcomes of one result, exceptional |
| 6 | Primer design dialog | 631 | `Sources/LungfishApp/Views/PrimerDesign/PrimerDesignDialog.swift:243` | no lane: general rules fit a popover, but no walk met them |

## The three surfaces, paragraph by paragraph

Ledger ids are BIO's (`SCR/inv/BIO.md:14-57`). "Item" is the work item of the lane brief.

**Cell map**, pbmc_1k_v3-tsne coloured by graphclust (walk shot a-B1). About 190 words in view now, about 30 after.

| Id | Words now | Ruling | Place | Item |
|---|---|---|---|---|
| C1 | W1 caption, UMAP and t-SNE, `RNASeqEmbeddingWords.swift:39` | 5.5 W1 | popover "About <method>" beside Embedding | TV-CELLMAP 1 |
| C2, C3 | W6 PHATE and the neutral captions, `:41-45` | 5.5 W1 | same popover. "method Not recorded" stays in view (BIO 4) | TV-CELLMAP 1 |
| C4 | W4 imported coordinates, `:62`, and the Source fact, `RNASeqCellMapViewController.swift:483,495` | 5.5 W1, V5 | one line in view: imported, with "not computed by LGE" whole, or "Computed by <tool> <version>" whole (`:497-498`). The sha256 goes to the Inspector | TV-CELLMAP 1 |
| C5 | I3 other counts, `RNASeqEmbeddingWords.swift:72` | 5.5 I3 | "computed on other counts" in view word for word. The clause after "so" goes to the popover | TV-CELLMAP 1 |
| C6 | Left out, `:77`, laid at `RNASeqCellMapViewController.swift:460-462`, and Cells drawn, `:487` | 5.5 I3 | in view, each sample's count. For one sample, merged with Cells drawn, keeping the count and "no coordinates in <embedding>" | TV-CELLMAP 1 |
| C8, C9 | W2 computed clusters and W3 cluster numbers, `RNASeqEmbeddingWords.swift:56,58` | 5.5 W1 | popover "About clusters" beside Colour by | TV-CELLMAP 1 |
| C10 | W4 imported labels, `:67`, and the Labels fact, `RNASeqCellMapViewController.swift:485` | 5.5 W1, V5 | as C4, under Colour by | TV-CELLMAP 1 |
| C7 | Unlabelled cells, `RNASeqEmbeddingWords.swift:82`, already legend words, one a sample (`RNASeqCellMapModel.swift:148-150`) | 5.5 L3 | stays in the legend, each sample's count with its name, shorter. "draw in grey under the others" may go to the clusters popover. No unlabelled line is a selection target (`RNASeqCellMapViewController.swift:444`) and none sums samples (5.6 B5) | TV-CELLMAP 1 |
| C14 | W5 gene and grey cells, `RNASeqEmbeddingGenePicker.swift:130` | 5.5 W1, G1 | unit and grey key in view. The dropout clause goes to a popover beside the legend. "not expressed" and "off" stay forbidden | TV-CELLMAP 1 |
| C12, C13 | Scale words, `RNASeqEmbeddingWords.swift:89,93-105`, with the third state `scaleToMaximum`, `:97-98` | format Bounds | p99, the maximum, the grey key and the all-zero line in view. When the top is the maximum, an exceptional line keeps "at least 99% of the <N> cells have 0" and "the largest value". The definition goes to the popover | TV-CELLMAP 1 |
| C15 | Normalised formula, `RNASeqEmbeddingLegend.swift:125` | 5.5 G1 | stays in the legend (5.6 B2) | none |
| C11 | Colours repeat after 19, `RNASeqEmbeddingWords.swift:85` | 5.5 V3 | stays in view | none |
| S1 | "No cells selected. Drag around cells, or click a legend row.", `RNASeqEmbeddingSelection.swift:24` | none | short in view, in a label that wraps. How to select goes to an info popover beside the selection line and to the plot's AX help, with no help tag on the plot | TV-CELLMAP 2 |
| S2 | One command cannot name the selection, `:25-26` | none | in view while true, shorter. The disabled buttons' help tags give the reason | TV-CELLMAP 2 |
| C16 | Under ten, `:38-40` | CM-SELECT-CLI-BIO 10 | in view, shorter | TV-CELLMAP 2 |
| C17 | Parent result and Embedding facts, `RNASeqCellMapViewController.swift:480-482` | 5.5 V5 | the parent path goes to the Inspector, and the UX words agent decides whether the parent's name keeps a line (C5 names it when the counts differ). The Embedding line goes, since the pop-up and the axis title say it, except a "Not recorded" method | TV-CELLMAP 1 |

The hover, failure and no-embedding lines stay (UX 8).

**Demultiplex**, Cutadapt with a built-in TruSeq kit (walk shot p-Efwd-1). 93 words in the pane now, at most 40 after.

| Id | Words now | Ruling | Place | Item |
|---|---|---|---|---|
| H | Header "Configure <tool> for the selected <type> data.", `FASTQOperationDialogState.swift:1275` | none | dropped, the selected card says it | TV-SHELL 3 |
| O | Overview, `FASTQOperationToolPanes.swift:89-94`, text `FASTQOperationDialogState.swift:1179`, card `:1995`, and the RNA-seq quant pane's Overview, `FASTQOperationRNASeqQuantPane.swift:126-128` | none | sections dropped, the summary becomes the card's help tag | TV-SHELL 3 |
| D1 | Custom Definition format, `FASTQOperationToolPanes.swift:665` | UX-WORDS-2 F4 (d), BIO-DUAL-FORM 4 | popover beside the definition source, the move recorded against F4 | TV-DEMUX 1 |
| D2-D4 | Engine explanations, `:1054-1056` | DEMUXSPLIT-UX review. D3 is true (BIO-EXACT-BARE-RC item 1) | popover "About engines" beside Engine, all three to compare. Each segment gets a one-line help tag | TV-DEMUX 1 |
| D7 | Long-read kit caption, `FASTQOperationDialogState.swift:1118-1119` | none | in view, shorter, keeping "Location and distance settings do not apply" and "assigned only when both ends carry the same barcode". The construct clause goes in the kit picker's help tag (SPLITS 1, settled) | TV-DEMUX 1 |
| D5 | Exact Bare chance caption, `FASTQOperationDialogState+ChanceCaption.swift:84-85` | UX-EXACT-BARE-WORDS, Known limit row 8 | in view, shorter only if "no chance check" and "only on reads that carry the barcodes in their sequence" hold | TV-DEMUX 2 |
| D6 | Keep Unchecked captions, `:102-114` | BIO-SATKIT-FLUIDIGM 3-4, DEMUX-FLOOR-SATURATED-KIT, DEMUX-EXACT-BARE-NO-FLOOR | in view (a refusal), shorter. "the run is refused", the route and "check each sample against your sample sheet" stay | TV-DEMUX 2 |
| D8 | Advanced filler, `FASTQOperationToolPanes.swift:949`, others `:828-958` | none | section dropped | TV-SHELL 2 |
| R | Readiness section, `:126-133` | none | dropped, the footer keeps the line | TV-SHELL 1 |
| X | Exact Bare refusal, `Sources/LungfishWorkflow/Demultiplex/DemultiplexError.swift:157-158` | BIO-EXACT-BARE-RC item 3, S3 (UX) | names the real limit, from the ruling's proposed text, true for each `return false` of the guard (`DemultiplexingPipeline+ExactBareMatching.swift:275-285`), so Custom Definitions are those "with no kit line" | TV-DEMUX 3 |

**Pseudobulk and Import Embedding panes** (walk shot b-F5). 77 words in the pseudobulk pane now, at most 40 after.

| Id | Words now | Ruling | Place | Item |
|---|---|---|---|---|
| O | Overview summary, `WorkflowOperationsDialog.swift:99-100`, text `Sources/LungfishApp/Services/WorkflowLibrary.swift:181` | none | the summary line goes. The Overview shows only while it holds Open Previous Run or Run Again, and neither shows for an RNA-seq tool with no replay (`:101,105`) | TV-SHELL 3 |
| R | Readiness section, `WorkflowOperationsDialog.swift:151-161` | none | dropped. The replay line goes to the footer, Check Configuration to the Run Again block | TV-SHELL 1 |
| E0 | "A single-cell .lungfishrnaseq result.", `RNASeqWorkflowPanes.swift:19` | none | help tag | TV-PSEUDOBULK 1 |
| E2 | Selection caption, `:22-23` | 5.5 S3 | first sentence in view, shorter. The labels-table sentence, a provenance fact, goes to the help tag | TV-PSEUDOBULK 1 |
| E1 | Groups under 10 left out, `:21` | pass rule 10 | in view, shorter, the 10 kept | TV-PSEUDOBULK 1 |
| F | Folder caption, `:24` | none | help tag. The readiness line says when the name exists | TV-PSEUDOBULK 1 |
| E3 | Import Embedding pane, other counts caption, `:33` | 5.5 I3 | unchanged, bound to C5 | none |
| E4 | Import Embedding pane, tool caption, `:29`, laid at `:437` | 5.5 I3, W4 | unchanged in view. The import pane is not one of the three surfaces | none |
| K | Card subtitles, `WorkflowLibrary.swift:147,181` | none | one line each, the rest in the card's help tag | TV-PSEUDOBULK 2 |
| E5 | W7, `Sources/LungfishWorkflow/RNASeq/RNASeqPseudobulk+CellMap.swift:15-17` | 5.5 S3 | if no app view shows it, an info button beside the selection field | TV-PSEUDOBULK 3 |

## Panel decisions

Ids are `5.6 <letter><n>`: P placement, U words and placement, L layout, A architecture, B science, Q tests. Round 2 closed every row the draft left open (`SCR/challenge/APPLIED.md`).

| Id | Decision | Source |
|---|---|---|
| 5.6 P1 | Sub-phase 5.6 (section Placement) | all five inventories |
| 5.6 U1 | The rule of section Where words go | `SCR/inv/UX.md:24-63` |
| 5.6 U2 | Each general caveat gets an info button beside the control or data it explains, never one button for a whole surface | BIO Q-U1, `SCR/inv/BIO.md:102` |
| 5.6 U3 | One click meets the BIO condition. The info button is also reached by VoiceOver and, with keyboard navigation on, by Space. A help tag alone never does, and no menu item is added. Tests pin what holds under either keyboard setting: `refusesFirstResponder` false, and a Space key event opens the popover. Tab focus is an owner list row | SWIFT Q-S2, QA Q-Q1, `SCR/inv/SWIFT.md:69-70`, SWIFT round 2 |
| 5.6 U4 | Section headings take sentence case in the seven dialogs and the panes they embed: `DatasetOperationsModels.swift:18,20`, `AssemblyWizardSheet.swift:510,600`, `ViralReconWizardSheet.swift:268`, `BAMPrimerTrimToolPanes.swift:34`, `MappingWizardSheet.swift:215`, `UnifiedMetagenomicsWizard.swift:48` and `IQTreeInferenceDialog.swift:176` (TV-SHELL), and the `RNASeqPaneGroup` titles such as `RNASeqWorkflowPanes.swift:288,296` (TV-PSEUDOBULK). Each new heading gets an `XCTAssertEqual` pin, and the pins at `MappingWizardSheetTests.swift:47` and `IQTreeInferenceOptionsDialogTests.swift:48` change in the same commit. Product names ("Viral Recon"), buttons, menu items, pickers and disclosure group labels keep title case. No XCUI test reads a heading | `docs/design/design-system/README.md:22`, UX and QA round 2 |
| 5.6 U5 | Spelling. Each surface keeps its own spelling and stays consistent within itself: the cell map is British (Colour by, Normalised, grey, `RNASeqCellMapViewController.swift:144`), the Operations dialogs US. A string moved between surfaces takes the spelling of its new surface. One spelling for the whole app is not this job | `SCR/briefs/PLAN.md:30`, `SCR/codex/preamble.md:15` |
| 5.6 U6 | No Help Book page, no user-manual chapter and no manual link in this job: docs-refresh rewrites the chapters now, so an anchor may not exist at publish. The info button takes no link parameter. The lane that first links a popover to the manual adds one, built from `DemoProjectManifest.manualBaseURL` as the peer agreed | `SCR/inv/ARCH.md:69`, `SCR/briefs/PLAN.md:36`, ARCH round 2, owner 2026-10-12 |
| 5.6 U7 | Word ceilings, each held by a test beside the per-id placement tests and never in their place: 40 words in the cell map's walk state (pbmc_1k_v3-tsne coloured by graphclust, no selection, imported coordinates and labels, and the other-counts line if the record has it), 40 in the demultiplex pane with Cutadapt and a built-in TruSeq kit, and 40 in the pseudobulk pane opened from a legend selection. The count reads drawn, visible static text only, leaves out control titles by type and legend rows, runs on a fixed fixture with fixed sample names, and has a negative test (a hidden label and a button title leave it unchanged). Every other state a lane's tests build reads no more words at the head than at the base. A ruled line wins: if the ruled lines alone pass 40, UX sets the bar at the measured count and records it with the base count | UX and QA round 2 |
| 5.6 U8 | `docs/user-manual/features.yaml` belongs to docs-refresh. Each lane lists its visible changes in its report, and the manager sends them to docs-refresh for UX 7's row | `docs/contracts/EXPERT-PANEL.md:67`, peer agreement 2026-11-21 |
| 5.6 L1 | The cell map's control column narrows to a fixed 240 pt, so the plot gets 753 - 240 - 48 = 465 pt of a 753 pt viewer, 61.8%. One width constant sets the column and every wrap width in it (`RNASeqCellMapViewController.swift:112,178,614`, `RNASeqEmbeddingLegend.swift:127,135`), so content fits its 212 pt. A pop-up title or legend name that does not fit truncates with a tail ellipsis and keeps its full name in its AX label and help tag. `RNASeqResultSurface` answers `pinsTopToSafeArea` true so the header starts under the toolbar. If T1 shows clipped legend names, a resizable split becomes a later row | `:139,182-183`, `Sources/LungfishKit/Surfaces/ResultViewport.swift:94-96`, UX and SWIFT round 2 |
| 5.6 A1 | One new LungfishKit file holds the AppKit info button. Its SwiftUI form wraps that button as an `NSViewRepresentable`, so one popover, one AX surface and one Esc behaviour serve both. The button makes its popover's window key, or offers a close-if-shown call that each Esc path makes first, so no Esc reaches the window behind as a keyDown or a `cancelOperation` (the Operations dialogs bind Esc to Cancel, `DatasetOperationsDialog.swift:133`, `WorkflowOperationsDialog.swift:935`). Its popover sizes from its content. A leaf builds its `HelpItem`s in its own module from its own constants, and its tests run TV-HELP's public catalog check (unique id, a summary of at most 20 words, the banned words). Items already in Kit stay in `allItems`, so `LungfishHelpContent.swift` holds its 1,052 lines | `SCR/inv/ARCH.md:59`, `scripts/ratchets/file-size.baseline:126`, SWIFT R1, R5, SWIFT and ARCH round 2 |
| 5.6 A2 | The shells change by deleting `DatasetOperationSection.readiness` (`DatasetOperationsModels.swift:9,23-24`) and editing each pane, with no shared section-stack view. A standalone wizard keeps its one Readiness. `DatasetOperationToolSidebarItem` gains a defaulted `help: String? = nil` for the card's help tag (`:43-60`), so the other dialogs' constructors stay as they are | `SCR/inv/ARCH.md:61-65`, R5, ARCH round 2 |
| 5.6 A3 | The Inspector binding: an `RNASeqResultDocumentState` in a new file with a header part, which `onLoaded` sets, and a cell map part, which a sibling closure of `onLoaded` on the surface sets (`Sources/LungfishRNASeqUI/RNASeqResultSurface.swift:63-64,109`). Each setter replaces only its own part for the same bundle URL, so the cell map part survives first open, whichever order the two arrive in. The surface implements `willDeactivate` to close the cell map and drop the closure, `close()` and a failed reread publish an empty cell map part, and the App drops a publish for a bundle that is not the Inspector's current RNA-seq target. A shared clear helper nets `DocumentSection.swift` down, and `updateRNASeqResultDocument` moves to a new `InspectorViewController+RNASeq.swift` by a pure move first. The payload is the tuple shape of `RNASeqResultFacts.rows` (`:41-43`) or a new public RNASeqUI type, and a new type regenerates the module map | `SCR/inv/SWIFT.md:50-57`, ARCH and SWIFT round 2 |
| 5.6 B1 | A ruled caveat changes words only when BIO confirms each row on the terms of `SCR/inv/BIO.md:71`. Each confirmed row goes in `SCR/rulings/BIO-WORDS-UXTEXT.md` with its ledger id and the ruling it amends. A move with no word change still needs BIO's check that it is one click away | `SCR/inv/BIO.md:67-73` |
| 5.6 B2 | 5.5 G1 stands: the normalised formula stays in the legend | BIO C15, Q-B4 |
| 5.6 B3 | BIO alone checks the single-cell meaning of the cell map rows. SC is called for one ruling only if a W row changes in meaning | BIO Q-B5, R7 |
| 5.6 B4 | Ruling BIO-EXACT-BARE-RC closes Q-B1: the reverse-complement words are true, and D3 may be reworded like the other G rows. No probe row and no S1 or S2. Its item 3 rides TV-DEMUX at S3, the severity UX set (`SCOPE-AND-DELIVERY.md:78`). The new words hold for each `return false` of `supportsExactBareBarcodeDemux` (`Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline+ExactBareMatching.swift:275-285`), and BIO's confirmation row lists each case and whether a user can reach it. Items 4 and 5 stay in the ruling file | `SCR/rulings/BIO-EXACT-BARE-RC.md:3-7`, UX and BIO round 2 |
| 5.6 B5 | The view computes no number. A shorter line adds no number the CLI did not write | `docs/formats/rnaseq-cell-map.md:9`, BIO §2 |
| 5.6 Q1 | Each surface lane's first commit is tests only, passes at the base and pins the ordered AX children and the ruled-caveat ids. Placement tests check visibility, since `texts(in:)` counts hidden views | `SCR/inv/QA.md:69-90`, `Tests/LungfishRNASeqUITests/CellMap/RNASeqCellMapViewModelTests.swift:291-299` |
| 5.6 Q2 | No full tier in 5.6. No Preview is promoted, and the Phase 5 close runs it, covering from the last full tier, GATE PASS at `a8384152d` on 2026-11-11 (`docs/reports/2026.11.7-technical.md:93`). If the owner asks to promote the 5.6 Preview, the full tier runs then (`VERIFICATION-ORDER.md:57`) | `docs/contracts/VERIFICATION-ORDER.md:46`, QA round 2 |
| 5.6 Q3 | `DemultiplexEngine.exactBareChanceWords` stays as it is, since the CLI summary and the Log read it. A shorter view caption takes its own constant | `SCR/inv/QA.md:62-65`, R7 |
| 5.6 Q4 | A lane that moves words the binding XCUI reads runs those classes once at its base and once at its head before landing: TV-DEMUX the two demultiplex classes, TV-CELLMAP `testReleaseCandidateViewSwitchPerKind`, which reads the selection words and a bare legend count (`Tests/LungfishXCUITests/ReleaseCandidateSmokeXCUITests.swift:455-474`). Only the candidate's smoke counts as evidence | `config/release-contract.json:88-92`, QA R6, QA round 2 |

## Revisits

Each row changes a 5.5 decision (`docs/contracts/EXPERT-PANEL.md:32`). The vote is round 2's (`SCR/challenge/TALLY.md`): a majority of the seats that vote carries, and an abstention is not counted.

| Id | New decision | Evidence | Vote |
|---|---|---|---|
| 5.5 W1 (revisit) | The general W words leave view for info buttons beside what they explain: W1, W6, the general clause of the neutral caption, W2, W3 and the dropout clause of W5. W4 joins its Source or Labels fact as one line in view. "method Not recorded" and the grey key of W5 stay in view. The forbidden words and the no-reproduce rule stand, and the moved words keep their meaning (5.6 B1) | BIO C1-C14, UX table rows 1-12, BIO Q-B3 | 5 yes (UX, BIO, SWIFT, ARCH, QA), 0 no: carries |
| 5.5 I3 (revisit) | "computed on other counts" stays in view word for word, and the clause after "so" leaves view. Each sample's left-out count stays in view. On a map of one sample it joins Cells drawn and keeps the count and "no coordinates in <embedding>", with only numbers the CLI wrote | BIO C5, C6, R1 | 2 yes (UX, BIO), 0 no, 3 abstain (SWIFT, ARCH, QA): carries |
| 5.5 V5 (revisit) | The parent path and both sha256 prefixes leave the view for the Inspector, in the lane after the Inspector shows them, and the cell map part survives first open (5.6 A3). Imported or computed, with "not computed by LGE" or "Computed by <tool> <version>" whole, and Cells drawn, stay in view. TV-INSPECT's test reads each expected value from the manifest. The reason of V5 ends with TV-INSPECT's net-down of both Inspector files | BIO C17, ARCH A3, SWIFT §3, `scripts/ratchets/file-size.baseline:22,24` | 5 yes (UX, BIO, SWIFT, ARCH, QA), 0 no: carries, on the conditions written here |

## Lane conditions

Every lane brief repeats these as checks.
- **BIO.** Every ruled caveat stays in view or one click away: an AX test finds its info button, presses it and reads text equal to the decided constant. In a SwiftUI pane the test hosts the pane in an `NSHostingView` and presses through AX, since ViewInspector cannot reach the wrapped AppKit button. Its words change only with BIO's recorded confirmation against its ruling (5.6 B1).
- **UX 5.** VoiceOver order is kept. The lane's tests-only first commit pins the ordered AX children at the base (5.6 Q1). After the move the order equals the pin, with each moved paragraph replaced at its own place by its info button.
- **QA 2.** A test that reads a label is updated in the commit that moves the label, never loosened. The reviewer counts assertions by id and by string at the base and at the head, and the head has as many or more. A view assertion deleted with a fact that moves to the Inspector counts as kept only when an assertion of the same id or string already stands in `InspectorRNASeqResultTests` at the head. New label assertions use `XCTAssertEqual` in a file that reads no source, so the `source-text-assertions` ratchet stays at or under 1,375 (`SCR/inv/QA.md:58`). A placement test checks visibility (`isHiddenOrHasHiddenAncestor` false and a frame inside the visible rect), not presence in the tree.
- **The two defects.** TV-INSPECT fixes the Inspector binding and TV-CELLMAP the clipped line, and no other lane edits them.
- **ARCH 6.** The report gives each baselined file's net line delta. Growth is raised only as `SCOPE-AND-DELIVERY.md:117` sets.
- **BIO 1.** No scientific payload or golden key changes (X4).

## The copy-edit flow

Words are decided inside each lane, after it moves the structure with the current words and before it commits new words. They are not decided in a words step for a wave, nor at review. The place sets a string's length (one line in view, about three sentences in a popover, 20 words in a help tag), so Sol needs the place first. QA 2 puts the words and the tests that read them in one commit, and BIO confirms before that commit (`SCR/inv/BIO.md:70`), so the words must be final before the lane commits. A words step for a whole wave would also hold three lanes on one agent.

1. The lane writes `SCR/codex/TV-<NAME>-in.md`: a table of id (the ledger id where one exists), where it lives (`path:line` and its place: in view, help tag, popover, disclosure or button), current text, RULED with its ruling id or "not ruled", and Claude's draft. A batch holds at most 40 strings. Placeholders such as `<sample>`, `<file>` and `\(count)` stand for real values. The input holds no home path, name, accession or unpublished data, and `run-codex.sh` refuses those and the word "token" (`SCR/codex/run-codex.sh:13-16`).
2. The lane runs `SCR/codex/run-codex.sh` with the literal paths of the in file and `SCR/codex/TV-<NAME>-out.md`. Only the lane or a words agent runs it. On a refusal or a failure the lane stops and tells the manager, and never switches model (`:31-34`).
3. Sol's wording is the final string by default. One `lge-ruling` UX agent, the words agent, writes `SCR/codex/TV-<NAME>-decided.md`: each string's final text and its outcome, Sol as written, Sol revised, or Claude rewrite with the reason. It changes or rejects a Sol string only for a logged reason: a wrong fact, a broken binding rule (the prose lint, the case rule, a RULED caveat's meaning, VoiceOver or label tests), or a string that does not fit its control or space. Taste alone is not a reason. An objection goes back to Sol through `run-codex.sh` with the objection on its row, and Claude rewrites a string only when Sol cannot meet the constraint, logged.
4. One `lge-ruling` BIO agent confirms each RULED row against its ruling id, writes "meaning holds, <ruling>" on it and adds its row to `SCR/rulings/BIO-WORDS-UXTEXT.md`, or sends the row back with its objection. A returned row goes to the words agent, which runs Sol again with BIO's objection on that row, as in step 3 (5.6 B1).
5. Every final string passes `AGENTS.md` section Writing docs, `docs/user-manual/build/scripts/lint/rules/ai-tells-words.txt` and UX 7 (title case for buttons and menu items, sentence case for the rest, 5.6 U4), and keeps its surface's spelling (5.6 U5). The words agent checks each one.
6. The lane applies the decided strings and their tests in one commit, only when every RULED row of the decided file reads "meaning holds, <ruling>". A row BIO has not cleared keeps its base words in that commit.
7. The `manual-fidelity-reviewer` checks the facts of the final strings at review, in slices of about 40 claims. A wrong fact is a fix that lands with the lane.
8. UX reads the session's new words once at the notes step (`SCOPE-AND-DELIVERY.md:70`).

## Lanes

Each lane ends at one milestone of at most three work items. None adds a bundle kind, a viewer or a launch. Reviews are `lge-review`, plus the fact-check for user-facing text. Paths are under `Sources/` unless they start with `docs/` or `Tests/`.

| Id | Files owned | Milestone | Order | Review | Agent |
|---|---|---|---|---|---|
| TV-HELP | new `LungfishKit/LungfishInfoButton.swift`, new `LungfishKit/LungfishHelpContent+Placement.swift` (the public catalog check), new `Tests/LungfishKitTests/LungfishInfoButtonTests.swift`, `docs/design/design-system/README.md`, `docs/contracts/EXPERT-PANEL.md`, `LungfishKit/AGENTS.md`, `docs/architecture/MODULES.md` (regenerated) | 1 the AppKit info button and popover, with no Esc reaching the window behind. 2 the SwiftUI form as an `NSViewRepresentable` of that button and the public catalog check, with AX tests in a hosted window of the label, `refusesFirstResponder` false, Space, Esc with a cancel button behind, and the text. 3 the README section and the UX 9 row with `contract-size.py` passing, the Kit AGENTS row and the module map | w1 | SWIFT | `lge-lane-opus` (design step) |
| TV-INSPECT | new `LungfishApp/Views/Inspector/InspectorViewController+RNASeq.swift`, new `LungfishApp/Views/Inspector/Sections/DocumentSection+RNASeq.swift`, `DocumentSection.swift`, `InspectorViewController+PublicAPI.swift`, `LungfishApp/Views/Viewer/ViewerViewController+RNASeq.swift`, the facts closure and `willDeactivate` of `LungfishRNASeqUI/RNASeqResultSurface.swift`, the publish calls in `refresh()`, `close()` and the failed reread of `RNASeqCellMapViewController.swift`, the RNA-seq routing rows and declared leaks, the Inspector step of `Tests/LungfishXCUITests/ReleaseCandidateSmokeXCUITests.swift`, and `docs/architecture/MODULES.md` with `LungfishRNASeqUI/AGENTS.md:17` if the payload is a new public type | 1 after a pure move, the Bundle tab shows the result's facts for bulk, single-cell and cell map. 2 the cell map part there from first open, following the embedding and colouring on show, and a test first that the Provenance tab lists the source files with their sha256. 3 a project switch, a switch from another kind, leaving the cell map and a failed reread clear it, and the routing rows and leak counts follow | w1 | SWIFT | `lge-lane-opus` (longest chain) |
| TV-SHELL | `LungfishApp/Views/Operations/DatasetOperationsModels.swift`, `DatasetOperationsDialog.swift`, `FASTQOperationDialogState.swift` (`:996-1003`, `:1162-1276`, `:2124-2127`), `FASTQOperationToolPanes.swift` (`:86-147`, `:823-958`), `WorkflowOperationsDialog.swift` (`:36-43`, `:98-161`), `WorkflowOperationDialogState.swift` (`:312-315`, `:513-514`, net zero lines), `FASTQOperationRNASeqQuantPane.swift`, `BAM/BAMVariantCallingToolPanes.swift`, `BAM/BAMPrimerTrimToolPanes.swift`, `Assembly/AssemblyWizardSheet.swift`, `Mapping/ViralReconWizardSheet.swift`, the heading lines of `Mapping/MappingWizardSheet.swift:215`, `Metagenomics/UnifiedMetagenomicsWizard.swift:48` and `Phylogenetics/IQTreeInferenceDialog.swift:176`, their tests, new `Tests/LungfishAppTests/OperationsDialogReadinessLineTests.swift` | 1 one readiness line, the footer, in all seven dialogs, the replay line and Check Configuration kept. 2 Advanced Settings only for a tool with a control there. 3 no Overview or header that repeats the card (FASTQ, RNA-seq quant and Workflow), the summary as the card's help tag, headings in sentence case (5.6 U4) | w1 | UX | `lge-lane` |
| TV-CELLMAP | `LungfishRNASeqUI/CellMap/RNASeqCellMapViewController.swift` (TV-INSPECT's publish calls stay), `RNASeqEmbeddingWords.swift`, `RNASeqEmbeddingSelection.swift`, `RNASeqEmbeddingGenePicker.swift`, `RNASeqEmbeddingLegend.swift`, `RNASeqCellMapModel.swift`, `pinsTopToSafeArea` in `RNASeqResultSurface.swift`, its help items, `docs/formats/rnaseq-cell-map.md` (bound lines), `Tests/LungfishRNASeqUITests/CellMap/`, the cell map step of the smoke | 1 the cell map rows of the table. 2 the selection words in a wrapping label with their info popover, and Esc from the plot, the legend or the controller closes a popover without clearing the selection. 3 the 240 pt column with one width constant, and the header (5.6 L1) | w2, after TV-HELP and TV-INSPECT | UX, BIO | `lge-lane-opus` (longest chain) |
| TV-DEMUX | `FASTQOperationToolPanes.swift` (`:650-700`, `:1050-1058`), `FASTQDemultiplexChanceRows.swift`, `FASTQOperationDialogState+ChanceCaption.swift`, `FASTQOperationDialogState.swift:1118-1119`, its help items, `LungfishWorkflow/Demultiplex/DemultiplexError.swift:157-158`, the demultiplex dialog tests, `ExactBareWordsXCUITests.swift`, `DemuxDualAnchorXCUITests.swift` | 1 D1 to D4 and D7 placed. 2 D5 and D6 in view, shorter only with BIO's word, with their own view constants. 3 the refusal words of BIO-EXACT-BARE-RC item 3, true for each case of the guard | w2, after TV-SHELL and TV-HELP | UX, BIO | `lge-lane` |
| TV-PSEUDOBULK | `LungfishApp/Views/WorkflowOperations/RNASeqWorkflowPanes.swift`, the card subtitles of `LungfishApp/Services/WorkflowLibrary.swift`, its help items, `Tests/LungfishAppTests/RNASeqPseudobulkDialogTests.swift`, `RNASeqPseudobulkDialogStateTests.swift` | 1 E0, E1, E2 and F placed, and the pane headings in sentence case. 2 card subtitles of one line. 3 W7 one click from the selection field if no app view shows it | w2, after TV-SHELL and TV-HELP | UX, BIO | `lge-lane` |
| TV-SCVIEW | `LungfishRNASeqUI/SingleCell/RNASeqSingleCellSummary.swift` (`:15`, `:26`), `RNASeqSingleCellViewController.swift` (`:147`, `:162`), `LungfishRNASeqUI/Bulk/RNASeqBulkViewController.swift` (`:233-258`), their tests | 1 the rank-plot words. 2 the cell map pointer line. 3 the bulk scale and progress lines | w3, after TV-HELP | UX | `lge-lane` |
| TV-NOTES | `docs/release-notes/<version>.md`, the record and owner check list in `docs/reports/` | 1 the notes. 2 the record and the check list before the last package. 3 the publish facts after the tag | after the last code landing | none (documentation only) | `lge-lane` |

## Order, waves and the candidate

- w1: TV-HELP, TV-INSPECT and TV-SHELL in parallel. The unit tier runs once after w1 lands. If both TV-HELP and TV-INSPECT change the module map, the second to land regenerates it again rather than merging by hand.
- w2: TV-CELLMAP, TV-DEMUX and TV-PSEUDOBULK, each when its predecessors land. The unit tier runs once after w2.
- w3: TV-SCVIEW may build from the moment TV-HELP lands (at most five builders, at a load under 40) and lands after w2's tier.
- The longest chain is TV-INSPECT then TV-CELLMAP. TV-SHELL and TV-DEMUX share `FASTQOperationToolPanes.swift`, TV-INSPECT and TV-CELLMAP share `RNASeqCellMapViewController.swift` and `RNASeqResultSurface.swift`, so each pair runs in that order.
- The candidate follows `docs/contracts/VERIFICATION-ORDER.md:26-30`: the unit tier once, TV-NOTES's notes and record committed, `package preview`, then at once the walk of T1, T2, T3 and T6, which are all new rows, where a finding ends the candidate. Then the replay suites, the golden compare and the executor replay once each (Sources changed, `:48`), the XCUI smoke, a walk of any screen changed since, `SCR/reviews/CANDIDATE-<commit>-QA.md` with its PASS line, `release.py setup`, then publish.

## Exit checks

Each ends Met, or Moved to a named backlog row with its severity.

| Check | Passes when |
|---|---|
| X1 | `swift test --skip-update --filter 'RNASeqCellMapViewControllerTests\|RNASeqCellMapViewWordsTests\|RNASeqEmbeddingSelectionTests\|RNASeqEmbeddingGeneTests\|RNASeqEmbeddingGeneControllerTests\|RNASeqResultSurfaceTests\|RNASeqCellMapViewFixtureTests\|RNASeqSingleCellViewTests\|RNASeqBulkQualityTests\|RNASeqBulkEvidenceTests\|RNASeqBulkTableTests\|LungfishInfoButtonTests\|LungfishHelpContentTests'` passes, and its new tests show each ruled caveat visible or one press away with its decided text, Esc from the plot, the legend and the controller closing a popover with the selection kept, AX order equal to the pin, every arranged subview of the column inside its insets at 1200 by 800 and at the minimum size, the plot at least 60% of a 753 pt viewer, and the ceilings of 5.6 U7 |
| X2 | `swift test --skip-update --filter 'FASTQOperationDialogRoutingTests\|FASTQOperationToolPanesSourceTests\|FASTQDialogKeepUncheckedSamplesTests\|FASTQDialogExactBareKeepUncheckedTests\|DatasetOperationsDialogTests\|OperationsDialogReadinessLineTests\|WorkflowOperationDialogStateTests\|RNASeqPseudobulkDialogTests\|RNASeqPseudobulkDialogStateTests\|IQTreeInferenceOptionsDialogTests\|MappingWizardSheetTests\|ViralReconWizardSheetTests\|AssemblyWizardSheetDefaultsTests\|AssemblyWizardSheetFlyeProfileTests\|AssemblyWizardCarefulModeTests\|BAMVariantCallingDialogRoutingTests\|DemultiplexingPipelineTests\|FastqRefusedRunKeepsEarlierOutputTests'` passes: `OperationsDialogReadinessLineTests` hosts each of the seven dialogs and finds the readiness text once (the footer's `status-text`), no section title stands without a control, the pseudobulk and RNA-seq quant states included, each moved paragraph is in its popover, and the demultiplex and pseudobulk states keep the ceilings of 5.6 U7 |
| X3 | `swift test --skip-update --filter 'RoutingTableSafetyNetTests\|ViewSwitchMatrixTests\|BundleKindParityTests\|InspectorProjectSwitchResetTests\|InspectorRNASeqResultTests'` passes: the bulk, single-cell and cell map rows show the result block and never "No Bundle Loaded", and the declared-leak counts fall by exactly the leaks closed |
| X4 | `python3 scripts/golden/golden.py compare` is clean with zero changed keys at the final candidate |
| X5 | `scripts/release/app_smoke_gate.py --channel preview` passes on the last packaged candidate with no skip, the demultiplex classes reading the words at their new place |
| X6 | Walk rows T1, T3 and T6 pass in background control on the packaged candidate, T2 and T5 pass or go to the owner list by their rows (their words then rest on X1's and X2's tests), no S1 or S2 is open, and the Preview is published |

## The walk and the owner list

| Row | Kind | Walk |
|---|---|---|
| T1 | background | Open pbmc_1k_v3-tsne coloured by graphclust at the walk's window size. In view are the controls, the legend with its counts, Cells drawn and this result's facts. No general paragraph shows, the selection line reads whole, the plot is wider than the column and the header's Name row sits under the toolbar. The legend counts equal the prep log, as 5.5 B1 did |
| T2 | background | Click the info buttons beside Embedding and beside Colour by. Each popover shows its words. If background tools cannot capture a popover, the row is logged as not walked, never as a Pass, and goes to the owner list with no walker |
| T3 | background | With the cell map open, the Inspector names the result and its facts, its Provenance tab lists the source file with its sha256, and it never reads "No Bundle Loaded" |
| T4 | full | Tools > Demultiplexing > Demultiplex Barcodes…, a built-in kit picked from its pop-up menu: one readiness line, no empty section, no Overview, the Exact Bare caption in view when Exact Bare is picked, the engine words one click away. It runs only after the owner says in chat that they are at the Mac, and otherwise goes to the owner list. X5 covers the demultiplex words either way |
| T5 | background | The pseudobulk dialog from a legend selection on the cell map, in the Workflow Operations window (`Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsWindowController.swift:84,118-123`): one readiness line and the decided helper lines. The route is the legend child's Select these cells action, then the Pseudobulk Selected Cells… button (`Sources/LungfishRNASeqUI/CellMap/RNASeqCellMapViewController.swift:81,116`), which the 5.5 walk drove in background (F5, `~/lungfish-phase-records/phase-5-5-sc-embed/events.log:257`). If background refuses, the row is logged as not walked and goes to the owner list (SPLITS 2, settled) |
| T6 | background | The single-cell result (walk shot a-B3) and a bulk result's Correlation tab: no general paragraph in view, info buttons beside the plots, the scale's numbers in view |

Owner list rows, which do not block (`SCOPE-AND-DELIVERY.md:25`): T4 and T5 unless walked; hover each new help tag; VoiceOver order by ear on the cell map and the demultiplex dialog; Esc from the keyboard on an open popover keeps the selection; Esc on an open info popover in the Demultiplex dialog keeps the dialog open; Tab reaches an info button with keyboard navigation on.

## The peer job, docs-refresh

docs-refresh (session local_457fb92d) owns `help-ids.yaml`, `docs/user-manual/**` and the nine Help Book pages (`Sources/LungfishApp/Resources/HelpBook/`, with fallbacks in `Sources/LungfishApp/Resources/Help/`, topics at `Sources/LungfishApp/Views/Help/HelpWindowController.swift:23-33`). No lane of this job edits them, and they stay with docs-refresh. This job owns `LungfishHelpContent.swift` and every Swift help control. It adds no link to the manual (5.6 U6). At the close the manager sends docs-refresh each new info button with its `HelpItem` id, and each lane's visible changes for `features.yaml` (5.6 U8).

## Backlog rows for the manager to commit

None. The seats found no S1 or S2. BIO-EXACT-BARE-RC closed Q-B1 with no probe row (5.6 B4), and TV-DEMUX fixes its S3 words. The "no lane" surfaces get no row: long words alone are S4 (`SCOPE-AND-DELIVERY.md:79`), and the rule binds the next lane that edits them. Nothing goes to `docs/plans/backlog-later.tsv`.

## Owner choices

None. The panel decided the open rows in round 2 (owner direction 2026-11-06). T4 and T5 need the owner at the Mac, which is an owner list row and not a choice.

## Open rows

None. Round 2 closed all eleven (`SCR/challenge/APPLIED.md`). The manager settled both splits on 2026-11-21 (`SCR/challenge/SPLITS.md`). D7's construct clause is unruled words, so UX's field places it, in the kit picker's help tag, and BIO allowed either home. T5 walks in background, as the 5.5 walk did, with the owner list as its fallback.
