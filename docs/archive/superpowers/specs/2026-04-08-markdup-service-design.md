# Markdup Service Design

**Date:** 2026-04-08
**Status:** Approved, ready for implementation plan

## Goal

Replace the brittle Swift-side position+strand deduplication heuristic with `samtools markdup` — the industry-standard PCR duplicate detection — driving unique read counts in the database AND the miniBAM viewer's excluded-reads filter. Apply uniformly across all four classifier tools that involve alignments: TaxTriage, EsViritu, NVD (materialized BAMs) and NAO-MGS (pseudo-BAMs materialized from SQLite).

## Motivation

The current Swift-side dedup in `BuildDbCommand.computeUniqueReads` and `MiniBAMViewController.detectDuplicates` has already produced multiple bugs:
- Paired-end detection initially fired on a single paired read in an 810K single-end dataset (fixed, but fragile).
- The heuristic is a custom implementation of what `samtools markdup` has solved canonically. We re-derive it twice (CLI + GUI).
- Each viewer opens recomputes dedup, wasting CPU.

Solution: run `samtools markdup` once during import/build-db, persist the duplicate flag (0x400) in the BAM file itself. Every downstream consumer (unique-reads count, miniBAM viewer, any future tool) uses a standard flag filter: `samtools view -F 0x404`. Single source of truth.

## Architecture

### New module: `MarkdupService` in `LungfishIO`

**Files:**
- `Sources/LungfishIO/Services/MarkdupService.swift` — public API
- `Sources/LungfishIO/Services/MarkdupResult.swift` — result struct + error enum

**Public API:**

```swift
public enum MarkdupService {
    /// Runs `samtools markdup` in-place on a single BAM file.
    ///
    /// Pipeline: `samtools sort -n | fixmate -m | sort | markdup`
    /// Output replaces the input atomically. A fresh `.bai` index is created.
    /// Idempotent: if the BAM already has a `@PG ID:samtools.markdup` header line,
    /// the operation is a no-op and `wasAlreadyMarkduped` is true in the result.
    ///
    /// - Parameters:
    ///   - bamURL: Absolute path to a coordinate-sorted BAM file.
    ///   - samtoolsPath: Path to the samtools binary.
    ///   - threads: Number of threads for sort (`samtools sort -@ N`). Default 4.
    ///   - force: Re-run even if already marked. Default false.
    /// - Throws: `MarkdupError` on any pipeline stage failure.
    public static func markdup(
        bamURL: URL,
        samtoolsPath: String,
        threads: Int = 4,
        force: Bool = false
    ) throws -> MarkdupResult

    /// Runs markdup on every `.bam` file in a directory tree.
    ///
    /// Recursively walks the directory. Skips `.bai` / `.csi` files, hidden files,
    /// and BAMs already marked (unless `force: true`).
    public static func markdupDirectory(
        _ dirURL: URL,
        samtoolsPath: String,
        threads: Int = 4,
        force: Bool = false
    ) throws -> [MarkdupResult]

    /// Checks whether a BAM has already been processed by `samtools markdup`.
    ///
    /// Reads the BAM header via `samtools view -H` and scans for a
    /// `@PG ID:samtools.markdup` line (which samtools markdup adds automatically).
    public static func isAlreadyMarkduped(
        bamURL: URL,
        samtoolsPath: String
    ) -> Bool

    /// Counts reads in a BAM file matching a flag filter, optionally restricted
    /// to a reference region.
    ///
    /// Convenience wrapper around `samtools view -c -F <flagFilter> <bam> <region>`.
    /// Used by `BuildDbCommand.updateUniqueReadsInDB` to populate `reads_aligned`
    /// (flagFilter=0x004) and `unique_reads` (flagFilter=0x404).
    public static func countReads(
        bamURL: URL,
        accession: String?,
        flagFilter: Int,
        samtoolsPath: String
    ) throws -> Int
}

public struct MarkdupResult: Sendable {
    public let bamURL: URL
    public let wasAlreadyMarkduped: Bool
    public let totalReads: Int          // post-markdup: view -c -F 0x004
    public let duplicateReads: Int      // post-markdup: totalReads - (view -c -F 0x404)
    public let durationSeconds: Double
}

public enum MarkdupError: Error, LocalizedError, Sendable {
    case toolNotFound
    case fileNotFound(URL)
    case pipelineFailed(stage: String, stderr: String)
    case indexFailed(stderr: String)
    case corruptOutput(reason: String)
}
```

