# GUI walk of Preview 2026.10.13 (2026-10-10)

Status is active. Cited by docs/plans/2026-10-09-phase-2-4.md. Delete both together when the program plan closes.

## Why this walk ran

Preview 2026.10.13 shipped from main `7faa999d7` overnight without its interactive GUI walk, because the Mac's screen locked and macOS refuses input to a locked screen. The release notes made the walk the first check of the next session and a block on any Stable promotion. The Phase 2.3 genotype changes, first shipped in the same Preview, never had a walk of their own either. The owner asked for the walk on 2026-10-10 while away, with a five-person expert panel (Swift and macOS, software architecture, bioinformatics, QA and QC, UI and UX) deciding by consensus.

## Setup

| Item | Value |
|---|---|
| App | Debug build of `7faa999d7` from `python3 scripts/release/release.py debug` in the worktree `.claude/worktrees/gui-walk-2026-10-10`, version 2026.10.13, bundle id `com.lungfish.browser.debug` |
| Storage roots | `~/.lungfish-stable` for the provenance and genotype checks (0 required installs), `~/.lungfish` for the 12S run, because only that root holds the Ribosomal RNA Removal Data that Required Setup needs |
| Baseline for the Excel A/B | The 2026.10.11 Debug app in `~/LGE-GUI-Walk/baseline` |
| Projects | Copies under `~/LGE-GUI-Walk/2026-10-10` of all ten demo projects as the owner installed them that morning, plus the Phase 2.3 genotype walk project. The MHC copy also holds the alpha.11 bare-run record beside `Bare Run Check/MN908947.3.gff3` |
| Driving | Computer use in background mode, from 07:42 to 08:41, when the screen locked. Before-snapshots of every file in every project were taken first |

## What ran

| Check | Result |
|---|---|
| Provenance tab on the annotated reference (a 2026.9.58 record with an embedded `legacyWorkflowRun`) | Pass. Complete, three lineage steps with command, exit status, wall time and an empty stderr, files and outputs, fourteen option rows |
| Raw JSON on both legacy files | Pass. The Copy button gives the file's own bytes, 33,767 bytes for the annotated reference and 2,769 for the bare run, equal under `cmp` |
| Provenance tab on the alpha.11 bare-run record | Fail on the first selection in two launches, which shows "No provenance required" (F2). On the second selection the tab reads Incomplete with the "File metadata incomplete" warning, as the display baseline expects |
| The six File > Export > Provenance items | Pass. Each wrote only its folder, showed "Provenance Export Complete" and wrote its own record with `status` completed, no nested run and a `lungfish-cli provenance export` command |
| The six exports against `lungfish-cli provenance export` | Pass for shell, Python, Nextflow, Snakemake and methods, byte for byte apart from the export's own record. The JSON export differs (F5) |
| One analysis launched from the app | Pass. 12S Amplicon Matching on the simulated mixture. The Operations panel command, which is the string Copy CLI Command writes, equals the record's `argv` and `durableReplayArgv` token for token and its `reproducibleCommand` exactly. The record has `status` completed and no nested run |
| 12S science | Pass. 1,817 of 2,000 reads exact, human 1,235, rhesus 491, cynomolgus 91, against a 70, 25 and 5 percent mixture, as the bioinformatics expert predicted |
| Plugin Manager | Pass. Turning Show Experimental Features off and on hides and shows GATK Core, Variant Phasing and Wastewater Surveillance at once with the window open |
| Genotype byte check on select | walk-geno writes nothing. The first selection of each haplotyped bundle writes seed files (F9). Saved analyses keep their bytes, because the calling rules version 5 recompute stays in memory |
| Haplotype band and export with the band collapsed and expanded | Pass. "Haplotype Calls (3 loci)", effective calls such as `M4 • M4`, and the two workbooks compare equal |
| Excel A/B against the 2026.10.11 app | Pass in the default view and with the matrix filtered to Mafa-G. Both pairs compare equal, and the filtered pair differs from the unfiltered one |
| Live progress of `tree infer iqtree` | Pass at the pipe, run by the CLI with the app's arguments after the screen locked. The start and first three progress events arrived within 0.12 s and the other four at 47.5 s when IQ-TREE ended |
| Launch of all ten demos | Pass. Each opened and listed its items |
| Byte check of all eleven projects after the walk | No file deleted and no write outside the allowlist. Opening alone changed only app state and the known search index record that the plan sends to 2.6 |
| Runtime health | No trap, assertion or crash report, no main-thread hang sampled, RSS at most 344 MB, quit in 2 seconds with no child process left |
| Excel export with no tools (star 3), after the owner unlocked the screen at 09:07 | Pass. With an empty storage root the export shows `Excel export failed — Tool 'python' not found in environment 'openpyxl'` under the button and an alert sheet on the same window, and writes nothing |
| Two windows (star 4) | Pass. With walk-hap in one window and walk-geno in a second, Export to Excel… in the second attaches exactly one sheet, to that window |
| IQ-TREE launched from the app | The tree built in 0.7 seconds, too fast to watch progress arrive. The app passes one thread, while the CLI run without a thread count let IQ-TREE spend 42.7 seconds choosing one. Both chose TPM2u+F+I with the same tree score |
| F2 and F11 fixes in a rebuilt Debug app | Pass. The bare-run GFF3 shows its record on the first selection, and with README.md selected after it the JSON export says "No Provenance Available" instead of offering the GFF3's record. The project changed only app state |
| First selection of a bundle annotated through the CLI, after the screen was unlocked | Fail (F9). One selection of walk-legacy rewrote `annotations.json`, left three `lungfish genotype apply-annotations` records with a stale SHA-256 for it and replaced the fourth record |

