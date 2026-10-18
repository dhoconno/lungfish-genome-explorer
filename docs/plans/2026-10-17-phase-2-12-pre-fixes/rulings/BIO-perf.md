# BIO ruling: zero-read references and per-sequence records (pre-2.12 fixes)

Model and effort: opus, effort max (agent type lge-expert, field BIO, letter B).

Code: every `path:line` is at `65539ddcd2fbe756390d0890cda0b5181e77ffc0`, the commit the coordinator moved the program worktree to during this task. I read the code at `c59241ace` first and checked the move with `git diff --stat c59241ace 65539ddcd`. Of the files cited here, six source files changed (`AppDelegate.swift`, `AppDelegate+ManagedMapping.swift`, `ConvertCommand.swift`, `BAMImportService.swift`, `BundleBuildHelpers.swift`, `NativeBundleBuilder.swift`), plus `Tests/Fixtures/golden/README.md` and `docs/contracts/EXPERT-PANEL.md`. I found their cited lines again with `git grep -n` at 65539ddcd. The golden mapping fixtures, `scripts/golden/captures.py`, `docs/contracts/READ-PAIRING.md` and `docs/formats/reference-bundle.md` did not change.

Questions: Q-S3 (`SWIFT-perf.md:354`) with the stats-database rows of the verdict's cause 3 (`SWIFT-perf.md:13`), and F5a and F5b (`SWIFT-perf.md:326-327`), under BIO 4, BIO 6 and BIO 7 (`docs/contracts/EXPERT-PANEL.md:124`, `:126`, `:127`).

## 1. Rulings

| Question | Ruling |
|---|---|
| Q-S3, `mapping-result.json` and the contig table | Yes, under a narrower rule than SWIFT's. Leave out a reference only when it has no alignment record of any kind, and record `referenceCount` and `unalignedReferenceCount`. A filter on `mappedReads > 0` alone would drop measured MAPQ and identity values, which BIO 4 forbids. |
| Q-S3, the result export | The export does not need the omitted rows. Each one is a name, its `@SQ` length and six zeros, all held by the BAM header, and the mapping record names the BAM with its digest. The export record must state both counts. |
| Q-S3, zero rows in the stats database | Not in this session, and not in 2.12 as the code stands. These rows come from `samtools idxstats`, not `samtools coverage`, and two readers treat the table as the full list of BAM references. Keep the table whole and read it narrowly (F3c in lane P2). |
| F5a, no stored `browser_summary` when it equals the synthesized one | No fact is lost. The summary copies `genome.chromosomes` and the track lists, and no writer stores per-sequence metrics. Four conditions follow in section 4. |
| F5b, per-sequence records in a sidecar | No fact and no lineage is lost only if the sidecar holds every `ChromosomeInfo` field, aliases included, with exact text, and the manifest and the import record both name it with a digest. SWIFT's list of name, length, description and flags would lose the aliases. Six conditions follow in section 5. |

## 2. Q-S3. The mapping result and its rows

### 2.1 What a zero row holds

- `samtools coverage` emits one row for each `@SQ` line (`Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift:66-71`, `:147-170`). The row's length is `endpos - startpos + 1`, the `@SQ` length (`:164`).
- `mappedReads` is the coverage `numreads` after `--ff UNMAP,SECONDARY,SUPPLEMENTARY,QCFAIL,DUP` (`:39`, `:68`). Mean depth and breadth come from the same filtered pass (`:156-167`).
- Median MAPQ and mean identity come from a second pass, `samtools view <bam>` with no flag filter (`:198`), over every record with aligned query bases (`:633-646`). A reference with no such record gets 0 for both (`:131`, `:672-673`, `:691-693`).
- A reference whose only records are secondary, supplementary, QC-fail or duplicate alignments therefore has `mappedReads` 0 but a measured median MAPQ and mean identity. The existing filter, `rows.filter { $0.mappedReads > 0 }` (`:128`), which SWIFT's F4 would switch on, drops that measurement.
- A reference with no coverage read and no view record holds its name, its `@SQ` length and six zeros. Nothing in it is measured. The BAM header holds the same name and length, and the mapping record names the BAM as an output (`Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift:165-169`).

### 2.2 Who reads the rows

A grep for `<name>.contigs` over `Sources` at c59241ace found three readers of a loaded result's rows, and a `git grep` at 65539ddcd found the same three and no new one.