### New CLI subcommand: `MarkdupCommand`

**File:** `Sources/LungfishCLI/Commands/MarkdupCommand.swift`

```swift
struct MarkdupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markdup",
        abstract: "Mark PCR duplicates in BAM files using samtools markdup"
    )

    @Argument(help: "Path to a BAM file or a directory containing BAMs")
    var path: String

    @Flag(name: .long, help: "Re-run markdup even if already marked")
    var force: Bool = false

    @Flag(name: .long, help: "Recursively walk subdirectories (implied for directories)")
    var recursive: Bool = false

    @Option(name: .long, help: "Threads for samtools sort (default 4)")
    var threads: Int = 4

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        // If path is a NAO-MGS result directory (has naomgs.sqlite), materialize pseudo-BAMs first
        // Otherwise, walk BAMs and call MarkdupService.markdup on each
    }
}
```

Registered in `LungfishCLI.swift` subcommand list.

### Pipeline implementation

**Recommended approach: shell pipe via `/bin/sh -c`**

```swift
let cmd = """
\(samtoolsPath) sort -n -@ \(threads) "\(inputPath)" | \
\(samtoolsPath) fixmate -m - - | \
\(samtoolsPath) sort -@ \(threads) - | \
\(samtoolsPath) markdup - "\(tempOutputPath)"
"""
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/sh")
process.arguments = ["-c", cmd]
// ... capture stderr, run, check exit status ...
```

**Rationale:** Swift `Process` + `Pipe` chaining 4 processes is verbose and error-prone (exit status handling, pipe closure ordering, deadlock risks). Shell-out is simpler, and samtools + sh are both hard dependencies already. No user input flows into the command string — paths are generated internally — so shell injection risk is nil.

**Idempotency check (`isAlreadyMarkduped`):**

```swift
let headerProc = Process()
headerProc.executableURL = URL(fileURLWithPath: samtoolsPath)
headerProc.arguments = ["view", "-H", bamURL.path]
// ... capture stdout ...
return output.contains("@PG") && output.contains("ID:samtools.markdup")
```

`samtools markdup` automatically adds a `@PG ID:samtools.markdup PN:samtools VN:...` line to the output BAM header. We scan for `ID:samtools.markdup`.

**Atomic replacement:**

1. Write pipeline output to `<bam>.markdup.tmp`
2. Run `samtools index <bam>.markdup.tmp`
3. `mv <bam>.markdup.tmp     <bam>` (atomic on same filesystem)
4. `mv <bam>.markdup.tmp.bai <bam>.bai`

If any step fails, delete the `.tmp` files and leave the original BAM untouched.

**Error handling:**

- `findSamtools()` returns nil → `MarkdupError.toolNotFound`
- Input BAM doesn't exist → `MarkdupError.fileNotFound(url)`
- Shell pipeline exits non-zero → `MarkdupError.pipelineFailed(stage:"markdup-pipeline", stderr:)` with captured stderr
- `samtools index` fails → `MarkdupError.indexFailed(stderr:)`, `.tmp` files cleaned up
- Output BAM missing after pipeline (corrupt) → `MarkdupError.corruptOutput(reason:)`

## Per-tool integration

