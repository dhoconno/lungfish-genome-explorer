# Implementation status: 2026-09-23 audit remediation

**2026-09-24 · branch `claude/lge-best-practices-audit-0a1b8f` (pushed, not merged to main, no release cut)**

This report covers the round of work the owner authorized after reviewing the audit. An Opus 5.5 orchestrator split the work into lanes. Sonnet agents implemented each lane in its own worktree. The orchestrator reviewed every diff, fixed problems before merging, merged, built, ran the affected tests, and recorded the result in the [ledger](ledger.md). The finding-by-finding status lives there. This page is the summary.

## Where things stand

| | Count |
|---|---:|
| Findings tracked (audit, genotyping review, and new live findings) | 185 |
| Fixed | 110+ |
| Partial | ~20 |
| Open | ~50, mostly P2/P3 and large structural items |
| P0 findings fixed | 10 of 11 |

One P0 is not fully closed. **GEN-02, homozygotes called heterozygous,** is mitigated. Affected calls are now marked `ambiguous` instead of wrongly `called`. The calling rule itself is the owner's decision.

The branch has about 240 commits over the pre-audit base `a1f439076`: roughly 26.7k lines added and 13.4k removed across Sources, Tests and scripts. The checkout itself shrank from 489 MB to 189 MB (docs work).

## What changed, by theme

- **Data safety:**
  - Variant deletion no longer drops alignment tracks (FEA-01).
  - Same-name FASTQ imports no longer replace existing bundles (FEA-02).
  - `tree infer` and MSA `--force` no longer destroy shared scratch or existing output (WFL-02, REC-02).
  - FASTQ outputs are never re-binned or silently Trim Galore-trimmed. Binning is off by default (WFL-01, SCI-08, D1).
  - Failed restores keep their backups (REC-01).
  - Viewer and Inspector annotation edits and deletes now persist (FEA-03).
- **Scientific correctness:**
  - iVar gets per-segment CDS with correct phases (SCI-01), and duplicate VCF records are removed (SCI-02).
  - AF and depth thresholds are actually applied (SCI-03). bcftools runs haploid with no depth cap (SCI-04).
  - Unique-read counts are uncapped (PERF-04). Mapping rate counts reads, not records (SCI-05).
  - Extraction is strand- and splice-aware, and reverse-complemented variants are transformed (SCI-06, SCI-07).
  - Translation honours `codon_start`, phase and translation tables (SCI-10). GFF3 phase and `Parent` links are correct (SCI-11). One locus grammar is used everywhere (SCI-13, FEA-09).
  - Interleaved subsampling is pair-aware (SCI-16).
  - Genotyping:
    - ONT barcodes are anchored to CS1/CS2 (GEN-01).
    - Indistinguishable haplotype pairs are marked ambiguous (GEN-02). Unresolved second haplotypes show `?` (GEN-08).
    - Fragment denominators are correct (GEN-07), and PacBio demux is deterministic (GEN-11).
- **Owner-requested viewport downsampling fix (DS-01):**
  - The read track samples evenly across the window instead of taking the first 50,000 reads by coordinate.
  - Confirmed live: "Showing 49,765 of 200,000 reads, sampled evenly across the view".
  - A 3M-read BAM fetch dropped from 19.8 s to 4.2 s.
- **Performance:**
  - No main-thread BAM hashing, TaxTriage samtools calls, or synchronous sidebar rescans (PERF-01/03/05).
  - `NativeToolRunner` no longer blocks its actor (PERF-02).
  - Annotation export no longer loads the genome (PERF-06).
  - The loading badge repaints only its own rect, panning is throttled, and draws skip tracks outside `dirtyRect` (PERF-09).
  - Variant-database scans run off the main thread (PERF-07).
  - Genotype matrix: fonts and colours are cached, cutting a full redraw from 346 ms to about 93–106 ms and first-paint cell build from about 707 ms to about 385 ms (PERF-17, still above the 100 ms target).
- **Operation lifecycle:**
  - `OperationCenter.begin` makes a lock refusal impossible to ignore (ARC-04, FEA-07), with a pre-push ratchet.
  - The `CLIImportRunner` and variant-calling cancel deadlocks are fixed.
  - Process-tree termination uses libproc (PERF-11).
  - Quit and window close warn when operations are running (FEA-06).
  - A stuck "Update Annotation" operation can no longer hold a bundle lock (NEW-07).
- **Dead ends and consistency:**
  - Results that couldn't be opened now open: routing reads `analysis-metadata.json` (WFL-05, WFL-06).
  - Wizard options reach the tools (WFL-10).
  - Primer-trim contigs are resolved against the BAM header (WFL-08).
  - Export failures are shown to the user (UX-02).
  - GATK phasing (D4) and AI haplotyping (D5) are hidden.
  - Copy and Find work in data tables. The shared column-filter menu is used by five viewers.
  - TaxTriage shortcuts are real menu items, and read sort and colour modes are reachable (FEA-08).
- **Structure:**
  - One typed `CLIEvent` schema and one `CLISubprocessTransport` now serve 6 of the 9 CLI runners.
  - `CLIInvocation` makes Kraken2 and FASTQ "Copy CLI Command" strings runnable, with parser round-trip tests.
  - About 5K lines of verified dead code are removed. Shared `FileDigest` and `DelimitedText` helpers are added.
