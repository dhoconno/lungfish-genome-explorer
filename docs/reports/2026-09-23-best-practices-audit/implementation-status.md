# Implementation status: 2026-09-23 audit remediation

**2026-09-24 · merged to `main` and shipped as Preview v2026.9.40**

This report covers the round of work the owner authorized after reviewing the audit. An Opus 5.5 orchestrator split the work into lanes. Sonnet agents implemented each lane in its own worktree. The orchestrator reviewed every diff, fixed problems before merging, merged, built, ran the affected tests, and recorded the result in the [ledger](ledger.md). The finding-by-finding status lives there. This page is the summary.

## Where things stand

| | Count |
|---|---:|
| Findings tracked (audit, genotyping review, and new live findings) | 185 |
| Fixed | 110+ |
| Partial | ~20 |
| Open | ~50, mostly P2/P3 and large structural items |
| P0 findings fixed | 11 of 11 |

All P0 findings are closed. GEN-02 (homozygotes called heterozygous) was fixed in the second round under the owner's decision D11. Affected calls are now marked `ambiguous` instead of wrongly `called`. The calling rule itself is the owner's decision.

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
  - **Found and later fixed:** NEW-02, NEW-06, NEW-10 and NEW-11, plus DS-02, which the depth cap replaced. NEW-10 and NEW-11 were confirmed live on the Desktop scratch project.

## Second round (owner decisions D8 to D21, 2026-09-24)

The owner answered the open questions, and a second round of lanes implemented every answer:

| Decision | Result |
|---|---|
| D8 Excel comments | Comments hold the exact user note. Evidence moved to its own column. The five quarantined tests pass, so the quarantine list is empty |
| D9 depth cap | The read view caps displayed depth (default 500x) instead of loading 50,000 reads. Shallow regions show every read. Verified live: 65,424 of ~671,705 reads shown at a 5,000x block, and typing 100 in the Inspector refetches |
| D10 sliders | All sliders use `NumericSliderField` with typed entry, enforced by a pre-push ratchet |
| D11, D12, D15 calling | Homozygotes call correctly (DQ and DR 28 of 28 in the golden test). Identical definitions are reported as ambiguities. Identical references collapse with an `ambiguous_with` list. Long-read calls keep indels with an `indel_bases` column and review flag |
| D13, D14 denominators and filters | One per-source-locus denominator everywhere. "Min %" is a per-sample read fraction for all alleles, plus a separate "Seen in ≥ N% of animals" control |
| D16, D17 release | Licence links pinned, zstd BSD election stated, `release.py yank` executes with typed confirmation and a build-floor marker |
| D18, D20 | The no-follow walk starts at the project or bundle, and the sidebar rescans when the app activates |
| D19 EsViritu | Strictly interleaved files run paired. Files that mix pairs and merged reads run single-end with a clear label |
| D6a, D21 (team) | The real-app smoke gate stays off until the owner creates the QA account. An idle session's finished fix was carried into the release |

The release-script test suite went from 67 failures to green (927 passed, 2 documented expected failures, REL-06 and REL-07). The integrated unit tier passed on `955075173` with 14,018 XCTest and 0 failures.

## Needs the owner

| Item | Why it needs you |
|---|---|
| **REL-03**: legal read | The kernel source offer and the zstd election sentence are compliance text and would benefit from a lawyer's read |
| **D6a**: QA account | Create the `lungfish-release-qa` macOS account to re-enable the real-app smoke gate. Fix REL-06 in the same change |
| REL-04 drill | Try `release.py yank --execute` once on a disposable fork before relying on it |
| Screenshot | `view-settings-reads-tab` and `esviritu-advanced-settings` need recapturing into the media repo |

## Known gaps and next steps

- **Structure:**
  - 3 import runners still need to move onto `CLISubprocessTransport` (ARC-02).
  - The full one-builder FASTQ encoding is unfinished (SIMP-01).
  - GUI analyses still run in-process instead of through shared run services (ARC-01).
  - Window context is not yet per-window (ARC-05/06).
  - Import routing is not yet unified (FEA-04).
- PERF-12: two cancellation-sensitive blocking waits remain.
- PERF-17: custom-drawn genotype matrix cells would get under 100 ms.
- UX: column-state persistence (UX-06), the rest of the label unification (UX-07), and VoiceOver in the core viewer (UX-11).

## Testing

- **Preview v2026.9.40** is the build to test. An installed Lungfish Preview offers it through the normal update check, or download it from the GitHub release.
- `/Applications/Lungfish Debug.app` is also built from the release commit. Launch it by path, because an older debug build in the primary checkout shares its bundle ID.
- A rebuilt debug app loses its macOS Desktop permission, so macOS may ask again. Since NEW-11, saving steps no longer hang while that request is pending.
- Scratch data from the Computer Use checks is at `~/Desktop/LGE-audit-verify.lungfish`, `~/Documents/audit-LGE-audit-scratch.lungfish` and `~/Documents/LGE-audit-inputs`. The Desktop project includes `DeepMixed`, a 60 kb reference with a 5,000x block for trying the depth cap. Delete them when you are done.
