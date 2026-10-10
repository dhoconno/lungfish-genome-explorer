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

## What did not run

| Check | Reason |
|---|---|
| Stars 2, 5, 6, 7 and 9 of the Phase 2.3 walk (manual haplotype editor, review menus, undo, context menus) | Menu items that depend on the first responder are disabled while the app is not frontmost, context menus and keystrokes are refused in background control, and full-screen control timed out with nobody at the Mac |
| Stars 3, 4 and 10, and the GUI IQ-TREE run | The screen locked at about 08:41 |
| The 12S reference made through Create 12S Reference | The open panel cannot be driven in background control, so the bundle was made with `lungfish-cli fastq 12s-reference-bundle` at the path the dialog uses |

## Findings and panel determinations

Each expert voted on severity (S1 wrong science or a read that changes data, S2 a release claim or binding rule fails or a wrong result reaches the user, S3 a visible defect or wrong wording with a workaround, S4 cosmetic), on whether the finding blocks a Stable promotion and on what to do. The determination is the majority. Every finding is older than 2026.10.13 unless the row says otherwise.

| Id | Finding | Severity | Blocks Stable | Determination |
|---|---|---|---|---|
| F2 | A loose file's record never reaches the Provenance tab on its first selection, which reads "No provenance required". The document publish step clears the target and nothing sets it again (`MainSplitViewController+MultiDocument.swift`). Present since 2026.9.9 | S2, five votes | Yes, three to two | Fix now, five votes |
| F11 | File > Export > Provenance exports the record of the last loaded document when a Quick Look item such as README.md is selected (`currentProvenanceExportResolution` in `AppDelegate+ImportExport.swift`) | S2, five votes | Yes, three to two | Fix now, five votes |
| F9 | The first selection of a haplotyped genotype result seeds four smart cohorts and writes `annotations.json`, a record with home-folder paths and a lock file. A built-in cohort the analyst deletes comes back on the next open. Present since May 2026 | S2, three votes, one S1 and one S3 | Until the docs are corrected, five votes | Correct the docs now, then fix in 2.6 by keeping the seed in memory until the first real edit, three to two |
| F10 | Switching between Haplotype Calls and Genotype Matrix saves the choice in `annotations.json` with an audit entry and a new record | S3 | No | 2.6, with F9 |
| F3 | Viewing a reference bundle writes the hidden `.viewstate.json` into it | S3 | No | Docs now. It is designed view state outside every checksum |
| F1 | The Raw JSON pane cuts off the ends of long lines | S3 | No | 2.6, Raw JSON display pass |
| F4 | Script exports re-run a command's sub-steps on its deleted scratch folder, so `run.sh` stops at step 2 | S3 | No | 2.6, provenance spec |
| F5 | The JSON export rewrites unresolved placeholders under the working directory and spells project paths with the home folder. 2026.10.11 does the same | S2, four votes | No | 2.6, schema version 2 |
| F6 | The 12S reference bundle command writes a record of a record | S3 | No | 2.6, sidecar name rule |
| F7 | A successful 12S run reads Completed with Warnings because its last line goes to standard error | S3 | No | 2.6, CLIEvent version 2 |
| F12 | The native alignment and tree records and the Excel export receipt carry no `status`, and the release note reads as if every record did | S3 | No | Next notes, then 2.7 |
| F8 | The 12S demo README names an old menu path | S4 | No | Manual and the next demo archive |
| F13 | A SwiftUI size fault on every provenance load, and an expected read past the end of a FASTA logged as an error | S4 | No | No action now, the 2.6 display pass may take the one-line spinner fix |

Observations O1 (a step command shows `<tool-root>` resolved to this Mac's storage root), O3 (the Workflow Library opens at its top) and O4 (the reference chooser opens in the last folder used anywhere) are S4 and need no action now.

**Does the walk clear the Stable block?** Five votes to none for option B. The walk clears the block for everything it ran, because the provenance scope that the Phase 2.4 panel set passed with byte evidence except F2, which is older than this release. It does not clear the checks that did not run. A session with the owner present runs them before any Stable promotion, together with the first selection of a loose file and a stale-record export after the F2 and F11 fixes.

**Corrections made in place.** The release notes of 2026.10.13 said that selecting a result no longer changes the project. That sentence and the summary line now name the EsViritu and TaxTriage backfills they meant, and a dated correction lists the three writes the walk found. `docs/contracts/RECORDING-PROVENANCE.md` no longer calls the search index the one read-time write, scopes the stored status to envelope records and names the CLI single-step recorder that keeps a step's stderr whole. The Phase 2.4 plan records the walk and carries the scheduled findings in its deferred table.

## For the next Preview's release notes

| Area | What to say |
|---|---|
| Run status | Records written as envelopes store their status. The native alignment and tree records and the Excel export receipt do not yet |
| Raw JSON | The block also cuts off the end of a long line. Copy still copies the whole file |
| GUI walk | The walk of 2026.10.13 ran on 2026-10-10. Name the two fixes it led to and the checks that still need the owner present |

## Evidence

Everything sits outside the repository. `~/LGE-GUI-Walk/2026-10-10/FINDINGS.md` holds the check log, `logs/` the before and after snapshots, the post-walk byte report `verify-walk.txt` and the app's unified log, `exports/` the clipboard captures and the CLI exports, and `cli/` the IQ-TREE event timings. The expert memos and votes sit in the session scratchpad.