| Tool | BAMs | Has `unique_reads` in DB? | markdup step | DB schema change |
|---|---|---|---|---|
| **TaxTriage** | Materialized at `<batch>/minimap2/<sample>.*.bam` | Yes (existing) | In `build-db taxtriage`, before `updateUniqueReadsInDB` runs, call `MarkdupService.markdupDirectory(<batch>/minimap2/)`. Counts use `countReads(flagFilter: 0x404)`. | None |
| **EsViritu** | Materialized at `<batch>/<sample>/bams/<sample>.third.filt.sorted.bam` (after prior `bams/` relocation fix) | Yes (existing) | In `build-db esviritu`, after BAM relocation and before unique-reads update, call `MarkdupService.markdup()` on each BAM. | None |
| **NVD** | Materialized per-sample BAMs from import pipeline | **No (new column needed)** | NVD import calls `MarkdupService.markdupDirectory()` on the result dir after BAM staging. DB gets new `blast_hits.unique_reads INTEGER` column, populated via `countReads(accession: sseqid, flagFilter: 0x404)` for each hit row. | Add `unique_reads INTEGER` to `blast_hits` table |
| **NAO-MGS** | **None (pseudo-BAMs materialized from SQLite)** | No | New `NaoMgsBamMaterializer` generates real BAMs at `<result-dir>/bams/<sample>.bam` from SQLite rows. Then runs markdup. Viewer switches from `displayReads()` to `displayContig()`. | None (BAM paths derived from result dir + sample ID, not stored in DB) |

### TaxTriage integration

In `BuildDbCommand.swift` `TaxTriageSubcommand.run()`, the existing flow:
1. Parse confidence TSV → build rows
2. Create DB
3. Compute unique reads via `updateUniqueReadsInDB(...)`
4. Cleanup

Change step 3: `updateUniqueReadsInDB` now (a) collects unique BAM paths from rows, (b) calls `MarkdupService.markdup()` on each (early return if already marked), (c) for each row, calls `MarkdupService.countReads(bamURL:accession:flagFilter: 0x004)` for `reads_aligned` and `flagFilter: 0x404` for `unique_reads`, (d) updates the DB.

The `reads_aligned` column is regenerated from the BAM (`samtools view -c -F 0x004`). This ensures `reads_aligned - unique_reads = duplicate_reads` holds by construction, and eliminates drift between the TSV-reported count and the actual BAM content. When the two values disagree, the BAM is the ground truth.

### EsViritu integration

Same pattern as TaxTriage. The existing `relocateEsVirituBAMs` step already runs before unique-reads computation, so BAMs are at `<batch>/<sample>/bams/` by the time markdup runs.

### NVD integration

**Schema change:** Add `unique_reads INTEGER` column to `blast_hits` (nullable for backward compatibility with existing NVD databases). Schema migration on read: `ALTER TABLE blast_hits ADD COLUMN unique_reads INTEGER` if the column is missing.

**CLI flow:** NVD import happens via `lungfish-cli nvd import <result-dir>`. After the current import logic stages BAMs into the result directory:
1. Call `MarkdupService.markdupDirectory(<result-dir>)` — marks all BAMs in the tree
2. For each `blast_hits` row, look up the paired BAM via `samples.bam_path`, then call `MarkdupService.countReads(bamURL:, accession: sseqid, flagFilter: 0x404)` and `UPDATE blast_hits SET unique_reads = ?` for that row.

The NVD viewer (`NvdResultViewController`) gets a "Unique Reads" column in its contig detail table alongside the existing `mapped_reads`. miniBAM display naturally benefits because the BAMs already have 0x400 flags set.

### NAO-MGS integration

**New file:** `Sources/LungfishIO/Services/NaoMgsBamMaterializer.swift`