## What did not run

| Check | Reason |
|---|---|
| Stars 2, 5, 6, 7 and 9 of the Phase 2.3 walk (manual haplotype editor, review menus, undo, context menus) | Menu items that depend on the first responder are disabled while the app is not frontmost, context menus and keystrokes are refused in background control, and full-screen control timed out three times, including twice while the owner was connected over Screen Sharing |
| Star 10 (smart cohorts) | Inconclusive. Pressing the Homozygous cohort through accessibility changed nothing visible, and both animals belong to it, so a working filter would also leave the view as it was |
| Live progress in the GUI | The IQ-TREE run took 0.7 seconds. The pipe timing of the same command stands in for it |
| The 12S reference made through Create 12S Reference | The open panel cannot be driven in background control, so the bundle was made with `lungfish-cli fastq 12s-reference-bundle` at the path the dialog uses |

## Findings and panel determinations

Each expert voted on severity (S1 wrong science or a read that changes data, S2 a release claim or binding rule fails or a wrong result reaches the user, S3 a visible defect or wrong wording with a workaround, S4 cosmetic), on whether the finding blocks a Stable promotion and on what to do. The determination is the majority. Every finding is older than 2026.10.13 unless the row says otherwise.

| Id | Finding | Severity | Blocks Stable | Determination |
|---|---|---|---|---|
| F2 | A loose file's record never reaches the Provenance tab on its first selection, which reads "No provenance required". The document publish step clears the target and nothing sets it again (`MainSplitViewController+MultiDocument.swift`). Present since 2026.9.9 | S2, five votes | Yes, three to two | Fix now, five votes. Fixed in d411b9d89 and 30474e9ad, which re-target the loose file after its document loads and leave a native project sequence cleared, and verified in the GUI |
| F11 | File > Export > Provenance exports the record of the last loaded document when a Quick Look item such as README.md is selected (`currentProvenanceExportResolution` in `AppDelegate+ImportExport.swift`) | S2, five votes | Yes, three to two | Fix now, five votes. Fixed in cb0219f18, where the sidebar selection wins unless the viewer shows it or a bundle that contains it, and verified in the GUI. Making the export follow the Inspector's resolved item is a 2.9 item |
| F9 | The first selection of a haplotyped genotype result seeds four smart cohorts and writes `annotations.json`, a record with home-folder paths and a lock file. On a bundle annotated through the CLI it leaves three existing records with a stale SHA-256 for `annotations.json` and replaces the fourth, which the walk confirmed on walk-legacy. A built-in cohort the analyst deletes comes back on the next open. Present since May 2026 | S1, four votes in a re-vote after the walk-legacy evidence | Yes | Fix now. The first vote, before that evidence, chose docs now and a fix in 2.6 by three to two. Fixed in b6235ae91, where both stores keep the built-in cohorts in memory and the first edit that saves the whole sidecar writes them with itself. QA and the Swift expert reviewed it, and in a rebuilt Debug app a first selection of a fresh and of a CLI-annotated bundle wrote no byte and left all four checksums matching |
| F10 | Switching between Haplotype Calls and Genotype Matrix saves the choice in `annotations.json` with an audit entry and a new record | S3 | No | 2.6, with F9 |
| F3 | Viewing a reference bundle writes the hidden `.viewstate.json` into it | S3 | No | Docs now. It is designed view state outside every checksum |
| F1 | The Raw JSON pane cuts off the ends of long lines | S3 | No | 2.6, Raw JSON display pass |
| F4 | Script exports re-run a command's sub-steps on its deleted scratch folder, so `run.sh` stops at step 2 | S3 | No | 2.6, provenance spec |
| F5 | The JSON export rewrites unresolved placeholders under the working directory and spells project paths with the home folder. 2026.10.11 does the same | S2, four votes | No | 2.6, schema version 2 |
| F6 | The 12S reference bundle command writes a record of a record | S3 | No | 2.6, sidecar name rule |
| F7 | A successful 12S run reads Completed with Warnings because its last line goes to standard error | S3 | No | 2.6, CLIEvent version 2 |
| F12 | The native alignment and tree records and the Excel export receipt carry no `status`, and the release note reads as if every record did | S3 | No | Next notes, then 2.7 |
| F14 | A sidebar copy or project copy import decodes options through `ParameterValue`, so a `<workspace>/dir/file` file option is written as `<external>/file`. The released demos hold 682 such values in 147 records. Checksums survive and the source is untouched | S2 or S3 | No | 2.7, with the copy helper after a facts freeze, keeping non-absolute file values verbatim |
| F8 | The 12S demo README names an old menu path | S4 | No | Manual and the next demo archive |
| F13 | A SwiftUI size fault on every provenance load, and an expected read past the end of a FASTA logged as an error | S4 | No | No action now, the 2.6 display pass may take the one-line spinner fix |