- **Release and tests:**
  - App bundles are no longer owner-only (REL-01).
  - Third-party notices are generated and bundled, including the kernel GPL notice (REL-03, needs legal review).
  - DMG uploads get a size-scaled timeout, with draft-then-publish (REL-05). A `yank` plan command exists (REL-04, plan only).
  - `ci.yml` is manual-dispatch only.
  - The release gate requires green unit-tier evidence for the release commit plus an app-launch smoke.
  - Gate timeouts and orphan-process fixes are in.
  - Process-wide `setenv` and `UserDefaults.standard` are removed from the tests that leaked state.
- **Docs:**
  - Finished notes are deleted.
  - Manual media is in the private `dhoconno/lungfish-manual-media` repo, pinned by `media.lock`.
  - Test fixtures moved to `Tests/Fixtures`.
  - Pre-commit guards cover large files, `features.yaml` entry points and the embedded Python.

## Verification

- **Per lane:** targeted suites for every change, run again on the integrated branch after merging.
- **Integrated unit tier:** **GATE PASS on `26744cec9`**: 13,907 XCTest executed, 0 failures, with the five D8 tests quarantined. Two runs before it failed on load flakes, and all three flaky tests were fixed:
  - a `readPID` that recorded an XCTest failure inside a `try?` poll;
  - a yield-count loop in the detached alignment viewer test;
  - human-scrubber tests sharing preferences across parallel workers. `DatabaseRegistry` now takes an injected preferences store.
- **Computer Use on the installed debug build** (see [gui-verification.md](gui-verification.md)):
  - **Passed:** 11 items. DS-01, FEA-01, FEA-02, FEA-06, FEA-08, FEA-09, NEW-01, NEW-03, WFL-10, cancel-all, and the project lock warning.
  - **Found and then fixed in this session:**
    - NEW-07: selecting an annotation started stuck operations.
    - NEW-09: "Cancel Operations and Quit" never quit. Confirmed live: the app now exits in about 2 seconds.
    - FEA-03 follow-up: an Inspector delete of an annotation picked in the drawer did nothing. Confirmed live: the row count went from 23 to 22.
    - NEW-08: a cancelled operation whose worker never returns now becomes Cancelled after 10 seconds. Its bundle stays locked until the worker actually exits, so nothing can write over it. Version probes no longer swallow cancellation.
  - **Found and still open:** NEW-02, NEW-06, NEW-10 (caused by NEW-11), NEW-11 and DS-02.

## Needs the owner

| Item | Why it needs you |
|---|---|
| **D8**: Genotype Excel comment contract | Two existing tests require opposite comment formats for the Filtered sheet. Five tests are quarantined in the gate until you choose (TST-15) |
| **GEN-02**: haplotype calling rule | The shipped definitions use `minimumMatches: 1`, so shared alleles can support a second haplotype. Calls are now flagged `ambiguous`; you decide the rule |
| GEN-04, 05, 06, 10 | Tie handling, locus-% denominator unification, "min %" semantics for novel rows, and an indel guard all change how numbers are interpreted |
| **REL-03**: legal review | The kernel source offer names your email address. The zstd BSD election and the `main`-branch license URLs also need a check |
| REL-04 | `release.py yank` prints a plan only. Executing it against the live Sparkle feed needs your go-ahead |
| NEW-02: sidebar watcher | Reproduced live 3 times (backgrounded signed app, 4–5 windows). Not reproduced headless. Leading hypothesis: App Nap throttling while backgrounded |
| NEW-06: EsViritu interleaved input | Runs as unpaired and is labelled "Single-end reads". Deinterleave and run paired? |
| **NEW-11**: folder permissions | Hardened file writes open every folder from `/` down. For a project in Desktop, Documents or Downloads they need that folder's macOS permission, not just the project. Without it, provenance writes, temp folders and the file watcher hang with no message. A live process sample showed it behind the stuck EsViritu run (NEW-08) and the stuck annotation-delete operation (NEW-10). Should the no-follow walk start at the project root instead? |

## Known gaps and next steps

- **Structure:**
  - 3 import runners still need to move onto `CLISubprocessTransport` (ARC-02).
  - The full one-builder FASTQ encoding is unfinished (SIMP-01).
  - GUI analyses still run in-process instead of through shared run services (ARC-01).
  - Window context is not yet per-window (ARC-05/06).
  - Import routing is not yet unified (FEA-04).
- PERF-12: two cancellation-sensitive blocking waits remain.
- PERF-17: custom-drawn genotype matrix cells would get under 100 ms.
- DS-02: fetch the visible range in full and sample only the padding.
- UX: column-state persistence (UX-06), the rest of the label unification (UX-07), and VoiceOver in the core viewer (UX-11).
- Recapture the `esviritu-advanced-settings` manual screenshot into the media repo. A capture from the new build is in the session scratchpad.

## Testing the debug build

`/Applications/Lungfish Debug.app` is built from `26744cec9`, the gated head. The previous debug app is in the Trash. Launch it by path. Another debug build in your primary checkout (`~/Documents/lungfish-genome-explorer/build/Debug/`) shares its bundle ID, and LaunchServices may pick that one otherwise. The Computer Use scratch data is at `~/Desktop/LGE-audit-verify.lungfish`, `~/Documents/audit-LGE-audit-scratch.lungfish` and `~/Documents/LGE-audit-inputs`. Delete them when you are done.

Each rebuild of the ad-hoc-signed debug app invalidates its macOS Desktop permission. The first time it touches the Desktop scratch project, macOS may ask for Desktop access again. Until you answer, some operations sit at 0% (NEW-11).