| Reader | Use | Effect of leaving out unaligned references |
|---|---|---|
| `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:957` | a log line with the row count | the count falls, harmless |
| `MappingResultExportBuilder.delimitedContent` (`Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController.swift:1796-1820`) | TSV or CSV export, one line a row | 905,628 lines become the rows with alignments |
| the export record (`ReferenceBundleViewportController.swift:1906-1911`) | `resolved.contigCount = result.contigs.count` (`:1907`) | the value changes meaning unless the counts are added |

The other loaders of a result read no rows. `BestMappedReadsAnnotationService.swift:65`, `CDSBestAnnotationService.swift:63`, `AlignmentFilterTargetResolver.swift:40` (all in `Sources/LungfishWorkflow/Alignment`), `Sources/LungfishCLI/Commands/BAMAdoptMappingSubcommand.swift:92`, `Sources/LungfishWorkflow/Mapping/ReferenceBundleSourceResolver.swift:108`, `Sources/LungfishApp/App/AppDelegate.swift:1608` and `Sources/LungfishApp/App/AppDelegate+ManagedMapping.swift:305` call `MappingResult.load`, and none of them reads `contigs`. No classifier or report reads a mapping result. The EsViritu and NVD `contigs` hits belong to their own types. The viewer's table already hides rows without primary reads (`ReferenceBundleViewportController.swift:1455-1456`, `:1578-1579`).

One writer already omits rows. The ONT genotyping pipeline saves a filtered result whose rows are only the genotypes with filtered reads (`Sources/LungfishWorkflow/ONTGenotyping/ONTGenotypingPipeline.swift:113-130`, `:302-308`), under schema 1 and with no count of what it left out. So no reader may take `contigs.count` of a schema-1 file as the number of references.

### 2.3 Goldens and READ-PAIRING (BIO 7, BIO 2)

- The mapping capture maps `Tests/Fixtures/sarscov2/genome.fasta` (`scripts/golden/captures.py:564-581`), one contig. Its result has one row, `MT192765.1` with 197 reads (`Tests/Fixtures/golden/mapping/mapping-result.json:4-18`), so the row set does not move.
- Keys that move in `Tests/Fixtures/golden/mapping/mapping-result.json`: `/schemaVersion` from 1 to 2 (`:22`), `/referenceCount` added with 1, `/unalignedReferenceCount` added with 0. Nothing else.
- `lungfish-provenance.json` and `mapping-provenance.json` do not move, because rule R10 masks the digest and size of `mapping-result.json` in both (`Tests/Fixtures/golden/README.md:97`). `counts.json` comes from the capture's own `samtools flagstat` and `idxstats` (`captures.py:623-642`). `cli-report.json` names no contig count (grep). `files.txt` keeps its five files (`Tests/Fixtures/golden/mapping/files.txt:1-5`).
- No golden holds a genotype mapping result or a stats database. The golden file list holds one `mapping-result.json`, this one, and one SQLite dump, of the Kraken2 read index.
- `docs/contracts/READ-PAIRING.md` has no key for mapping results, contigs, coverage, idxstats or chromosome stats (grep over its sections, lines 1-129). The result's read totals come from the normalized counts (`ManagedMappingPipeline.swift:156-158`) and do not change, so BIO 2 holds.
- The golden cannot see the filter, because its only contig has reads. The unit test in 2.4 covers the three cases.

### 2.4 Ruling, fixes and tests

Ruling. `mapping-result.json` may leave out a reference that has no alignment record of any kind, when it records how many it left out. The contig table may show only references with primary reads, as it does today. The export writes the rows the result holds and never filters at export time, so the export of an older schema-1 result keeps its bytes (BIO 1).

Fixes for the F4 lane:

1. `MappingSummaryBuilder.swift:128`, replace the line with the block below, and return `rows.count` and `rows.count - displayedRows.count` to the caller with the rows. Keep the defaults at `:55` and `:110`.
   ```swift
   let displayedRows = includeUnmappedReferenceRows
       ? rows
       : rows.filter { $0.mappedReads > 0 || identities[$0.name] != nil }
   ```
