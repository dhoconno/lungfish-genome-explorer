# Findings ledger

Single source of truth for finding status (plan rule 9). Status: `open`, `verified` (still holds at current HEAD), `not-reproduced`, `fixed` (commit + evidence), `accepted` (reason), `deferred` (reason).

| ID | P | Title | Status | Package | Commit | Evidence |
|---|---|---|---|---|---|---|
| FEA-01 | P0 | Manifest rewrites drop alignment tracks and the record store (variant deletion paths) | fixed | P0-B | ca6f0f14d | BundleManifest copy-based mutators; sidebar + drawer + VCF merge migrated; round-trip tests |
| FEA-02 | P0 | GUI FASTQ import silently replaces same-named bundles, and ignores Keep Both and sample-sheet names | fixed | P0-B | 30883db6a | dup check at Imports/, --force only on Replace, --name added, Replace trashes old bundle |
| PERF-04 | P0 | Unique-read counts for TaxTriage and EsViritu are capped at 100,000 parsed reads per contig after buffering up | fixed | P0-C | e3efa6f77,b87e84661 | UniqueReadStartCounter 10/10 incl >100k; AlignmentDataProviderTests 55/55; caches renamed .v2 |
| REL-01 | P0 | Shipped app bundles are owner-only (0700/0600) because of `umask 077` | fixed | P0-A | dabbd4b4c | umask 022 before xcodebuild + chmod; smoke mode check; test_smoke_test_fails_when_app_bundle_is_owner_only |
| SCI-01 | P0 | GFF exported to iVar collapses multi-segment CDS (ORF1ab frameshift, spliced CDS) into one span, which changes | fixed | P0-C | 3af455220 | CDSSegmentPhasesTests 6/6, AnnotationDatabaseGFFExporterTests 5/5; ivar split-vs-merged GFF compared manually |
| TST-01 | P0 | Pre-push unit tier is red on HEAD: 117 failures plus 1 indefinite hang | fixed | P0-A..final | 9535e6da7 | GATE PASS unit tier: 13,825 XCTest + 590 swift-testing, 0 failures (5 pre-existing D8 tests quarantined, TST-15); was 117 failures + hang |
| TST-02 | P0 | No gate runs the broad suite: release selects 186 of about 14.2K tests, the hook is not installed, and 11 rele | fixed | P0-A | b35a3c006 | release.py requires green unit-tier result for commit; appSmokeRequired both channels; hook installed by setup-worktree |
| WFL-01 | P0 | FASTQ-operation outputs are silently quality-binned and, when large, Trim Galore-trimmed during re-ingestion | fixed | P0-B | 7c3fb0fd5,+clumping fix | no re-binning; auto clumping skips instead of Trim Galore; read-count check before source delete |
| WFL-02 | P0 | `tree infer iqtree` deletes the shared project `.tmp`, deletes pre-existing output on refusal, and can deadloc | fixed | P0-B | 6898a985f | no .tmp deletion, refusal deletes nothing, concurrent pipe drain |
| ARC-01 | P1 | Two execution models for GUI analyses, chosen per feature, with no shared service layer | open | | | |
| ARC-02 | P1 | Nine copy-pasted CLI runner actors and about 12 ad-hoc, stringly-typed CLI event schemas | partial | P6-A,P6-A2 | 6bc83748f,057d642b1..c17efbc1d | 6 of 9 runners on CLISubprocessTransport; 3 import runners remain |
| ARC-03 | P1 | Operations-panel "CLI command" strings are hand-built and drift from the real CLI (Kraken2 replay cannot run) | fixed | P6-A2 | 809847a07 | Kraken2 single-sample replay runnable; ClassificationCLIInvocationBuilder |
| ARC-04 | P1 | `OperationCenter.start` can return an already-failed operation, and callers are not forced to notice | fixed | P1-A | c656e84c3 | OperationCenter.begin -> started/refused; 11 callers migrated; per-family never-launch tests; ratchet baseline 18 in pre-push |
| ARC-13 | P1 | TaxTriage view controller runs samtools synchronously on the main actor, with a pipe-ordering hazard | fixed | P4-A | 447955d3d | samtools off main, concurrent drain; TaxTriage UI tests 37/37 integrated |
| FEA-03 | P1 | Annotation edit and delete from the viewer and Inspector are not persisted for reference bundles | fixed | P2-A+orchestrator | 55eb87a2c,cb7c10798,9053d1e95 | live GUI: drawer-selected Inspector delete was a silent no-op (no track id); fixed, sqlite 23 to 22 verified live |
| FEA-04 | P1 | The same BAM or VCF file does different things depending on the entry point, and BAM/VCF have no target choose | open | | | |
| FEA-05 | P1 | Multi-file BAM or VCF import into an open bundle imports only the first file | fixed | P2-A | 7e33703ef | sequential per-bundle import queue |
| FEA-06 | P1 | Quit and window close do not warn about running operations, and interrupted outputs become invisible | fixed | P1-B | b732ea628 | quit/close warning sheets; interrupted outputs surfaced in storage scan |
| FEA-07 | P1 | `OperationCenter.start` does not enforce the bundle lock, so unchecked callers mutate locked bundles | fixed | P1-A | c656e84c3 | drawer-delete sub-claim was wrong (already pre-checked); others migrated |
| FEA-08 | P1 | Read sort and colour modes are implemented and tested but unreachable in the alignment viewer | fixed | P7b | a13bc763 lane | sort/color modes wired via Inspector; context-menu Sort by Base pending |
| PERF-01 | P1 | Alignment scientific actions SHA-256 the whole BAM, index and reference on the main actor, twice per action | fixed | P4-A | f02c6cc87 | off-main hashing + stat-keyed digest cache; coordinator tests 20/20 |
| PERF-02 | P1 | `NativeToolRunner.shared` actor is blocked for the full runtime of `runWithFileOutput` / `runPipeline` childre | fixed | Q2 | eb48026d1 | actor no longer blocked (work in detached task); concurrency test blocked by TST-04 tool lookup in test env |
| PERF-03 | P1 | TaxTriage batch unique-read pass runs directory walks, file parsing and `samtools` on the main actor, then an  | fixed | P4-A | 447955d3d | off-main discovery, keyed table sync, 250ms coalesced reload |
| PERF-05 | P1 | Eight post-import and post-operation call sites run the full recursive project scan synchronously on the main  | fixed | P4-A | bea6e910b | 8/8 reloadFromFilesystem call sites now async |
| PERF-06 | P1 | "Export annotations" and multi-source sequence export decompress and parse the entire genome into memory | fixed | Q2 | c338d802d | annotation export never opens genome |
| REC-01 | P1 | Sibling mutation service deletes backup | fixed | P0-B | 12e6722a6 | VariantMutationPublication recovery path |
| REC-02 | P1 | MSA/tree --force deletes output before work | fixed | Q3 | dd086b592 | tree infer --force atomic swap; failing-iqtree test |
| REC-03 | P1 | Kraken2 taxonomy/BLAST exports lack provenance | fixed | P6-B | 5b00ee8fb | taxonomy + BLAST export sidecars; manual haplotype export atomic |
| REC-04 | P1 | Sidebar VCF/folder drop silently discarded | open | | | |
| REC-05 | P1 | About Saving text promises persistence FEA-03 disproves | fixed | P2-A | cb7c10798 | About Saving now true |
| REL-02 | P1 | CI workflow invalid since 2026-09-14, 24 straight failures, 12 previews shipped on red | accepted | P0-A | 53371073b | owner: hosted CI paused; disabled cleanly |
| REL-03 | P1 | GPL-2.0 Linux kernel shipped without notice or source offer; THIRD-PARTY-NOTICES stale and not bundled | fixed-needs-legal-review | P8-A | a9f982c67 | generated notices + bundled + smoke gate; OWNER: review kernel source-offer wording (uses owner email), zstd BSD election, pin override license URLs |
| REL-04 | P1 | No rollback or yank path for a bad Sparkle release; the floor gate blocks the obvious one | partial | P8-A | 267e82746 | yank plan (dry-run) + floor --yank; execute_yank not implemented this round |
| REL-05 | P1 | Every `gh` call, including the ~167 MB DMG upload, is capped at 180 s | fixed | P8-A | b1e84001b | size-scaled upload timeout; draft->upload->verify->publish |
| SCI-02 | P1 | iVar TSV to VCF converter emits duplicate records for overlapping CDS (ORF1a/ORF1ab) | fixed | P0-C | e3eac6bc0 | IVarTSVToVCFConverterTests 10/10 (overlapping-cds fixture) |
| SCI-03 | P1 | Minimum AF and depth thresholds silently ignored for LoFreq, bcftools, Medaka and Clair3, yet recorded in prov | fixed | P0-C | ffd76587a | bcftools view -i post-filter; provenance records applied thresholds only; ViralVariantCallingPipelineTests (4 env failures: samtools path, TST-04) |
| SCI-04 | P1 | bcftools caller runs with diploid ploidy and max-depth 250 on viral data | fixed | P0-C | ffd76587a | --ploidy 1, mpileup -d 0; managed bcftools 1.24 synthetic 2000x: DP=2000 haploid |
| SCI-05 | P1 | Mapping "reads mapped / total" and per-contig % count alignment records (secondary and supplementary), not rea | fixed | P3-A | c734597fb | primary/primary mapped; 18-record fixture 80% |
| SCI-06 | P1 | Annotation extraction ignores strand and splicing, and the core API applies 5'/3' flanks by coordinate | fixed | Q4 | 8260be365 | strand/splice-aware extraction; orientation-aware flanks |
| SCI-07 | P1 | Region to bundle extraction with Reverse Complement does not transform variants | fixed | Q4 | 8c68a3ba1 | RC variants mirrored + REF/ALT RC |
| SCI-08 | P1 | Lossy quality binning on by default (silent on downloads and FASTQ operation outputs), mislabelled schemes, or | fixed | P0-B,Q3 | 7c3fb0fd5,b90f9a337 | default none; labels corrected (illumina4=7 levels) |
| SCI-09 | P1 | NAO-MGS "coverage %" uses the furthest alignment end as reference length when references were not fetched | fixed | P3-A | 6538d8d39 | reference_length_source; UI shows coverage unavailable |
| TST-03 | P1 | Swift Build migration broke subpath `Bundle.module` fixtures, crashing tests with SIGTRAP | fixed | P0-A | 18b87a387 | fixtureURL helper, 4 classes |
| TST-04 | P1 | Stable-namespace change broke about 75 tests that hard-code `.lungfish` fake homes, and tests cannot inject an | fixed | P0-A2/A3 | 270f5feaa.. | appIdentity injectable; all identity-dependent tests pinned |
| TST-05 | P1 | No per-test or overall timeout: a cancellation test hung for 14+ min and stalls the gate forever | fixed | P0-A,P1-B | 88afe5580 | root cause: actor blocked on waitUntilExit; cancel nonisolated; 5/5 runs <1s; KNOWN_HANGING_TESTS removed; gate timeouts kept |
| TST-06 | P1 | `ci.yml` has been an invalid workflow on every push since 2026-09-14 instead of being disabled cleanly | fixed | P0-A | 53371073b | workflow_dispatch only; valid file |
| UX-01 | P1 | "Delete Annotation" from the viewer and the Inspector silently does nothing on reference bundles | fixed | P2-A | cb7c10798 | same as FEA-03 |
| UX-02 | P1 | Export failures are logged but never shown in EsViritu, TaxTriage (3 paths), NAO-MGS and NVD | fixed | P1-C | bfcad3925 | ResultExportCoordinator added to LungfishKit; migrated EsViritu, TaxTriage x3, NAO-MGS, NVD, plus Kraken2 and 12S; ResultExportCoordinatorTests 2/2 |
| WFL-03 | P1 | "GATK + WhatsHap Phased" is selectable and runnable-looking but always dead-ends | fixed | P1-C | 919af40eb | BAMVariantCallingToolID.catalogCases filters the phased case behind an off flag; BAMVariantCallingDialogRoutingTests 26/26 |
| WFL-04 | P1 | Viral Recon loses outputs on caller overrides and (likely) Nanopore; analysis folder has no provenance; cancel | open | | | |
| WFL-05 | P1 | pbAA results are written into a sidebar-hidden folder; Savont batch samples route to "Unsupported analysis" | fixed | P2-B | af5e6c94 lane | pbAA to Analyses/pbaa-*; savont routed |
| WFL-06 | P1 | Renamed classifier batch folders cannot be reopened (routing uses name prefix, not metadata) | fixed | P2-B | af5e6c94 lane | route by analysis-metadata.json; RenamedClassifierBatchRoutingTests 6/6 |
| WFL-07 | P1 | "Remove Human Reads" database chooser discards the chosen file and rejects the real index | fixed | P1-C | 5e51af98e | removeHumanReadsDatabaseID replaces the file-stem guess; .database dropped from required inputs; request/argv tests 3/3 |
| WFL-08 | P1 | BAM primer trim never matches the scheme's contig to the BAM's `@SQ` name | fixed | P2-D | af5e6c94 lane | @SQ names resolved; loud failure on mismatch |
| WFL-09 | P1 | No shared dependency preflight: most workflows find a missing tool only by failing | open | | | |
| WFL-10 | P1 | Wizard options silently ignored downstream (EsViritu min length, TaxTriage classifiers, demux, seeds, etc.) | fixed | P2-D | af5e6c94 lane | EsViritu min length removed (not an EsViritu option); TaxTriage classifiers; subsample --seed; IQ-TREE blank seed random |
| ARC-05 | P2 | Per-window state leaks through globals (`mainWindowController`, `DocumentManager.shared` mirror, `NSApp.keyWin | open | | | |
| ARC-06 | P2 | Window scoping of notifications is a fail-open convention reimplemented in three controllers | open | | | |
| ARC-07 | P2 | GUI and CLI write different provenance for the same Kraken2 analysis | open | | | |
| ARC-08 | P2 | Dead parallel FASTQ materializer (~1,100 lines) kept alive only by tests | fixed | P5-A | P5-A | parallel FASTQ materializer + MaterializationPipeline removed |
| ARC-09 | P2 | FASTQ derivative operations have two GUI code paths and two CLI-command builders | open | | | |
| ARC-10 | P2 | `AppDelegate` extensions are the business-logic layer for import, export, downloads and classification | open | | | |
| ARC-11 | P2 | About 1,290 test hooks in production types, a symptom of logic trapped in view controllers | open | | | |
| ARC-12 | P2 | `GenotypeResultViewController` is a 9.8K-line god object (323 stored vars, 508 funcs) | open | | | |
| ARC-15 | P2 | Five external-process mechanisms, plus about 120 raw `Process()` sites across all layers | open | | | |
| FEA-09 | P2 | Two locus parsers with different grammar, and no gene lookup in the locus field | fixed | Q4 | 74609ce60 | one LocusQueryParser for ruler + Go to Location |
| FEA-10 | P2 | Settings controls that nothing reads (default zoom window, max undo levels) | fixed | P2-A | 8632b57aa | default zoom wired; max undo control removed |
| FEA-11 | P2 | Export Image/PDF can export a hidden view or the wrong window; some menu actions ignore the key window | open | | | |
| FEA-12 | P2 | GUI BAM and VCF imports record a `lungfish-cli` command that the CLI cannot run | fixed | P6-B | a1e282448 | BAM import real command; VCF import command removed (no CLI attach path yet) |
| FEA-13 | P2 | Variant table dead controls: Het Only chip, single-option Match picker, silent preset rewrite | fixed | P7 | 6c6c748a9 | dead Het Only + single-option picker removed; preset normalization banner |
| FEA-14 | P2 | Output placement differs by entry point (Imports, project root, drop folder, alignment-read-extractions with U | open | | | |
| PERF-07 | P2 | Result and bundle selection opens SQLite databases and runs scans and JSON decodes on the main thread | fixed | Q1b | a206f4813 | variant track scan off main with generation check; main-actor responsiveness test |
| PERF-08 | P2 | Oriented virtual-FASTQ materialization loads the orient map twice as whole `String`s into two `Set<String>` of | fixed | Q2 | a95a10c9a | single streaming pass |
| PERF-09 | P2 | Loading-badge animation invalidates the whole sequence viewer at 18 fps, and horizontal pan redraw is a traili | fixed | Q1 | fb926ae3f,8a5c88145 | badge-rect invalidation; pan throttle; cached maxReadSpan |
| PERF-10 | P2 | MSA drawing allocates an attributed string per residue and re-registers tooltips inside `draw(_:)`, and the gu | partial | Q1 | 11df0160c | gutter range + tooltips fixed; per-residue attributed strings not yet cached |
| PERF-11 | P2 | Process-tree termination spawns `ps` per PID per loop, and quit terminates roots serially on the main thread | fixed | P1-B | 365e17396 | libproc snapshot per phase; concurrent terminateAll |
| PERF-12 | P2 | Blocking waits pin cooperative-pool threads for tool lifetimes | partial | Q2 | eb48026d1 | detached tasks still block pool threads; FASTQIngestionService.runCLISubprocess and runSamtoolsProcess deferred |
| PERF-13 | P2 | Import helper cancellation signals only the helper root and polls with `Thread.sleep` | fixed | P1-B | 793f54fc2 | waitForHelperProcessExit + tree termination at 4 sites |
| REL-06 | P2 | App version inside the hashed dependency manifest resets "Later" and stales receipts every release | open | | | |
| REL-07 | P2 | Five hand-maintained version sites where one would do | open | | | |
| REL-08 | P2 | Legacy alpha bridge and pre-2026.9.2 previews are offered updates with a different bundle ID | open | | | |
| REL-09 | P2 | Release machinery is heavy while the regression gate is thin and no gate launches the app | open | | | |
| REL-10 | P2 | Release builds from the live working checkout, so stray untracked files block releases | open | | | |
| REL-11 | P2 | Conda transitive dependencies are unpinned, so a "dependency set" is not reproducible | open | | | |
| REL-12 | P2 | Database archives and one pipeline are not integrity-pinned; one catalog ID/URL mismatch | open | | | |
| REL-13 | P2 | Pages deploy job (pages:write, id-token:write) uses tag-pinned third-party actions | open | | | |
| REL-14 | P2 | Code claims a Stable release triggers CI conformance; no workflow listens for it | fixed | P8-A | 267e82746 | stale claim removed |
| SCI-10 | P2 | CDS translation ignores `/codon_start`, GFF phase and `/transl_table`, and reverse-strand phase comes from the | fixed | Q4 | a7f09c78a | codon_start, phase, transl_table |
| SCI-11 | P2 | GFF3 export writes phase 0 on every CDS segment, splits one CDS into distinct IDs, and leaves a dangling `Pare | fixed | Q4 | f0b6bab26 | phase via CDSSegmentPhases, one ID, no dangling Parent |
| SCI-12 | P2 | Bgzip FASTA reader returns `\r` and drops bases for CRLF FASTA | fixed | P3-D | f7da65c56 | CRLF bgzip fixture fail-then-pass |
| SCI-13 | P2 | User-visible `chr:start-end` strings mix 0-based and 1-based conventions | fixed | Q4 | 74609ce60 | 1-based display strings |
| SCI-14 | P2 | Variant track chromosome aliasing silently matches by length or max-position (up to 20% tolerance) | fixed | P3-D,Q3 | ddee0b5fa,024eab61c | length matches surfaced as tooltip |
| SCI-15 | P2 | Origin-spanning features on circular genomes are sorted by start, which reorders segments | fixed | Q4 | de9c25fdd | interval order preserved; bounding math uses min/max; renderer order-independent (orchestrator checked) |
| SCI-16 | P2 | Interleaved paired FASTQ subsample via the CLI-backed Operations path is not pair-aware | fixed | Q3 | 7cf08caf7 | reproduced; interleaved -> reformat.sh pair-aware |
| SCI-17 | P2 | Markdup shell pipeline: no `pipefail`, double-quote interpolation of paths, duplicate fraction over alignment  | fixed | P3-A | b1c665c91 | pipefail, argv paths, dup fraction over primary |
| SCI-18 | P2 | Bracken always uses the 150 bp distribution regardless of actual read length | open | | | |
| SIMP-01 | P2 | FASTQ operations have three independent CLI encodings; provenance records a command that did not run | partial | P6-A2 | 6dbee03a4 | search-text/motif + length/dedup argv fixed; full one-builder collapse pending |
| SIMP-02 | P2 | About 5.9K lines of workbook-transaction recovery outlive their only writer | open | | | |
| SIMP-03 | P2 | PrimalScheme3 adapter supports 4 fork versions and 2 external-binary-only selectors (about 3.3K lines) | open | | | |
| SIMP-04 | P2 | Nine copy-pasted CLI subprocess runners (about 3.4K lines) next to an unused kernel runner | partial | P6-A2 | 057d642b1..c17efbc1d | 6 of 9 consolidated |
| SIMP-05 | P2 | Verified dead code: about 5.0K production lines plus about 2.5K test lines (ranked list) | fixed | P5-A | 45ec1f040..3b12093d3 | rows 1-5,7,9,11,12 removed; net -5.2K lines |
| SIMP-06 | P2 | Same-named public types in two modules (`SequencingPlatform`, `AlignmentFilter*`) | open | | | |
| SIMP-07 | P2 | Chromosome aliasing implemented at least 5 times; the dedicated resolver is unused | partial | P3-D | ddee0b5fa | variant-track path now uses resolver; other alias copies remain |
| SIMP-08 | P2 | Docs and review artifacts dominate the checkout and the churn | open | | | |
| TST-07 | P2 | About 300 source-text-inspection tests, 591 assertions over production source strings | open | | | |
| TST-08 | P2 | Low-value tests: tautologies, ArgumentParser echoes, constant re-assertions, vacuous conditionals (about 20% o | open | | | |
| TST-09 | P2 | White-box over-testing: 1,440 test hooks shipped in production code, Genotype area 109K test lines | open | | | |
| TST-10 | P2 | Flakiness sources: wall-clock budgets as tight as 0.1 s, global singletons and defaults, process-wide `setenv` | partial | P0-A3,final | 29edb2099,2fab641eb,9535e6da7 | setenv + UserDefaults leaks fixed; yield/fixed-sleep waits replaced where they flaked |
| TST-11 | P2 | Silent skips: tool-gated app tests ignore `LUNGFISH_REQUIRE_TOOLS`, in-repo fixture misses skip, the conforman | open | | | |
| TST-12 | P2 | XCUITests (40) run nowhere automatically, `appSmokeRequired: false`, core scientific journeys uncovered | open | | | |
| UX-03 | P2 | Keyboard shortcuts implemented in `NSViewController.performKeyEquivalent` are probably never reached, and ⌘0 c | fixed | P7,P7b | 0d42f3f8a + P7b | TaxTriage shortcuts as View menu items; Cmd-0 collision resolved (Opt-Cmd-0) |
| UX-04 | P2 | Edit > Copy and Edit > Find are dead in data views | fixed | P7 | 287aaaa03 | copy TSV + find in BatchTableView tables |
| UX-05 | P2 | Table search and column-filter UI copied four times and drifting. NAO-MGS has no search. TaxTriage hides searc | partial | P7b | a13bc763 lane | shared ColumnHeaderFilterMenu in Batch/Kraken2/EsViritu; NAO-MGS search field; NVD/NAO-MGS menu pending |
| UX-06 | P2 | No table column state is persisted. Four ad-hoc `UserDefaults` schemes exist elsewhere | open | | | not attempted this pass |
| UX-07 | P2 | Same action, different names: BLAST, NCBI lookup, Copy TaxID, Extract labels drift across viewers | partial | P7b | a13bc763 lane | label enum + Copy Taxon ID unified; BLAST/NCBI builder pending |
| UX-08 | P2 | CZ-ID disables Extract on the action bar but the table menu still offers Kraken2 Extract and BLAST | fixed | P1-C | af7a09e1d | TaxonomyViewController.readLevelActionsAvailable threaded into TaxonomyTableView.validateMenuItem; CzIdImportWorkflowTests 7/7 |
| UX-09 | P2 | Result load failures are shown three different ways, one of them silent | fixed | P1-C | bfcad3925,7d800e94f | 12S load failure now routes through clearViewport(statusMessage:) like Assembly/Mapping; TwelveSResultLoadFailureTests 1/1 |
| UX-10 | P2 | Content Text Size is ignored by the Kraken2 table and most sequence-viewer chrome | fixed | P7b | a13bc763 lane | Kraken2 table ContentTypography |
| UX-11 | P2 | Core sequence viewer and track headers are opaque to VoiceOver and keyboard | open | | | |
| UX-12 | P2 | Inspector key/value rows reimplemented about 10 times with different layout and accessibility | fixed | P7 | 1bf0c1400 | InspectorKeyValueRow in Kit |
| UX-13 | P2 | The "viewport interface class" contract and dialog conventions are ceremonial or stale | open | | | |
| UX-14 | P2 | No "no matches" or first-run empty states in result tables and empty projects | partial | P7 | 94ee66683 | no-matches in BatchTableView only |
| WFL-11 | P2 | Operations-panel CLI commands and several provenance argv records are not runnable | partial | P6-A2 | 4f2cccaac | round-trip parser tests for Kraken2 + FASTQ families |
| WFL-12 | P2 | Cancel missing or inert on several long-running paths | partial | P1-B | 01dd95338 | 12S x2, ONT MHC, CZ-ID, BLAST cancel wired; workflow-builder graph + AI provider calls not cancellable |
| WFL-13 | P2 | MHC genotyping naming: "miSeq amplicon" workflow runs ONT data and tags it as MiSeq | fixed | P2-D | af5e6c94 lane | workflow kind derived from input mode |
| WFL-14 | P2 | AI haplotyping exposed in the main viewport with no key check, no consent, macaque defaults | fixed | P1-C (D5) | 96dee9889 | aiHaplotypingUIEnabled=false removes the section from the viewport; defense-in-depth guard in requestAIHaplotyping; execution service/CLI kept; GenotypeResultViewportArtifactsAndOutlineTests 2 new + suite green |
| WFL-15 | P2 | BLAST drawer inconsistencies: CZ ID no-op, `nt` vs `core_nt`, NAO-MGS taxon restriction, no persistence | open | | | |
| WFL-16 | P2 | User-registered workflows are a half-surface: no menu, loose outputs, no sidebar result, "Beta1" copy | open | | | |
| WFL-17 | P2 | Surface asymmetry: capabilities only on one surface (CLI-only exports, context-menu-only tree, import-only rec | open | | | |
| WFL-18 | P2 | Two execution paths for the same operation with different defaults (orient, assembly Reassemble, genotyping) | open | | | |
| WFL-19 | P2 | Failure-path quality: raw enum text, silent no-ops, cleanup errors failing successful runs | fixed | P1-C,Q3 | b3dcd7dc3,d47e79f1d | remaining raw errors + orient silent no-op |
| WFL-20 | P2 | Inconsistent result layouts across sibling tools (single vs batch, import destinations, warning states) | open | | | |
| ARC-14 | P3 | `ResultViewportController` / `BlastVerifiable` are premature abstractions with no polymorphic consumer | fixed | P5-A | P5-A | ResultViewportController/BlastVerifiable removed |
| ARC-16 | P3 | Misplaced vocabulary: UI event names in Core, test harness in Kit, CGPoint graph model in Workflow, dead notif | partial | P5-A | P5-A | dead fastqOrientRequested removed |
| FEA-15 | P3 | About 27 orphaned action handlers, stale validation branches and invisible import history | fixed | P5-A | P5-A | orphaned handlers removed |
| FEA-16 | P3 | `features.yaml` GUI entry-point claims that do not exist in the menus | fixed | P5-A | P5-A | 14 entry points corrected; features-yaml check in pre-push (146/146) |
| FEA-17 | P3 | Edit > Find (Cmd-F) is dead in the main window | fixed | P7,P7b | a13bc763 lane | sidebar find fallback |
| PERF-14 | P3 | Racy output-drain idioms (CondaManager 100 ms "drain delay", `readerGroup.enter` inside `readabilityHandler`) | fixed | Q2 | f31335bc0 | drain to EOF |
| PERF-15 | P3 | Operation log entries are unbounded per operation | fixed | Q2 | a13f9b83b | 2000-entry cap with elision marker |
| PERF-16 | P3 | Remaining `runModal`, redundant timer-to-main hops, and test probes as `nonisolated(unsafe)` statics in produc | open | | | |
| REL-15 | P3 | Nightly coordinator auto-commits agent worktrees into main inside the release tool, and is effectively unused | open | | | |
| REL-16 | P3 | Dead or stale release/dependency artifacts (`containers/`, nonexistent smoke script reference) | open | | | |
| REL-17 | P3 | Double notarization and no delta updates, so a full 167 MB download for each of about 38 releases a month | open | | | |
| SCI-19 | P3 | `kraken2 --fasta-input` is not a Kraken2 option (warning only) but is recorded in provenance | fixed | P3-D | 7af100247 | --fasta-input removed |
| SCI-20 | P3 | Assembly statistics drop IUPAC codes from contig length and count N in the GC denominator | fixed | P3-D | 01b7b995d | IUPAC in length, GC over ACGT |
| SCI-21 | P3 | Variant extraction keeps the full REF for records straddling the region start | fixed | Q4 | 8c68a3ba1 | straddling records excluded |
| SIMP-09 | P3 | Process-doc sprawl and stale process pointers to dead code | open | | | |
| SIMP-10 | P3 | 49 SHA-256 helpers and 15 CSV/TSV escapers with inconsistent rules | partial | P5-D | P5-D | FileDigest + DelimitedText; 5 call sites migrated |
| SIMP-11 | P3 | About 5.4K lines of test hooks in production types, and 109 source-text test files | open | | | |
| SIMP-12 | P3 | Two container-runtime factories plus a Docker fallback | partial | P5-D | P5-D | dead half of container factory removed |
| SIMP-13 | P3 | Copy-paste pairs: classifier VCs, genotype replay commands and payloads, tree runners | open | | | |
| SIMP-14 | P3 | Small hygiene items: drifted agent copies, diverged prompt copy, unused fixture, `.gitignore` contradictions | open | | | |
| SIMP-15 | P3 | `scripts/`: 45K Python lines, including one-off research labs and 23.5K lines of script tests | open | | | |
| SIMP-16 | P3 | About 1.4K lines of Python embedded in Swift string literals | fixed | P5-D | P5-D | embedded Python moved to resources; compile check in pre-push |
| SIMP-17 | P3 | Project-storage cleanup is 9.3K source lines plus 15.7K test lines for a move-to-Trash | open | | | |
| TST-13 | P3 | Build health: 251 unique warnings, including concurrency-isolation warnings in tests and use of deprecated cle | open | | | |
| TST-14 | P3 | Test effort is skewed toward release tooling and policy text over app behaviour | open | | | |
| UX-15 | P3 | Alert and menu wording drift, success modals, dead "Not Yet Implemented" helper, ASCII ellipses | partial | P7 | 519e21ac3 | ellipsis/wording sweep |
| UX-16 | P3 | Hard-coded light fills in the read track reduce dark-mode contrast | fixed | Q1 | a6d26ce62 | dynamic colors; WCAG contrast test |
| UX-17 | P3 | `BatchTableView` ⌘-click quick-copy competes with standard ⌘-click multi-select | fixed | P7 | 287aaaa03 | cmd-click quick-copy removed |
| UX-18 | P3 | Sample-scope control differs per viewer. TaxTriage's segmented control does not scale | accepted | P7b | a13bc763 lane | control unreachable in production (batch mode uses Inspector picker); inert popup added should be DELETED in P5-A |
| WFL-21 | P3 | Dead dialogs, launchers and engines kept alive only by tests | fixed | P5-A | P5-A | 15 orphaned handlers, BatchProcessingEngine, OrientWizardSheet, dead assembly chain |
| GEN-01 | P0 | ONT barcode assignment takes the leftmost exact barcode match anywhere in the read, including inside the ampli | fixed | G1 | 545fcea36 | anchored window after rc(CS2), both orientations, multi-match unassigned; 20-read DRB1 case all FLD0001 |
| GEN-02 | P0 | `minimumMatches: 1` plus a count-only match rule reports homozygotes as heterozygotes (DQ M2/M2 as "M2 / M6",  | mitigated | G2 | 6dd8eb44f | 28-genotype golden test; 6 wrong-but-called now 'ambiguous'; calling rule itself pending owner decision |
| GEN-03 | P1 | `--min-support` does not filter the report CSV or pipeline workbook, contrary to its help text | fixed | G2 | 4af5150a9 | help text corrected (report/workbook intentionally unfiltered) |
| GEN-04 | P1 | Reads tied across alleles are credited in full to each allele with no ambiguity marker. minimap2 `-N 5` makes  | open | | | |
| GEN-05 | P1 | "Locus %" uses three different locus groupings (pipeline haplotype filter, matrix "Viewed Locus", evidence pan | open | | | |
| GEN-06 | P1 | "Minimum percent" means within-sample read fraction for known alleles but fraction of animals for candidate ro | open | | | |
| GEN-07 | P1 | Illumina sample totals count mates before merging while retained reads count merged fragments, which halves re | fixed | GEN-2 | 69c5bb780 | fragment denominators |
| GEN-08 | P2 | A second haplotype of "-" means both "homozygous" and "second haplotype not identified", and the viewer hides  | fixed | GEN-2 | ba411539c | '?' unresolvedSecondHaplotype vs '-' |
| GEN-09 | P2 | The Python demux filter silently resolves duplicate or reverse-complement-colliding barcodes to the first samp | fixed | G1 | 545fcea36 | Python filter rejects colliding barcodes |
| GEN-10 | P2 | Full-length ONT: a zero-SNP hit is a known call regardless of indel size, with no indel count in the call | open | | | |
| GEN-11 | P2 | PacBio exact dual-barcode demux assigns multi-matching reads in Swift `Dictionary` iteration order, which vari | fixed | GEN-2 | bcc258e8e | multi-match unassigned, deterministic |
| GEN-12 | P2 | Provenance and QC gaps: bbtools missing from `managedTools`, hard-coded "resolvedDefaults", hard-coded QC cut- | fixed | G2 | aa3cc573d | bbtools recorded, real thresholds, no AI prompt copy |
| GEN-13 | P2 | Legacy `fastq ont-genotype` maps ONT reads with the short-read preset, ignores `--allow-indels`, and randomly  | fixed | GEN-2 | ed8ab757e | legacy CLI hidden + deprecation notice |
| DS-01 | P1 | Owner-reported: mapping viewport downsample clustered at window start | fixed | DS | 3c44ed94d | fetchReadSketch (count + samtools --subsample) per track; every-decile test; 3M-read BAM 19.8s -> 4.2s |
| NEW-01 | P2 | CLI import bam -o bundle copied loose files, no track | fixed | Q3 | 6e4cac542 | attaches via PreparedAlignmentAttachmentService |
| NEW-02 | P2 | Sidebar watcher misses CLI changes in newly created project | open | live-only |  | reproduced live 3x (signed app, backgrounded, 4-5 windows); NOT reproduced headless single-window (raw binary, /tmp and ~/Documents: FSEvents fire, sidebar reloads, root-removed banner works). Hypotheses: App Nap throttling main-run-loop refresh timer while backgrounded; multi-window registry; read-only fallback branch |
| NEW-03 | P3 | Open Recent duplicates; reopening opens second window | fixed | Q3 | 95cbdfeac | dedupe by path; focus existing window |
| NEW-04 | P2 | test_releasing_lungfish_skill 26/36 failing at base | open | | | pre-existing |
| PERF-17 | P1 | (new, measured) Genotype comparison matrix: 955 ms to build 40x96 visible cells, 350 ms full redraw | partial | Q1c,Q1d | d12957bff,abde7d24f | first-paint cell build ~707->~385 ms, redraw ~126->~93 ms; benchmark bypasses reuse queue (worst case); remaining floor = NSTextField per cell (custom-drawn cell deferred) |
| PERF-18 | P1 | (new) CLIVariantCallingRunner.cancel deadlocked behind in-flight run | fixed | P6-A2 | a84cb151c | struct runner; cancellation tests 3x |
| NEW-06 | P2 | EsViritu labels interleaved pairs Single-end and runs -p unpaired | open | | | live GUI |
| NEW-07 | P1 | Selecting an annotation starts Update Annotation ops and rewrites genome.db; one stuck at 0% holds bundle lock | fixed | NEW-07 lane | e24cacfe4 | no-op commit guard + AppDelegate unchanged-annotation guard + reload before complete; 27 tests |
| DS-02 | P2 | Small contigs: padded fetch window spreads sample over whole contig; in-view share small | open | | | live GUI |
| TST-15 | P2 | Pre-existing Genotype Excel contract conflict + InvalidTransition flake (5 tests) | quarantined | stabilization | | proven failing at a1f439076; KNOWN_PREEXISTING_FAILURES in gate; decision D8 |
| NEW-08 | P1 | Cancelled EsViritu operation stays active after Cancel All (tool processes gone) | fixed | lane+orchestrator | b8e0c32e1,b9990b803,b42a6171b | root cause live: worker stuck in openat (NEW-11). detectToolVersion rethrows cancellation; cancel() forces Cancelled after 10 s but keeps the bundle lock until the worker returns; 5 grace tests |
| NEW-09 | P1 | Cancel Operations and Quit never quits (discarded terminateNow) | fixed | orchestrator | 840f45af4 | QuitWithRunningOperationsTests fail without fix; live: Cancel Operations and Quit exits in ~2 s with 2 ops (one stuck in kernel) |
| NEW-10 | P2 | After an Inspector delete, the drawer keeps the old row and the operation stays at 0% | explained | orchestrator | - | live 2026-09-24: `sample` shows the delete blocked in openat inside the provenance write (NEW-11), so the reload that refreshes the drawer never runs. Row itself is deleted. Recheck once NEW-11 is resolved |
| NEW-11 | P1 | `NoFollowFileSystem.openDirectoryHierarchy` opens every ancestor from `/`, so writes under ~/Desktop, ~/Documents or ~/Downloads need the folder-level TCC grant even when the project was opened by user intent. Without it, provenance writes, `ProjectTempDirectory.create` and the FSEvents watcher setup block forever in `openat` (or fail with EPERM) while plain full-path opens keep working | open (owner decision) | orchestrator | - | live `sample` 2026-09-24: 3 threads blocked in openat (annotation delete provenance, EsViritu FASTA preview temp dir, FileSystemWatcher setup). The debug build's cdhash 9852fc40 does not match the Desktop TCC csreq (cdhash 4dd7c0e1). The same walk from a shell is instant. Likely also explains NEW-08 and possibly NEW-02. Fix options: anchor the no-follow walk at the project or bundle root opened by path, or add a bounded preflight that surfaces a clear permissions error |