Observations O1 (a step command shows `<tool-root>` resolved to this Mac's storage root), O3 (the Workflow Library opens at its top) and O4 (the reference chooser opens in the last folder used anywhere) are S4 and need no action now.

**Does the walk clear the Stable block?** Five votes to none for option B. The walk clears the block for everything it ran, because the provenance scope that the Phase 2.4 panel set passed with byte evidence except F2, which is older than this release. F2, F11 and F9 block a Stable promotion of 2026.10.13 as it shipped, and the walk branch fixes all three, so Stable should come from a build that carries those fixes. The walk does not clear the checks that did not run. A session with the owner present runs them before any Stable promotion.

**Corrections made in place.** The release notes of 2026.10.13 said that selecting a result no longer changes the project. That sentence and the summary line now name the EsViritu and TaxTriage backfills they meant, and a dated correction lists the three writes the walk found. `docs/contracts/RECORDING-PROVENANCE.md` no longer calls the search index the one read-time write, scopes the stored status to envelope records and names the CLI single-step recorder that keeps a step's stderr whole. The Phase 2.4 plan records the walk and carries the scheduled findings in its deferred table.

## Owner-present walk of the remaining stars (2026-10-10 afternoon)

The owner sat at the Mac and approved full-screen control. The checks ran on Debug builds of main against `~/.lungfish-stable`, on fresh copies of the walk project under `~/LGE-GUI-Walk/2026-10-10-owner`, `-owner2` and `-owner3`. The first pass ran on `9fb0b82d4`, found two defects, and the 2026.10.11 baseline app separated new from old. The panel had both fixed test-first and reviewed, and the second pass ran on `ed28a621c`.

| Star | First pass on `9fb0b82d4` | Second pass on `ed28a621c` |
|---|---|---|
| 2 Unsaved draft and Export to Excel | Fail. The alert and Cancel behaved, but Save, and Save Assignments itself, did nothing visible on a bundle with no `annotations.json`. The save had failed since 900c0fabb in July, and its message sat below the visible part of the card | Pass on a copy with no sidecar. Save kept `WALK3`, the Export Genotype View sheet opened, and `annotations.json` and its record hold the assignment |
| 5 Genotype Call menu and shortcuts | Fail on both this build and the 2026.10.11 baseline. A click selected a cell without giving the matrix keyboard focus, so the menu items stayed dimmed and the shortcuts went to the sidebar. The context menu worked | Pass. Mark False Positive and Edit Comment are enabled, Mark False Negative stays dimmed, ⌥⌘P shows `[4]` and ⌥⌘R clears it |
| 6 Genotype Sample menu, undo and Sample Detail | Fail for the same reason | Pass. ⌘R, then Undo reads `Undo Mark Sample Reviewed`, Redo works and ⇧⌘O opens the Sample Detail sheet |
| 7 Context menus | Pass. Cell and column header menus list their items in order with their shortcuts, the dimmed Mark False Negative explains itself, and Add Comment opens Add Matrix Comment | Not rerun |
| 9 Manual band and Compare & Copy | Blocked by star 2 | Pass. The band shows `WALK3 · —`, the draft alert's Cancel and Discard behave as named, and Compare & Copy offers the saved sample |
| 10 Smart cohorts | Partial. A cohort filters the view (Incomplete haplotypes empties the matrix), and saving then removing a `Filter:` row works. No control shows which cohort is active, and clicking it again does not clear it | Not rerun |

The fixes are on main as `16d56e21d` (the matrix and Haplotype Calls take the keyboard focus on a click) and `58ef690e4` to `ed28a621c` (the first manual save publishes the viewed sidecar first, a failed save shows under Save Assignments and under Export to Excel, and it is logged). The panel reviewed both and asked for four changes to the second, which were made before it landed.

Smaller findings, scheduled with the 2.6 display pass.

| Finding | Severity |
|---|---|
| Star 10 shows no active cohort and has no way to clear it except choosing another cohort | S3 |
| The quit alert reads "The requested appQuit change will close the current sample editor" | S4 |
| Two different projects with the same name both get the window title "MHC Genotyping [1]" | S3 |
| Compare & Copy opens at the top of the detail pane, out of view of the button that opened it | S4 |
| A click on a row selector, a column header chiclet or a band target still leaves the focus in the sidebar | S3 |
| The first matrix review or comment on a bundle without a sidecar records no embedded prior, so its recorded replay command refuses | S3, 2.6 with the provenance spec |

## For the next Preview's release notes

| Area | What to say |
|---|---|
| Run status | Records written as envelopes store their status. The native alignment and tree records and the Excel export receipt do not yet |
| Raw JSON | The block also cuts off the end of a long line. Copy still copies the whole file |
| GUI walk | The walk of 2026.10.13 ran on 2026-10-10. Name the three fixes it led to and the checks that still need the owner present |
| Provenance tab and export | A loose file such as a GFF3 shows its record on the first selection. File > Export > Provenance exports the record of the selected item and says "No Provenance Available" for an item without one, where it used to export the record of the last document viewed |
| Genotype cohorts | Selecting a genotype result no longer writes into it. The built-in smart cohorts show from memory and are saved with the first real edit, so `genotype list-cohorts` and `genotype export-labkey` list them only after that edit. The Excel export record says whether its annotations came from the file or from memory |

## Evidence

Everything sits outside the repository. `~/LGE-GUI-Walk/2026-10-10/FINDINGS.md` holds the check log, `logs/` the before and after snapshots, the post-walk byte report `verify-walk.txt` and the app's unified log, `exports/` the clipboard captures and the CLI exports, and `cli/` the IQ-TREE event timings. The expert memos and votes sit in the session scratchpad.