```swift
public enum NaoMgsBamMaterializer {
    /// Generates real BAM files from NAO-MGS SQLite data at <resultURL>/bams/<sample>.bam.
    ///
    /// For each sample in the database:
    /// 1. Query reference_lengths for all accessions referenced by this sample's virus_hits
    /// 2. Synthesize a SAM header with @HD + @SQ lines
    /// 3. Query virus_hits WHERE sample = ? and synthesize SAM alignment lines
    /// 4. Pipe SAM text into `samtools view -bS - | samtools sort -o <bam>`
    /// 5. Create `.bai` index
    /// 6. Run MarkdupService.markdup on the result
    ///
    /// Skips samples whose BAM already exists and is already markdup'd.
    public static func materializeAll(
        database: NaoMgsDatabase,
        resultURL: URL,
        samtoolsPath: String,
        force: Bool = false
    ) throws -> [URL]
}
```

**SAM synthesis per virus_hits row:**

| SAM field | Source |
|---|---|
| QNAME | `seq_id` column |
| FLAG | `16` if `is_reverse_complement` is true, else `0` (single-end, no pair flags) |
| RNAME | `subject_seq_id` column |
| POS | `ref_start + 1` (convert 0-based to 1-based) |
| MAPQ | `60` (default; NAO-MGS doesn't store MAPQ) |
| CIGAR | `cigar` column |
| RNEXT | `*` |
| PNEXT | `0` |
| TLEN | `0` |
| SEQ | `read_sequence` column |
| QUAL | `read_quality` column |

**SAM header synthesis:**

```
@HD	VN:1.6	SO:unsorted
@SQ	SN:<accession>	LN:<reference_length>
@SQ	SN:<accession2>	LN:<reference_length2>
...
@PG	ID:lungfish-naomgs-materializer	PN:lungfish	VN:1.0
```

`reference_lengths` table in the NAO-MGS schema already stores the needed lengths.

**CLI integration:** `lungfish-cli markdup <naomgs-result-dir>` detects the presence of `naomgs.sqlite` and runs the materializer before running markdup on the generated BAMs. `lungfish-cli nao-mgs import` runs the materializer as its final step.

**Viewer change:** `NaoMgsResultViewController` currently calls `miniBAMController.displayReads(reads:contig:contigLength:)` with SQLite-derived reads. Change to construct a BAM URL from `resultURL.appendingPathComponent("bams/\(sample).bam")` and call `displayContig(bamURL:contig:contigLength:indexURL:)` — the same code path used by TaxTriage/EsViritu/NVD.

**Fallback for old databases:** If the generated BAM doesn't exist when the viewer opens (e.g., an old NAO-MGS import that predates this feature), invoke `NaoMgsBamMaterializer.materializeAll()` on-demand before displaying. The existing `displayReads()` method on `MiniBAMViewController` can be removed once the on-demand materialization is in place.

## MiniBAM viewer changes

**Files:**
- `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`

**Delete:**
- `detectDuplicates(in reads:) -> Set<Int>` — the Swift-side position+strand heuristic
- `allDuplicateIndices` stored property
- `pcrDuplicateReadCount` stored property
- `applyDuplicateVisibility(rebuildReference:)` — the visibility toggle logic
- Any UI element that toggles "show/hide duplicates"

**Modify:**
- `displayContig(bamURL:contig:contigLength:indexURL:)` — change `provider.fetchReads(...)` to pass `excludeFlags: 0x404` (unmapped | duplicate) instead of the current default `0x904`. All duplicates are filtered at the samtools layer; the viewer never sees them.
- Update status label to show "N reads (M duplicates removed)" where M = `samtools view -c -F 0x004` minus the fetched count. The count can be computed via a second lightweight `samtools view -c` call, or derived from the DB if available.

**Delete (once NAO-MGS migration is complete):**
- `displayReads(reads: [AlignedRead], contig:, contigLength:)` — the in-memory read-array path used only by NAO-MGS

**Rationale:** Duplicate handling is now entirely upstream. The viewer's job is to display the reads it's given. No flag parsing, no position grouping, no toggle UI.

## Testing strategy

### Functional testing via CLI

The standalone `lungfish-cli markdup` command makes functional testing straightforward. Test fixtures and validation commands are shell-level, easy to write and inspect.

**Test fixtures:**
- Existing `Tests/Fixtures/taxtriage-mini/minimap2/*.bam` (3 BAMs, single-end SARS-CoV-2 reads with indexes)
- New `Tests/Fixtures/markdup-synthetic/known-duplicates.bam` — a small BAM with known duplicate reads, created via a helper that writes SAM → samtools view -bS → samtools sort
- New `Tests/Fixtures/naomgs-materializer/` — minimal NAO-MGS SQLite + reference_lengths data for materializer tests

### Test suites

**1. `Tests/LungfishIOTests/MarkdupServiceTests.swift`** (unit)

- `testMarkdupOnFixtureBAM` — run on taxtriage-mini BAM, verify output is coordinate-sorted, has 0x400 flags set on some reads, has `@PG ID:samtools.markdup` header
- `testIsAlreadyMarkdupedFalseOnUntouched` — returns false before markdup
- `testIsAlreadyMarkdupedTrueAfterMarkdup` — returns true after markdup runs
- `testMarkdupIdempotency` — second call is a no-op, returns `wasAlreadyMarkduped: true`
- `testMarkdupForceReMarks` — `force: true` re-runs even if already marked
- `testMarkdupPreservesCoordinateSortOrder` — verify output header has `SO:coordinate`
- `testMarkdupGeneratesIndex` — verify `.bai` file exists adjacent to output
- `testMarkdupThrowsOnMissingBAM` — throws `MarkdupError.fileNotFound`
- `testCountReadsWithFlagFilter0x004` — returns total mapped reads for an accession
- `testCountReadsWithFlagFilter0x404` — returns mapped minus duplicates (always <= 0x004 count)
- `testCountReadsWithoutAccession` — nil accession returns BAM-wide count

**2. `Tests/LungfishIOTests/NaoMgsBamMaterializerTests.swift`** (unit)

- `testMaterializeSingleSample` — synthesize SQLite rows, call materializer, verify BAM exists and contains expected reads via `samtools view`
- `testMaterializeWithDuplicateReads` — create SQLite rows with 3 duplicate groups, materialize + markdup, verify `samtools flagstat` shows non-zero duplicate count
- `testMaterializeUsesReferenceLengths` — verify `@SQ LN:` values match `reference_lengths` table
- `testMaterializeReverseComplementFlag` — verify `is_reverse_complement = true` → FLAG 16
- `testMaterializeSkipsExistingBAM` — re-run on same directory, verify no regeneration (idempotent)
- `testMaterializeForceRegenerates` — `force: true` re-generates

**3. `Tests/LungfishCLITests/MarkdupCommandTests.swift`** (integration via ArgumentParser)

- `testCliMarkdupSingleBAM` — `MarkdupCommand.parse([bamPath])`, verify in-place modification
- `testCliMarkdupDirectory` — directory input, all BAMs processed
- `testCliMarkdupRecursive` — walks subdirectories (implied for dirs)
- `testCliMarkdupSkipsAlreadyMarked` — second run is no-op
- `testCliMarkdupForceReMarks` — `--force` re-runs
- `testCliMarkdupThreadsOption` — `--threads 2` propagates to samtools sort
- `testCliMarkdupOnTaxTriageResultDir` — end-to-end on `taxtriage-mini`, verify all BAMs marked
- `testCliMarkdupOnNaoMgsResultDir` — end-to-end on NAO-MGS fixture, verify materialization + markdup both run

**4. `Tests/LungfishCLITests/BuildDbCommandMarkdupTests.swift`** (integration, extends existing)

- `testBuildDbTaxTriageRunsMarkdup` — after `build-db taxtriage`, verify BAMs have markdup headers AND `unique_reads` in DB matches `samtools view -c -F 0x404` per row
- `testBuildDbEsVirituRunsMarkdup` — same for EsViritu
- `testBuildDbSkipsMarkdupWhenAlreadyDone` — manually markdup a BAM, run build-db, verify it doesn't re-mark (check mtime)
- `testBuildDbNvdRunsMarkdup` — after NVD import, verify unique_reads column populated

**5. Validation script (one-shot, not a repeating test)**

Before shipping: run a shell script that compares markdup-based counts against the legacy Swift dedup on the 149-sample real dataset at `/Volumes/nvd_remote/.../taxtriage-2026-04-06T20-46-18/`. Log discrepancies. Expected: small differences (markdup handles edge cases better — soft clips, supplementary alignments), no catastrophic disagreements.

### Test fixture generation

A test helper in `Tests/LungfishIOTests/TestSupport/BamFixtureBuilder.swift`:

```swift
enum BamFixtureBuilder {
    /// Creates a minimal BAM file with the given reads, using samtools to compress.
    /// Used for tests that need synthetic BAM data with known duplicates.
    static func makeBAM(
        at url: URL,
        references: [(name: String, length: Int)],
        reads: [(qname: String, flag: Int, rname: String, pos: Int, cigar: String, seq: String, qual: String)],
        samtoolsPath: String
    ) throws
}
```

Tests can call this to produce tiny BAMs with explicit duplicate patterns (e.g., 10 reads at the same position+strand, expected to reduce to 1 after markdup).

## Migration & compatibility

**Existing databases:**
- TaxTriage / EsViritu DBs: re-running `build-db --force` picks up the new markdup path. Old BAMs get marked on first re-run. DB schemas already have `unique_reads` columns; values are updated from markdup-aware counts.
- NVD DBs: need schema migration to add `unique_reads INTEGER`. Use same pattern as NAO-MGS's `reference_lengths` table migration (check on read, `ALTER TABLE ... ADD COLUMN` if missing).
- NAO-MGS DBs: no schema change. First time the viewer opens a row, materialize on-demand.

**Existing BAMs:**
- On-disk BAMs from any source (TaxTriage pipeline output, NVD imports, user imports) can be markdup'd via `lungfish-cli markdup <dir>` at any time. Idempotent.

**GUI auto-build path:**
- When the GUI triggers `build-db` because a `.sqlite` is missing, the new build-db flow runs markdup as part of the pipeline. No GUI-side changes needed beyond the viewer cleanup.

## Scope check & decomposition

This spec is appropriately scoped for one implementation plan:
- One new service (MarkdupService) + one new CLI command + four tool integrations
- Clear boundaries between the service layer and each tool's integration
- Testing strategy spans all layers

If the plan becomes unwieldy during writing, the NAO-MGS integration (the biggest integration because of BAM synthesis) can be split into a follow-up. Keep it in-scope for now per user direction.

## Out of scope

- Marking duplicates in BAM files that are neither from a classifier tool nor imported via Lungfish (e.g., BAMs the user has open in a plain alignment viewer). Users can still run `lungfish-cli markdup` manually on those.
- Supporting non-samtools markdup tools (Picard, bamutil). samtools is the project's standard.
- UMI-aware deduplication. samtools markdup has a `--barcode-tag` option for this but it requires UMI-tagged BAMs, which our pipelines don't currently produce.
- Optical duplicate detection via `-d INT`. Only relevant for PCR-amplified Illumina data at high coverage on the same tile; not our common case.

## Open questions

None. All design decisions have been made during brainstorming:
- Shell pipe (not Process chaining) for the markdup pipeline — simpler, safe because no user input
- In-place atomic replacement with `.markdup.tmp` staging
- `@PG ID:samtools.markdup` header line as the idempotency marker
- `samtools view -c -F 0x404` per (sample, accession) for counting, not `flagstat`
- Filter duplicates out of the miniBAM viewer by default (not show-with-greyed-out)
- NAO-MGS gets materialized BAMs (not a SQL-only dedup shortcut)
- NAO-MGS BAM paths are NOT stored in the DB (derived from `<result-dir>/bams/<sample>.bam`)
- Markdup runs automatically in `build-db` / import pipelines, no user trigger required