2. `ManagedMappingPipeline.swift:226-233`, pass `includeUnmappedReferenceRows: false` and carry both counts into `MappingResult`.
3. `Sources/LungfishWorkflow/Mapping/MappingResult.swift:103-114` and `:165-178`, add `referenceCount: Int?` and `unalignedReferenceCount: Int?`. `:215` writes `schemaVersion: 2` when both are set and 1 otherwise. `:242` decodes both with `decodeIfPresent`. An absent count means unknown, never that every reference is listed.
4. `ReferenceBundleViewportController.swift:35-38`, pass `includeUnmappedReferenceRows: false`. The rows are filtered again at `:1455-1456`, so the table does not change.
5. `ReferenceBundleViewportController.swift:1906-1911`, add `"referenceCount"` and `"unalignedReferenceCount"` to `resolved` when the result has them. `contigCount` keeps its meaning, the rows written.
6. `ONTGenotypingPipeline.swift:113-130` leaves both counts nil in this change. Its rule keeps genotypes with filtered indel-only reads (`:308`), which is not "no alignment", so `unalignedReferenceCount` would be a false fact there.

The name. Under fix 1 a kept row can show 0 primary reads, so SWIFT's `zeroReadReferenceCount` would not count what was left out. `unalignedReferenceCount` does, and the invariant is `contigs.count + unalignedReferenceCount == referenceCount`.

