# Findings ledger

Single source of truth for finding status (plan rule 9). Status: `open`, `verified` (still holds at current HEAD), `not-reproduced`, `fixed` (commit + evidence), `accepted` (reason), `deferred` (reason).

| ID | P | Title | Status | Package | Commit | Evidence |
|---|---|---|---|---|---|---|
| FEA-01 | P0 | Manifest rewrites drop alignment tracks and the record store (variant deletion paths) | open | | | |
| FEA-02 | P0 | GUI FASTQ import silently replaces same-named bundles, and ignores Keep Both and sample-sheet names | open | | | |
| PERF-04 | P0 | Unique-read counts for TaxTriage and EsViritu are capped at 100,000 parsed reads per contig after buffering up | open | | | |
| REL-01 | P0 | Shipped app bundles are owner-only (0700/0600) because of `umask 077` | open | | | |
| SCI-01 | P0 | GFF exported to iVar collapses multi-segment CDS (ORF1ab frameshift, spliced CDS) into one span, which changes | open | | | |
| TST-01 | P0 | Pre-push unit tier is red on HEAD: 117 failures plus 1 indefinite hang | open | | | |
| TST-02 | P0 | No gate runs the broad suite: release selects 186 of about 14.2K tests, the hook is not installed, and 11 rele | open | | | |
| WFL-01 | P0 | FASTQ-operation outputs are silently quality-binned and, when large, Trim Galore-trimmed during re-ingestion | open | | | |
| WFL-02 | P0 | `tree infer iqtree` deletes the shared project `.tmp`, deletes pre-existing output on refusal, and can deadloc | open | | | |
| ARC-01 | P1 | Two execution models for GUI analyses, chosen per feature, with no shared service layer | open | | | |
| ARC-02 | P1 | Nine copy-pasted CLI runner actors and about 12 ad-hoc, stringly-typed CLI event schemas | open | | | |
| ARC-03 | P1 | Operations-panel "CLI command" strings are hand-built and drift from the real CLI (Kraken2 replay cannot run) | open | | | |
| ARC-04 | P1 | `OperationCenter.start` can return an already-failed operation, and callers are not forced to notice | open | | | |
| ARC-13 | P1 | TaxTriage view controller runs samtools synchronously on the main actor, with a pipe-ordering hazard | open | | | |
| FEA-03 | P1 | Annotation edit and delete from the viewer and Inspector are not persisted for reference bundles | open | | | |
| FEA-04 | P1 | The same BAM or VCF file does different things depending on the entry point, and BAM/VCF have no target choose | open | | | |
| FEA-05 | P1 | Multi-file BAM or VCF import into an open bundle imports only the first file | open | | | |
| FEA-06 | P1 | Quit and window close do not warn about running operations, and interrupted outputs become invisible | open | | | |
| FEA-07 | P1 | `OperationCenter.start` does not enforce the bundle lock, so unchecked callers mutate locked bundles | open | | | |
| FEA-08 | P1 | Read sort and colour modes are implemented and tested but unreachable in the alignment viewer | open | | | |
| PERF-01 | P1 | Alignment scientific actions SHA-256 the whole BAM, index and reference on the main actor, twice per action | open | | | |
| PERF-02 | P1 | `NativeToolRunner.shared` actor is blocked for the full runtime of `runWithFileOutput` / `runPipeline` childre | open | | | |
| PERF-03 | P1 | TaxTriage batch unique-read pass runs directory walks, file parsing and `samtools` on the main actor, then an  | open | | | |
| PERF-05 | P1 | Eight post-import and post-operation call sites run the full recursive project scan synchronously on the main  | open | | | |
| PERF-06 | P1 | "Export annotations" and multi-source sequence export decompress and parse the entire genome into memory | open | | | |
| REC-01 | P1 | Sibling mutation service deletes backup | open | | | |
| REC-02 | P1 | MSA/tree --force deletes output before work | open | | | |
| REC-03 | P1 | Kraken2 taxonomy/BLAST exports lack provenance | open | | | |
| REC-04 | P1 | Sidebar VCF/folder drop silently discarded | open | | | |
| REC-05 | P1 | About Saving text promises persistence FEA-03 disproves | open | | | |
| REL-02 | P1 | CI workflow invalid since 2026-09-14, 24 straight failures, 12 previews shipped on red | open | | | |
| REL-03 | P1 | GPL-2.0 Linux kernel shipped without notice or source offer; THIRD-PARTY-NOTICES stale and not bundled | open | | | |
| REL-04 | P1 | No rollback or yank path for a bad Sparkle release; the floor gate blocks the obvious one | open | | | |
| REL-05 | P1 | Every `gh` call, including the ~167 MB DMG upload, is capped at 180 s | open | | | |
| SCI-02 | P1 | iVar TSV to VCF converter emits duplicate records for overlapping CDS (ORF1a/ORF1ab) | open | | | |
| SCI-03 | P1 | Minimum AF and depth thresholds silently ignored for LoFreq, bcftools, Medaka and Clair3, yet recorded in prov | open | | | |
| SCI-04 | P1 | bcftools caller runs with diploid ploidy and max-depth 250 on viral data | open | | | |
| SCI-05 | P1 | Mapping "reads mapped / total" and per-contig % count alignment records (secondary and supplementary), not rea | open | | | |
| SCI-06 | P1 | Annotation extraction ignores strand and splicing, and the core API applies 5'/3' flanks by coordinate | open | | | |
| SCI-07 | P1 | Region to bundle extraction with Reverse Complement does not transform variants | open | | | |
| SCI-08 | P1 | Lossy quality binning on by default (silent on downloads and FASTQ operation outputs), mislabelled schemes, or | open | | | |
| SCI-09 | P1 | NAO-MGS "coverage %" uses the furthest alignment end as reference length when references were not fetched | open | | | |
| TST-03 | P1 | Swift Build migration broke subpath `Bundle.module` fixtures, crashing tests with SIGTRAP | open | | | |
| TST-04 | P1 | Stable-namespace change broke about 75 tests that hard-code `.lungfish` fake homes, and tests cannot inject an | open | | | |
| TST-05 | P1 | No per-test or overall timeout: a cancellation test hung for 14+ min and stalls the gate forever | open | | | |
| TST-06 | P1 | `ci.yml` has been an invalid workflow on every push since 2026-09-14 instead of being disabled cleanly | open | | | |
| UX-01 | P1 | "Delete Annotation" from the viewer and the Inspector silently does nothing on reference bundles | open | | | |
| UX-02 | P1 | Export failures are logged but never shown in EsViritu, TaxTriage (3 paths), NAO-MGS and NVD | open | | | |
| WFL-03 | P1 | "GATK + WhatsHap Phased" is selectable and runnable-looking but always dead-ends | open | | | |
| WFL-04 | P1 | Viral Recon loses outputs on caller overrides and (likely) Nanopore; analysis folder has no provenance; cancel | open | | | |
| WFL-05 | P1 | pbAA results are written into a sidebar-hidden folder; Savont batch samples route to "Unsupported analysis" | open | | | |
| WFL-06 | P1 | Renamed classifier batch folders cannot be reopened (routing uses name prefix, not metadata) | open | | | |
| WFL-07 | P1 | "Remove Human Reads" database chooser discards the chosen file and rejects the real index | open | | | |
| WFL-08 | P1 | BAM primer trim never matches the scheme's contig to the BAM's `@SQ` name | open | | | |
| WFL-09 | P1 | No shared dependency preflight: most workflows find a missing tool only by failing | open | | | |
| WFL-10 | P1 | Wizard options silently ignored downstream (EsViritu min length, TaxTriage classifiers, demux, seeds, etc.) | open | | | |
| ARC-05 | P2 | Per-window state leaks through globals (`mainWindowController`, `DocumentManager.shared` mirror, `NSApp.keyWin | open | | | |
| ARC-06 | P2 | Window scoping of notifications is a fail-open convention reimplemented in three controllers | open | | | |
| ARC-07 | P2 | GUI and CLI write different provenance for the same Kraken2 analysis | open | | | |
| ARC-08 | P2 | Dead parallel FASTQ materializer (~1,100 lines) kept alive only by tests | open | | | |
| ARC-09 | P2 | FASTQ derivative operations have two GUI code paths and two CLI-command builders | open | | | |
| ARC-10 | P2 | `AppDelegate` extensions are the business-logic layer for import, export, downloads and classification | open | | | |
| ARC-11 | P2 | About 1,290 test hooks in production types, a symptom of logic trapped in view controllers | open | | | |
| ARC-12 | P2 | `GenotypeResultViewController` is a 9.8K-line god object (323 stored vars, 508 funcs) | open | | | |
| ARC-15 | P2 | Five external-process mechanisms, plus about 120 raw `Process()` sites across all layers | open | | | |
| FEA-09 | P2 | Two locus parsers with different grammar, and no gene lookup in the locus field | open | | | |
| FEA-10 | P2 | Settings controls that nothing reads (default zoom window, max undo levels) | open | | | |
| FEA-11 | P2 | Export Image/PDF can export a hidden view or the wrong window; some menu actions ignore the key window | open | | | |
| FEA-12 | P2 | GUI BAM and VCF imports record a `lungfish-cli` command that the CLI cannot run | open | | | |
| FEA-13 | P2 | Variant table dead controls: Het Only chip, single-option Match picker, silent preset rewrite | open | | | |
| FEA-14 | P2 | Output placement differs by entry point (Imports, project root, drop folder, alignment-read-extractions with U | open | | | |
| PERF-07 | P2 | Result and bundle selection opens SQLite databases and runs scans and JSON decodes on the main thread | open | | | |
| PERF-08 | P2 | Oriented virtual-FASTQ materialization loads the orient map twice as whole `String`s into two `Set<String>` of | open | | | |
| PERF-09 | P2 | Loading-badge animation invalidates the whole sequence viewer at 18 fps, and horizontal pan redraw is a traili | open | | | |
| PERF-10 | P2 | MSA drawing allocates an attributed string per residue and re-registers tooltips inside `draw(_:)`, and the gu | open | | | |
| PERF-11 | P2 | Process-tree termination spawns `ps` per PID per loop, and quit terminates roots serially on the main thread | open | | | |
| PERF-12 | P2 | Blocking waits pin cooperative-pool threads for tool lifetimes | open | | | |
| PERF-13 | P2 | Import helper cancellation signals only the helper root and polls with `Thread.sleep` | open | | | |
| REL-06 | P2 | App version inside the hashed dependency manifest resets "Later" and stales receipts every release | open | | | |
| REL-07 | P2 | Five hand-maintained version sites where one would do | open | | | |
| REL-08 | P2 | Legacy alpha bridge and pre-2026.9.2 previews are offered updates with a different bundle ID | open | | | |
| REL-09 | P2 | Release machinery is heavy while the regression gate is thin and no gate launches the app | open | | | |
| REL-10 | P2 | Release builds from the live working checkout, so stray untracked files block releases | open | | | |
| REL-11 | P2 | Conda transitive dependencies are unpinned, so a "dependency set" is not reproducible | open | | | |
| REL-12 | P2 | Database archives and one pipeline are not integrity-pinned; one catalog ID/URL mismatch | open | | | |
| REL-13 | P2 | Pages deploy job (pages:write, id-token:write) uses tag-pinned third-party actions | open | | | |
| REL-14 | P2 | Code claims a Stable release triggers CI conformance; no workflow listens for it | open | | | |
| SCI-10 | P2 | CDS translation ignores `/codon_start`, GFF phase and `/transl_table`, and reverse-strand phase comes from the | open | | | |
| SCI-11 | P2 | GFF3 export writes phase 0 on every CDS segment, splits one CDS into distinct IDs, and leaves a dangling `Pare | open | | | |
| SCI-12 | P2 | Bgzip FASTA reader returns `\r` and drops bases for CRLF FASTA | open | | | |
| SCI-13 | P2 | User-visible `chr:start-end` strings mix 0-based and 1-based conventions | open | | | |
| SCI-14 | P2 | Variant track chromosome aliasing silently matches by length or max-position (up to 20% tolerance) | open | | | |
| SCI-15 | P2 | Origin-spanning features on circular genomes are sorted by start, which reorders segments | open | | | |
| SCI-16 | P2 | Interleaved paired FASTQ subsample via the CLI-backed Operations path is not pair-aware | open | | | |
| SCI-17 | P2 | Markdup shell pipeline: no `pipefail`, double-quote interpolation of paths, duplicate fraction over alignment  | open | | | |
| SCI-18 | P2 | Bracken always uses the 150 bp distribution regardless of actual read length | open | | | |
| SIMP-01 | P2 | FASTQ operations have three independent CLI encodings; provenance records a command that did not run | open | | | |
| SIMP-02 | P2 | About 5.9K lines of workbook-transaction recovery outlive their only writer | open | | | |
| SIMP-03 | P2 | PrimalScheme3 adapter supports 4 fork versions and 2 external-binary-only selectors (about 3.3K lines) | open | | | |
| SIMP-04 | P2 | Nine copy-pasted CLI subprocess runners (about 3.4K lines) next to an unused kernel runner | open | | | |
| SIMP-05 | P2 | Verified dead code: about 5.0K production lines plus about 2.5K test lines (ranked list) | open | | | |
| SIMP-06 | P2 | Same-named public types in two modules (`SequencingPlatform`, `AlignmentFilter*`) | open | | | |
| SIMP-07 | P2 | Chromosome aliasing implemented at least 5 times; the dedicated resolver is unused | open | | | |
| SIMP-08 | P2 | Docs and review artifacts dominate the checkout and the churn | open | | | |
| TST-07 | P2 | About 300 source-text-inspection tests, 591 assertions over production source strings | open | | | |
| TST-08 | P2 | Low-value tests: tautologies, ArgumentParser echoes, constant re-assertions, vacuous conditionals (about 20% o | open | | | |
| TST-09 | P2 | White-box over-testing: 1,440 test hooks shipped in production code, Genotype area 109K test lines | open | | | |
| TST-10 | P2 | Flakiness sources: wall-clock budgets as tight as 0.1 s, global singletons and defaults, process-wide `setenv` | open | | | |
| TST-11 | P2 | Silent skips: tool-gated app tests ignore `LUNGFISH_REQUIRE_TOOLS`, in-repo fixture misses skip, the conforman | open | | | |
| TST-12 | P2 | XCUITests (40) run nowhere automatically, `appSmokeRequired: false`, core scientific journeys uncovered | open | | | |
| UX-03 | P2 | Keyboard shortcuts implemented in `NSViewController.performKeyEquivalent` are probably never reached, and ⌘0 c | open | | | |
| UX-04 | P2 | Edit > Copy and Edit > Find are dead in data views | open | | | |
| UX-05 | P2 | Table search and column-filter UI copied four times and drifting. NAO-MGS has no search. TaxTriage hides searc | open | | | |
| UX-06 | P2 | No table column state is persisted. Four ad-hoc `UserDefaults` schemes exist elsewhere | open | | | |
| UX-07 | P2 | Same action, different names: BLAST, NCBI lookup, Copy TaxID, Extract labels drift across viewers | open | | | |
| UX-08 | P2 | CZ-ID disables Extract on the action bar but the table menu still offers Kraken2 Extract and BLAST | open | | | |
| UX-09 | P2 | Result load failures are shown three different ways, one of them silent | open | | | |
| UX-10 | P2 | Content Text Size is ignored by the Kraken2 table and most sequence-viewer chrome | open | | | |
| UX-11 | P2 | Core sequence viewer and track headers are opaque to VoiceOver and keyboard | open | | | |
| UX-12 | P2 | Inspector key/value rows reimplemented about 10 times with different layout and accessibility | open | | | |
| UX-13 | P2 | The "viewport interface class" contract and dialog conventions are ceremonial or stale | open | | | |
| UX-14 | P2 | No "no matches" or first-run empty states in result tables and empty projects | open | | | |
| WFL-11 | P2 | Operations-panel CLI commands and several provenance argv records are not runnable | open | | | |
| WFL-12 | P2 | Cancel missing or inert on several long-running paths | open | | | |
| WFL-13 | P2 | MHC genotyping naming: "miSeq amplicon" workflow runs ONT data and tags it as MiSeq | open | | | |
| WFL-14 | P2 | AI haplotyping exposed in the main viewport with no key check, no consent, macaque defaults | open | | | |
| WFL-15 | P2 | BLAST drawer inconsistencies: CZ ID no-op, `nt` vs `core_nt`, NAO-MGS taxon restriction, no persistence | open | | | |
| WFL-16 | P2 | User-registered workflows are a half-surface: no menu, loose outputs, no sidebar result, "Beta1" copy | open | | | |
| WFL-17 | P2 | Surface asymmetry: capabilities only on one surface (CLI-only exports, context-menu-only tree, import-only rec | open | | | |
| WFL-18 | P2 | Two execution paths for the same operation with different defaults (orient, assembly Reassemble, genotyping) | open | | | |
| WFL-19 | P2 | Failure-path quality: raw enum text, silent no-ops, cleanup errors failing successful runs | open | | | |
| WFL-20 | P2 | Inconsistent result layouts across sibling tools (single vs batch, import destinations, warning states) | open | | | |
| ARC-14 | P3 | `ResultViewportController` / `BlastVerifiable` are premature abstractions with no polymorphic consumer | open | | | |
| ARC-16 | P3 | Misplaced vocabulary: UI event names in Core, test harness in Kit, CGPoint graph model in Workflow, dead notif | open | | | |
| FEA-15 | P3 | About 27 orphaned action handlers, stale validation branches and invisible import history | open | | | |
| FEA-16 | P3 | `features.yaml` GUI entry-point claims that do not exist in the menus | open | | | |
| FEA-17 | P3 | Edit > Find (Cmd-F) is dead in the main window | open | | | |
| PERF-14 | P3 | Racy output-drain idioms (CondaManager 100 ms "drain delay", `readerGroup.enter` inside `readabilityHandler`) | open | | | |
| PERF-15 | P3 | Operation log entries are unbounded per operation | open | | | |
| PERF-16 | P3 | Remaining `runModal`, redundant timer-to-main hops, and test probes as `nonisolated(unsafe)` statics in produc | open | | | |
| REL-15 | P3 | Nightly coordinator auto-commits agent worktrees into main inside the release tool, and is effectively unused | open | | | |
| REL-16 | P3 | Dead or stale release/dependency artifacts (`containers/`, nonexistent smoke script reference) | open | | | |
| REL-17 | P3 | Double notarization and no delta updates, so a full 167 MB download for each of about 38 releases a month | open | | | |
| SCI-19 | P3 | `kraken2 --fasta-input` is not a Kraken2 option (warning only) but is recorded in provenance | open | | | |
| SCI-20 | P3 | Assembly statistics drop IUPAC codes from contig length and count N in the GC denominator | open | | | |
| SCI-21 | P3 | Variant extraction keeps the full REF for records straddling the region start | open | | | |
| SIMP-09 | P3 | Process-doc sprawl and stale process pointers to dead code | open | | | |
| SIMP-10 | P3 | 49 SHA-256 helpers and 15 CSV/TSV escapers with inconsistent rules | open | | | |
| SIMP-11 | P3 | About 5.4K lines of test hooks in production types, and 109 source-text test files | open | | | |
| SIMP-12 | P3 | Two container-runtime factories plus a Docker fallback | open | | | |
| SIMP-13 | P3 | Copy-paste pairs: classifier VCs, genotype replay commands and payloads, tree runners | open | | | |
| SIMP-14 | P3 | Small hygiene items: drifted agent copies, diverged prompt copy, unused fixture, `.gitignore` contradictions | open | | | |
| SIMP-15 | P3 | `scripts/`: 45K Python lines, including one-off research labs and 23.5K lines of script tests | open | | | |
| SIMP-16 | P3 | About 1.4K lines of Python embedded in Swift string literals | open | | | |
| SIMP-17 | P3 | Project-storage cleanup is 9.3K source lines plus 15.7K test lines for a move-to-Trash | open | | | |
| TST-13 | P3 | Build health: 251 unique warnings, including concurrency-isolation warnings in tests and use of deprecated cle | open | | | |
| TST-14 | P3 | Test effort is skewed toward release tooling and policy text over app behaviour | open | | | |
| UX-15 | P3 | Alert and menu wording drift, success modals, dead "Not Yet Implemented" helper, ASCII ellipses | open | | | |
| UX-16 | P3 | Hard-coded light fills in the read track reduce dark-mode contrast | open | | | |
| UX-17 | P3 | `BatchTableView` ⌘-click quick-copy competes with standard ⌘-click multi-select | open | | | |
| UX-18 | P3 | Sample-scope control differs per viewer. TaxTriage's segmented control does not scale | open | | | |
| WFL-21 | P3 | Dead dialogs, launchers and engines kept alive only by tests | open | | | |