Tests:
- `MappingSummaryBuilderTests.testOmitsOnlyReferencesWithoutAnyAlignment`, through `buildSummaries(coverageOutput:viewOutput:totalReads:includeUnmappedReferenceRows:)` (`MappingSummaryBuilder.swift:106-119`) with literal text for three references. One has a primary read, one has only a supplementary record (coverage `numreads` 0 and one view line) and one has nothing. Assert two rows, the second with `mappedReads == 0` and `medianMAPQ > 0`, and counts of 3 and 1.
- `MappingResultTests.testSchemaOneResultWithZeroReadRowsLoads` (SWIFT's) and `MappingResultTests.testSchemaTwoRoundTripsCounts`.
- `MappingResultExportTests.testExportWritesStoredRowsAndRecordsCounts`. A schema-2 result exports its rows and the record's `resolved` holds all three counts. A schema-1 result with zero rows exports them unchanged.
- The golden step, `python3 scripts/golden/golden.py compare --only mapping` and then `python3 scripts/golden/predictions.py check predictions.json` with the three key predictions of 2.3 (`Tests/Fixtures/golden/README.md:152`).

### 2.5 A gap outside this question

The coverage and view passes that make the rows are not steps of the mapping record. The record's steps are materialization, indexing, the mapper and normalization (`ManagedMappingPipeline.swift:176`). The summary runs at `:143-148` and is not among them. So the record cannot say which `samtools` calls produced the rows or under which omission rule. This ruling does not ask for it now, because it would move both mapping provenance goldens. It is open item Q-B3.

## 3. Q-S3. Zero rows in the stats database

### 3.1 Where the rows come from

The brief's premise needs one correction. `chromosome_stats` is filled from `samtools idxstats`, not `samtools coverage` (`Sources/LungfishIO/Bundles/AlignmentMetadataDatabase.swift:26`, `:303-317`, `:828-839`). Its writers are `Sources/LungfishWorkflow/Mapping/BAMImportService.swift:185` and `Sources/LungfishWorkflow/Alignment/PreparedAlignmentAttachmentService.swift:428`. The `*` line is skipped (`:833`). The `samtools coverage` rows reach only `MappingResult.contigs` and the viewer's in-memory rows (`MappingSummaryBuilder.swift:127-145`). An idxstats row with `mapped_reads` 0 can still count placed unmapped mates in `unmapped_reads` (`:836-837`).

### 3.2 Who reads them

| Reader | Use | If zero rows left the table |
|---|---|---|
| `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Alignment.swift:153-209` | the BAM-to-reference alias map, from the table's names and lengths (`:167-169`) | wrong-contig reads, explained below |
| `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift:1285` | "Chromosomes" shows the row count | the number changes meaning, from references in the BAM to references with reads |
| `ReadStyleSection.swift:1287-1289` | "Est. Coverage" shows when there is exactly one row | it appears for a multi-contig BAM with one covered contig |
| `ReadStyleSection.swift:537-546`, `AlignmentMetadataDatabase.swift:337-364` | mapped and unmapped totals | unchanged, if rows with `unmapped_reads > 0` stay |
| `ReferenceBundleViewportController.swift:1569-1596` | fallback rows, already `mappedReads > 0` (`:1579`) | unchanged |

No CLI command, classifier, report or golden reads the table (the `git grep` at 65539ddcd, and no golden holds a stats database).

The alias map. When any BAM name is missing from the reference (`:174-178`), each reference without an exact name takes the first unused BAM name of equal length, iterating a `Set` (`:190-195`). Take references X and Y of equal length whose BAM names both differ, where X comes first and only Y has reads. Today X picks between X's and Y's BAM names in hash order. With X's zero row gone, X takes Y's name every time, and Y's reads draw on X. Placing reads on the wrong sequence is a BIO red line. A mapping that LGE runs against its own bundle has equal names, so no alias map is built (`:178`), and the risk falls on imported BAMs named another way.

### 3.3 Ruling

Keep `chromosome_stats` whole. The cost SWIFT measured is the full reads at open, and F3c in lane P2 already reads `WHERE mapped_reads > 0` through `idx_chromstats_mapped` (`AlignmentMetadataDatabase.swift:139-140`, `SWIFT-perf.md:298`), which this ruling endorses. A later phase may drop rows only when all four of these hold.
1. A row leaves only when `mapped_reads = 0` and `unmapped_reads = 0`.
2. `file_info` records `reference_count`, and `ReadStyleSection.swift:1285` shows it.
3. The alias map takes names and lengths from the BAM header's `@SQ` lines, not from this table.
4. The lane predicts each changed key and checks it, as BIO 7 requires, even though no golden holds the table today.

## 4. F5a. No stored `browser_summary` when it equals the synthesized one

Facts.
- The synthesized summary copies name, description, length, aliases and both flags from `genome.chromosomes`, with `metrics: nil` (`Sources/LungfishCore/Bundles/BundleManifest.swift:791-801`). Its aggregate holds the track counts and the sum of the alignment tracks' mapped reads (`:781-790`).
- No writer constructs `BundleBrowserSequenceMetrics`. The only hits are the type and the field that holds it (`Sources/LungfishCore/Bundles/BundleBrowserSummary.swift:50`, `:59`, `:71-77`), so no stored summary holds a measured per-sequence value today.
- The manifest is a recorded output of the import, with its own record at `provenance/manifest.json.lungfish-provenance.json` (`docs/formats/reference-bundle.md:93`). The import saves the manifest into staging (`Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift:243`) before it builds the output records from staging (`:360-363`).

Ruling. No recorded fact is lost, under four conditions.
1. Leave out only a summary equal to the synthesized one, compared on every field, aggregate and metrics included. A stored summary that differs, or a future one with metrics, is written as it is.
2. New writes only. An older bundle keeps its summary. Reading never rewrites `manifest.json`, and a rewrite would also orphan the digest its record holds.
3. The import record hashes the manifest bytes that are published. Test `NativeBundleBuilderProvenanceTests.testRecordedManifestDigestMatchesPublishedManifest` asserts that the published `manifest.json` has no `browser_summary` key and that its SHA-256 equals the digest of the record's output entry for it.
4. In-memory equality does not change, because `==` already compares the equivalent summary (`BundleManifest.swift:774-776`). Test `BundleManifestTests.testSlimManifestDecodesToEqualManifest` saves, loads and compares.

## 5. F5b. Per-sequence records in a sidecar

### 5.1 Each field and its other home

| Field | Written from | Other home in the bundle |
|---|---|---|
| `name`, `length` | the FASTA parse (`NativeBundleBuilder.swift:1316-1385`) | `genome/sequence.fa.gz.fai`, columns 1 and 2 |
| `offset`, `line_bases`, `line_width` | the same parse (`:1346-1348`) | `.fai` columns 3 to 5, a file-layout detail rather than a scientific fact |
| `fasta_description` | the header text after the first space (`:1355-1357`) | the header lines of `sequence.fa.gz`, because the FASTA is copied whole (`:857`) and the U-to-T pass skips header bytes (`Sources/LungfishCore/Models/ThymineAlphabet.swift:66`, `:73-76`) |
| `fasta_description` after an NCBI assembly report | rebuilt as molecule type and molecule (`Sources/LungfishWorkflow/Native/BundleBuildHelpers.swift:386-392`) | none, so the manifest is its only home |
| `aliases`, `is_primary`, `is_mitochondrial` | the assembly report (`BundleBuildHelpers.swift:321-407`) | none in the documented layout (`docs/formats/reference-bundle.md:9-35`) |
| `md5_checksum` of the uncompressed FASTA | `GenomeInfo` (`Sources/LungfishCore/Bundles/BundleTracks.swift:212-213`) | a genome-level value that stays in the manifest |

Descriptions are data, not only labels. `lungfish-cli convert` writes each converted record's description from `chromosome.fastaDescription` (`Sources/LungfishCLI/Commands/ConvertCommand.swift:475`), and name matching reads descriptions (`Sources/LungfishCore/Models/ChromosomeAliasResolver.swift:417`, `Sources/LungfishCore/Bundles/ChromosomeNameMapping.swift:92`). In R they are the SILVA taxonomy paths.

### 5.2 Ruling and tests

Moving the records loses no fact and no lineage only under six conditions.
1. Every field. The sidecar holds all nine `ChromosomeInfo` fields (`BundleTracks.swift:245-310`) in manifest order. SWIFT's "name, length, description and flags" leaves out the aliases, which have no other home. The three layout fields may come from the `.fai` instead, once a test shows equal values.
2. Exact text. `fasta_description` is stored byte for byte. Nil stays distinct from empty, with no trimming, case folding or Unicode normalization. SILVA paths hold spaces, semicolons and non-ASCII names.
3. Declared and checked. The manifest names the sidecar by path, row count and SHA-256, and keeps `total_length` (`BundleTracks.swift:207`) and a sequence count. A reader that finds them disagreeing refuses the sidecar and says why (BIO 4). It never shows a partial list and never rebuilds the records from the `.fai`, which has no descriptions or aliases.
4. Recorded. The sidecar is written into staging before the output records are built (`NativeBundleBuilder.swift:243`, `:360-363`), so the import record lists it with its digest and size.
5. Older bundles keep their arrays, with no migration on read. A later migration command writes and verifies the sidecar and writes its own record before any array leaves a manifest (BIO 6, records before removal).
6. Same outputs. `convert` and name resolution give identical results for a sidecar bundle and its array twin.

Tests:
- `ReferenceSequenceSidecarTests.testSidecarRoundTripsEveryChromosomeField`, over a fixture with assembly-report aliases and flags, a SILVA-like description, an empty one and a nil one.
- `ReferenceSequenceSidecarTests.testMismatchedSidecarIsRefusedWithReason`, once with a changed row count and once with a changed digest.
- `ConvertCommandTests.testSidecarBundleConvertsByteIdentically`, to FASTA and to GenBank.
- `ChromosomeAliasResolverTests.testSidecarAndArrayBundlesResolveIdentically`.
- `NativeBundleBuilderProvenanceTests.testImportRecordListsSequenceSidecar`.

Goldens. No golden holds a reference manifest. The mapping capture maps a bare FASTA (`captures.py:571-579`) and its inventory has no bundle (`files.txt:1-5`). F5a and F5b therefore move no golden, unless a lane adds a CLI option, whose help text then moves.

F5c. If the viewer bundle stops copying per-sequence records, lineage to the descriptions runs through the mapping's reference input record (`ManagedMappingPipeline.swift:170-173`) and `origin_bundle_path`. ARCH rules on the layout. BIO requires that the mapping record keep naming the reference payload with its digest.

## 6. Calls

| Call | Agent type, model, effort | When |
|---|---|---|
| F4 lane, fixes 1 to 6 of 2.4 with its tests and golden predictions | lge-worker, opus, effort max | where ARCH places F4 |
| F5a and F5b lanes, with sections 4 and 5 as acceptance | lge-worker, opus, effort max | where ARCH places them |
| BIO review of each of those lanes | lge-expert (BIO), opus, effort max | after each lane report |
| Fact-check on R, read only. Print three header lines of `genome/sequence.fa.gz` and the same records' `fasta_description`, and confirm the text is equal | lge-worker, sonnet, effort max | before F5b lands. Optional, since condition 1 does not rely on it |

## 7. Open items

| Id | Field | Item |
|---|---|---|
| Q-B1 | ARCH | Confirm `referenceCount`, `unalignedReferenceCount` and schema 2 of `mapping-result.json`, and name the `docs/formats/` file that documents them. |
| Q-B2 | UX | Wording for the omitted references in the mapping summary bar and the export, such as "94 of 905,628 references have alignments". |
| Q-B3 | BIO, 2.12 | Record the coverage and view passes as a step of the mapping record (2.5). It moves both mapping provenance goldens. |
| Q-B4 | BIO, 2.12 | Give the ONT filtered result an omitted-row count under its own rule (`ONTGenotypingPipeline.swift:302-308`). |
