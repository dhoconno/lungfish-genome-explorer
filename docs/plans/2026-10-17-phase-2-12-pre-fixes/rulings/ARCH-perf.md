# ARCH ruling: large-reference fixes (pre-2.12)

Model and effort: opus, effort max (agent type lge-expert, field ARCH, letter A).

Code: worktree `laptop-golden-runner-setup-e5434b`. The coordinator moved it from `c59241ace` to `65539ddcd2fbe756390d0890cda0b5181e77ffc0` during this task, and every `path:line` below is at `65539ddcd`. I checked the move with `git diff --name-only` over every file cited here. `BuildDbCommand+Provenance.swift`, `NativeBundleBuilder.swift`, `BAMImportService.swift`, `MappingViewerBundlePublicationService.swift`, `ImportCommand+FASTA.swift`, `EXPERT-PANEL.md`, `RECORDING-PROVENANCE.md`, `EXTERNAL-VOLUMES.md` and `scripts/ratchets/file-size.baseline` changed, and I read their cited lines again at `65539ddcd`. The coordinator's list of changed files left out the three mapping and import sources, so SWIFT's C3 lines moved (section 6). Data: project 32616 on `/Volumes/corella_geneious`, by `ls` only, on 2026-10-17. Of BIO's ruling I read sections 1, 2.4 and 7 only, as the coordinator asked.

## 1. Rulings

| Id | Ruling |
|---|---|
| Q-S2 | No pointer sidecars. The cause is a projection rule, not a copied batch record. A `build-db esviritu` sidecar beside a BAM or an index keeps only the steps that wrote that file, read it or read the bytes it came from, and the database's sidecar stays the whole run. Older 18 MB sidecars are read as they are, through P1's index, and never rewritten. |
| Q-S4 | Yes. `save` leaves `browser_summary` out when it equals the summary synthesized from the manifest, and keeps it otherwise. The loader synthesizes in memory for a bundle with a genome and never touches the project mirror for it. `project migrate` stops treating that absence as a migration. |
| Q-S5 | `genome/sequences.sqlite`, schema 1, declared by `genome.sequence_index`, with `genome.chromosomes` left out and `format_version` `"2.0"`, written only above a sequence-count threshold. It holds every `ChromosomeInfo` field, as BIO requires. A design for Phase 3. |
| Q-S6 | Neither option now. The viewer bundle stays whole. Its manifest thins through Q-S4 now and Q-S5 later. Resolving the genome through `origin_bundle_path` is refused, and hard links move out with F5b. |
| Q-S7 | The index may persist only outside the project, in `~/Library/Caches/<bundle id>/ProvenanceSidecarIndex/`, keyed by volume UUID and resolved project path. A project-side cache is refused, and so is a head-only read as the index's source. Not in this session. Check C4 decides between Phase 2.12 and Phase 3. |
| Q-B1 | Confirmed, with one fix. `referenceCount` and `unalignedReferenceCount` are optional, and `schemaVersion` is 2 when both are set. `withViewerBundle` must carry both, or publication's second save drops them. They are documented in `docs/formats/analyses-layout.md`. |
| C2 | The `.fai` is read whole and parsed into an ordered array and a name dictionary, and `ReferenceBundle` parses it again on every sequence fetch. F5b cannot rely on it as it stands (Q-A1). |
| C3 | Import saves once (`NativeBundleBuilder.swift:243`). A mapping saves the viewer manifest twice (`MappingViewerBundlePreparer.swift:52`, `BAMImportService.swift:296`) and decodes a 706 MB manifest four times. |
| Scope | This session gets the Q-S2 writer (P4) and F4 with Q-B1 (P5, after P2). Phase 2.12 gets F5a with F5c's thin manifest. Phase 3, by panel vote, gets F5b and hard links, and the persistent index unless C4 pulls it into 2.12. |

## 2. Q-S2. The EsViritu BAM and BAI sidecars

### 2.1 What the code and the data show

The 17.8 MB `steps` array is not the batch record's. It is the record of the `lungfish build-db esviritu` run, and the writer copies most of it beside every output.

- In project 32616 the batch root `.lungfish-provenance.json` is 23,694 bytes and `esviritu.sqlite.lungfish-provenance.json` is 18,259,664 bytes. In sample `SRR35517702`, `bams/` holds a 9,455-byte BAM and a 1,104-byte BAI whose sidecars are 18,262,248 and 18,261,739 bytes, all written at 21:55 (`ls -la`).
- `recordBuildDbProvenance` makes one step for the run. Its outputs are the database and, for EsViritu, every `.bam`, `.bam.bai` and `.bam.csi` under `bams/` (`BuildDbCommand+Provenance.swift:79-81`, `:94-105`, `:271-284`). It writes `envelope.focusedOnOutput(output)` beside each output (`:162-179`).
- `focusedOnOutput` keeps a step when one of its outputs is the focused file, and also every step that has no outputs (`ProvenanceWriter.swift:1399-1405`).
- The run's steps are `relocationSteps + samtoolsProvenance.steps + cleanupSteps` (`BuildDbCommand+EsVirituCore.swift:188-200`). The read-count pass runs two `samtools view -c` for each detection row (`BuildDbCommand.swift:215-252`). Each count and each header probe records `outputs: []` (`BuildDbCommand+SamtoolsProvenance.swift:226-230`, `:242-246`). So do the markdup pipeline's first sort and its other unnamed stages (`:296-313`), and every removal step (`RecordedRemovalStep.swift:36-47`).

So every BAM, BAI and CSI sidecar carries every output-less step of every sample. The size grows with samples times detections, and the number of copies grows with samples. That is 301 files and 5,242 MB here (`SWIFT-perf.md` line 153).

### 2.2 Ruling on the writer

Pointer sidecars are refused, for three reasons.

1. A `<file>.lungfish-provenance.json` is the record of the one file it is named after (`docs/formats/provenance.md:10`). A sidecar that only points elsewhere changes that meaning, which needs a new `schemaVersion` (`:65-71`).
2. Released readers ignore keys they do not know (`:71`), so a released build would show a pointer sidecar as a run with no steps. That is a silently wrong lineage on rollback (ARCH 7, BIO 6).
3. Export, `provenance verify`, the lineage index and the parity named-file rule all read sidecars directly, and each would have to follow the pointer.

The projection changes instead. For each EsViritu output of `build-db` other than the database, the sidecar keeps four kinds of step.

1. Each step that names the file among its outputs, narrowed to that file, as today.
2. Each step without outputs whose inputs name the file's path or its `originPath`, such as that BAM's header probe, first sort and counts, the markdup replacement that names its old bytes and the removal of its `_temp` path.
3. Each step that names no file at all, as today, because nothing ties it to another file. These are the unnamed markdup stages, one set for each BAM.
4. No other step. Counts, probes, sorts and removals that name only other files are dropped. `files` keeps the inputs of the kept steps, as `focusedOnOutput` does (`ProvenanceWriter.swift:1406-1429`).

The inputs of a kept step stay whole, because a step read what it read (BIO 4). The run's own step, the move and the `_temp` removal each list every moved file, so a sidecar keeps those three lists. Q-A3 asks BIO whether they may be narrowed. The lane reports bytes per sidecar before and after on its fixture.

The database's sidecar keeps today's projection. The count steps set `read_count` and `unique_reads` in it (`BuildDbCommand.swift:199-259`), so it stays the one complete record of the run. The batch root keeps the EsViritu Batch record, which `build-db` does not replace (`BuildDbCommand+Provenance.swift:160`, `:188`, `:211`). Kraken2 and TaxTriage keep today's projection, since only the EsViritu branch names an output for each BAM (`:278`).

Placement (ARCH 6, ARCH 7). The new projection goes in a new `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope+LineageFocus.swift`, and only the call at `BuildDbCommand+Provenance.swift:164` changes, for the EsViritu `bams/` outputs. `ProvenanceWriter.swift` sits at its 1514-line baseline (`scripts/ratchets/file-size.baseline:193`), and `focusedOnOutput` stays as it is for its other callers and their goldens.

### 2.3 How readers keep accepting the older large sidecars

- The format does not change. A sidecar with fewer steps is still an envelope at version 2.
- Older sidecars stay as written. A read never rewrites a record (`docs/contracts/RECORDING-PROVENANCE.md:84`, UX 6 at `docs/contracts/EXPERT-PANEL.md:133`), and a rewrite would also void any signature over it.
- Their read cost is P1's job: one index per project per session, a light decode, cancellation, and no envelope kept. This ruling adds nothing to P1's brief.
- A command that compacts older sidecars is not approved. It would rewrite records, it needs BIO's ruling on every fact it keeps and a CLI parity row, and it moves out with the persistent index.

## 3. Q-S4. `browser_summary` left out when it is derivable

### 3.1 Facts

- The key is optional in the format (`docs/formats/reference-bundle.md:57`) and decoded with `decodeIfPresent` (`BundleManifest.swift:564`). Manifest equality already treats a missing summary as the synthesized one (`:773-776`).
- `save` always writes one, because it encodes `withSynthesizedBrowserSummaryIfNeeded()` (`:805-822`), and every mutator clears it (`:640-769`). So every save writes both per-sequence arrays.
- The synthesized summary depends on the manifest alone. It holds the track counts, the mapped reads summed over alignments, and each sequence's name, description, length, aliases and two flags, with `metrics` nil (`:778-803`). BIO finds no writer that stores per-sequence metrics (BIO-perf section 1).
- With no stored summary, `BundleBrowserLoader.load` reads or writes the project mirror `.lungfish-cache/bundle-browser.sqlite` (`BundleBrowserLoader.swift:47-67`, `BundleBrowserMirrorStore.swift:38-41`).
- `lungfish-cli project migrate` reports a `1.0` manifest with no summary as `migration-available`, and without `--dry-run` it writes the summary back (`ProjectCommand.swift:319`, `:402-419`).

### 3.2 Ruling

1. `save` encodes the manifest without `browser_summary` when the stored summary is nil or equals the synthesized one, and with it unchanged otherwise. The test is an equality at save time, so nothing is dropped that synthesis cannot give back (BIO 4, which BIO confirmed for F5a).
2. A bundle without a genome keeps today's path, since its summary comes from the variant databases (`BundleSequenceSummarySynthesizer.swift:68-111`).
3. For a bundle with a genome and no stored summary, `BundleBrowserLoader.load` returns the summary synthesized from the manifest in memory, and neither reads nor writes the mirror. Without this, opening a new SILVA bundle would write a 905,628-row mirror into the project.
4. `project migrate` reports such a manifest as current. The lane narrows the condition at `ProjectCommand.swift:402-404`, leaves the synthesize action in place until the panel removes it (ARCH 7), and names the changed route in its commit (ARCH 4).
5. `BundleManifest.swift` is at its 823-line baseline (`file-size.baseline:85`). The new code goes in a new `Sources/LungfishCore/Bundles/BundleManifest+StoredForm.swift`, and the line at `:820` calls it.

### 3.3 Older bundles and rollback

- An older bundle keeps its stored summary until its next save drops it. A read never rewrites it.
- A released build opens a new manifest, because the key is optional. It synthesizes the summary and writes its own mirror once per bundle (`BundleBrowserLoader.swift:52-60`). A released `project migrate` would offer to write the summary back, which costs size and loses nothing.
- Docs: `docs/formats/reference-bundle.md`, the `browser_summary` row (`:57`) and the sentence on `save` (`:61`).
- Goldens: every captured reference bundle's `manifest.json` changes bytes. The lane writes a prediction row for each before the capture (BIO 7, QA 5).

## 4. Q-S5. The per-sequence sidecar (design for F5b)

### 4.1 Facts

- `GenomeInfo` and `ChromosomeInfo` decode through Swift's synthesized decoder, with no default values, in `BundleTracks.swift:195-240` and `:245-311`. So every released build fails to decode a manifest whose `genome` has no `chromosomes`, or a chromosome entry without `aliases`, `is_primary` or `is_mitochondrial`. `validate()` also reports an empty list (`BundleManifest+Validation.swift:39-40`).
- The `.fai` holds name, length, offset and line geometry (`FASTAIndex.swift:26-45`). Description, aliases and the two flags have no other home.
- About 45 source files read a `chromosomes` array, across Core, IO, Workflow, Operations, App and CLI (`grep -rln '\.chromosomes\b' Sources`).

### 4.2 Ruling

- Name and place. `genome/sequences.sqlite`, beside the FASTA and its indexes, so every copier that carries `genome/` carries it (`MappingViewerBundlePreparer.swift:58-63`).
- Format, schema 1. Table `sequences` in FASTA order with `ordinal INTEGER PRIMARY KEY`, `name TEXT NOT NULL UNIQUE`, `length`, `offset`, `line_bases` and `line_width` (each `INTEGER NOT NULL`), `description TEXT`, `aliases TEXT NOT NULL` (a JSON array), `is_primary INTEGER NOT NULL`, `is_mitochondrial INTEGER NOT NULL`, and `sort_key BLOB NOT NULL` with an index, the natural-order key P3 builds. Table `aliases(alias TEXT NOT NULL, ordinal INTEGER NOT NULL)` with an index on `alias`. Table `meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)` with `schema_version`, `sequence_count`, `total_length` and the SHA-256 of the `.fai` it was built from. Text is stored exactly as the import read it. The geometry columns must equal the `.fai`, which stays for samtools and other tools.
- Writing. Built once in staging by the import, in the pass that writes the `.fai`, with journal mode DELETE, and published with the bundle. A test compares every row's name, length and geometry with the `.fai`. The import record names the file with its digest (BIO 6).
- Reading. Opened read-only and immutable, so a read creates no `-wal` or `-shm` in the bundle (UX 6). The sequence reader looks a name's geometry up here instead of parsing the whole `.fai` (section 6).
- Declaration. `genome.sequence_index` holds `path`, `format` (`sqlite`), `schema_version`, `sequence_count` and `checksum_sha256`. `genome.chromosomes` and `browser_summary` are left out, and `format_version` becomes `"2.0"`. A released build then fails at decode with the error it already shows, rather than showing a wrong list.
- Switch (ARCH 7). The import writes `2.0` only above a sequence count, 10,000 proposed. Below it the `1.0` layout stays, so ordinary references, every golden and every released build are unaffected. A parity test imports one FASTA both ways and compares every answer of the catalog.
- Layering (ARCH 1). One `ReferenceSequenceCatalog` protocol in LungfishIO, with a manifest-array implementation and a SQLite one. `BundleManifest` in LungfishCore only declares the index. Every reader of `chromosomes` moves to the catalog.
- Docs. `docs/formats/reference-bundle.md` (the layout, the `genome` row, a new Sequence index section and format `2.0`) and `docs/formats/bundle-kinds.md` where it lists bundle members.

## 5. Q-S6. The mapping viewer bundle

### 5.1 Facts

- The preparer copies each top-level folder the source manifest names with `COPYFILE_CLONE`, which clones on APFS and copies bytes elsewhere (`MappingViewerBundlePreparer.swift:27-33`, `:113-144`). It records `origin_bundle_path` (`:40`, `:146-162`), passes `browserSummary: nil` (`:50`) and saves (`:52`).
- `ReferenceBundleEscapeRoots` already lets a bundle resolve members into its origin, but only while the viewer and the origin sit in one project and the origin exists with a valid manifest of the same identifier (`ReferenceBundleEscapeRoots.swift:27-38`). Any failed check returns no root (`:45-117`).
- On exFAT, clones and hard links fail with `ENOTSUP`, and the contract says to copy (`docs/contracts/EXTERNAL-VOLUMES.md:70-71`). Symbolic links work there (`:81`).

### 5.2 Ruling

- Resolving the genome through `origin_bundle_path` is refused. Deleting or moving R, or copying the mapping result into another project, would break every viewer made from R (`ReferenceBundleEscapeRoots.swift:54-57`, `:92-95`, `:113-117`). The deletion planner would have to learn that dependency (ARCH 5), and the escape-root code warns against widening its use (`:119-135`).
- Hard links move out with F5b. They help only HFS+ volumes, which lack clones. Two bundles would share one inode, so a writer that rewrites a `genome/` file in place in either bundle would change both. exFAT copies in either case. The copy runs in the CLI's mapping process, not on the main thread, so it was not part of the stall the owner saw.
- What F5c keeps. The viewer manifest drops its per-sequence copy through Q-S4 now, since the preparer passes no summary, and through Q-S5 later. That is a test in the F5a lane, not a lane of its own.
- When the origin moves or is deleted, the viewer still opens, because its bundle is whole. `origin_bundle_path` stays as a lineage hint that resolves to nothing, and the lineage walk stops at the mapping's recorded reference input, as it does today. exFAT behaves the same.

## 6. C2 and C3

C2, the `.fai` on the first sequence fetch.

- `FASTAIndex.init(url:)` reads the whole `.fai` into one `String`, splits it into lines and builds an ordered `[Entry]` and a `[String: Entry]` of every sequence (`FASTAIndex.swift:67-103`). For R that is 38 MB and 905,628 entries, held twice.
- `ReferenceBundle.fetchSequence` builds a new `BgzipIndexedFASTAReader` on each call (`ReferenceBundle.swift:290-302`), and its init parses the `.fai` again (`BgzipIndexedFASTAReader.swift:258-264`). `fetchSequenceSync` does the same through `SyncBgzipFASTAReader` (`ReferenceBundle.swift:342-356`, `BgzipIndexedFASTAReader.swift:554-560`). These are the only two places in `Sources` that build either reader.
- Each fetch also finds the name by a linear scan of `genome.chromosomes`, aliases included (`ReferenceBundle.swift:210-219`).

So F5b cannot rely on the loader as it stands. It must hold one parsed index for each open bundle and look names up through the sidecar's unique index. The parse on every fetch already costs time before F5b, so Q-A1 asks SWIFT to rule on it after check C5.

C3, the save lines. SWIFT cited `MappingViewerBundlePublicationService.swift:1479` and `BAMImportService.swift:293` at `c59241ace`. At `65539ddcd` those lines are `:1478` and `:294`.

- Import of R. The bundle builder that writes `genome/` (`docs/formats/reference-bundle.md:37`) makes the manifest without a summary (`NativeBundleBuilder.swift:230-241`) and saves it once into staging (`:243`), where `save` adds the synthesized summary. `lungfish-cli import` then decodes the published manifest again, only to print counts and ten names (`ImportCommand+FASTA.swift:268-289`).
- Mapping. The preparer decodes R (`MappingViewerBundlePreparer.swift:17`) and saves the viewer manifest (`:52`). `MappingResultLayoutService.swift:149` attaches the BAM through `BAMImportService.importBAM`, which decodes the viewer manifest (`BAMImportService.swift:294`), adds the track and so clears the summary (`:295`, `BundleManifest.swift:732`), and saves again (`BAMImportService.swift:296`). Publication decodes R (`MappingViewerBundlePublicationService.swift:1428`) and the viewer manifest (`:1478`) to list descriptors.

One mapping onto R therefore decodes a 706 MB manifest four times and writes one twice. F5a halves each of these, and F5b removes them.

## 7. Q-B1. `mapping-result.json` schema 2

Facts:

- `PersistedMappingResult` holds `schemaVersion` and camel-case keys such as `totalReads`, `mappedReads` and `unmappedReads` (`MappingResult.swift:165-178`). `save` always writes `schemaVersion: 1` (`:215`), with an atomic `Data.write` (`:229-232`).
- `load` decodes the struct and never reads the number (`:239-257`), so a released build decodes a file with a higher number and extra keys.
- `withViewerBundle` rebuilds the result field by field (`:142-159`), and publication saves that copy into staging (`MappingViewerBundlePublicationService.swift:711`).

Ruling:

- Confirmed. `referenceCount` and `unalignedReferenceCount`, as `Int?`, are written only when known and read as absent otherwise, with BIO's invariant `contigs.count + unalignedReferenceCount == referenceCount`. The names follow the file's camel case, and "unaligned" keeps a reference with no alignment apart from `unmappedReads`, which counts reads.
- Confirmed. `schemaVersion` is 2 when both counts are set and 1 otherwise. A new number is right, because `contigs` changes meaning, from every reference to every reference with an alignment record. Readers accept 1 and 2 and never refuse a higher number.
- Fix. `withViewerBundle` (`MappingResult.swift:146-158`) carries both counts, or publication's save writes schema 1 without them. Test `MappingResultTests.testWithViewerBundleKeepsCounts`.
- Fix. Write through `DurableReplace` (SWIFT 4), as SWIFT's F4 says.
- Rollback. A released build reads a schema-2 result and shows its rows. A schema-1 result reads and exports unchanged (BIO 1), and nothing rewrites it.
- Docs. A new `mapping-result.json` section in `docs/formats/analyses-layout.md`, which already names the file (`:60`, `:94`). It gives every key, both schema numbers and the invariant, and says that an absent count means unknown.

## 8. Q-S7. A persistent sidecar index

- A project-side cache is refused. Finding, loading and displaying a record "create nothing but the export the user saves" (`docs/contracts/RECORDING-PROVENANCE.md:84`), and reading writes nothing into a project (UX 6). The bundle browser mirror in `.lungfish-cache/` (`BundleBrowserMirrorStore.swift:38-41`) is older than both rules and is not a precedent to extend.
- A head-only read is refused as the index's source. The index records a step's outputs except those whose checksum is among that step's inputs (`ProvenanceLineageResolver.swift:385-405`), so it needs `steps`. In sorted-key bytes `steps` comes after `files`, `id` and `outputs`, and a reader may not rely on key order in any case (`docs/formats/provenance.md:18`). An index built from heads would miss producers and end lineage early (BIO 6). A streaming decode that reads every byte and keeps only step checksums stays exact, and that choice is P1's.
- The Q-S2 writer alone helps only new results. Project 32616 keeps its 5.2 GB.
- `~/Library/Caches` is allowed, in this form.
  - Folder `~/Library/Caches/<bundle id>/ProvenanceSidecarIndex/`, with one SQLite file per project. Debug, Preview and Stable have their own bundle ids, so their formats never meet.
  - Key. The SHA-256 of the volume UUID (`URLResourceKey.volumeUUIDStringKey`) and the resolved project path below the volume. A project stores no identity of its own (`Sources/LungfishCore/Storage/ProjectFile.swift` holds only sequence UUIDs), and a read may not write one.
  - Entries. Exactly P1's in-memory entries (checksum, record id, creation date and the sidecar path relative to the project), each with the sidecar's size, modification date and file identifier. An entry is used only while all three still match.
  - A `schema_version`. A mismatch, a read error or a purge by macOS means a rebuild. The cache never stores an envelope, a step or any other record content.
  - Written off the main actor after a walk completes, never into the project or a bundle.
- When. Not in this session, because it builds on P1's index type. Check C4 times the first and second walk on project 32616 once P1 lands. If the first walk takes more than 60 s, or the footprint passes 2 GB, the cache becomes a Phase 2.12 lane. Otherwise it moves out to Phase 3.

## 9. Scope

| Fix | Where | Lane | Files | Tests | Older bundles and projects (ARCH 4, 5, 7) | `docs/formats/` |
|---|---|---|---|---|---|---|
| Q-S2 writer | This session, P4, at any time | lge-worker, opus, effort max | new `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope+LineageFocus.swift`, `BuildDbCommand+Provenance.swift:164` | `ProvenanceEnvelopeLineageFocusTests.testStepsWithoutOutputsThatReadOtherFilesAreDropped` and `testStepsThatReadTheFileOrItsOriginAreKept`. `BuildDbEsVirituRunLevelTests.testEachBAMSidecarHoldsOnlyItsOwnSampleSteps`, with two samples, failing at the base (QA 1). The existing `testEveryRecordOfAMarkdupBuildNamesTheBAMWhereItEnds` and `EsVirituRunLevel.problems` stay green. `provenance verify` passes on the fixture (ARCH 5). A golden prediction row for any captured EsViritu sidecar | No record rewritten. Older sidecars stay readable at version 2. `focusedOnOutput` is unchanged for its other callers, and the database sidecar equals today's projection (parity test) | `provenance.md`, one paragraph on what a `build-db` file sidecar holds |
| F4 with Q-B1 | This session, P5, after P2 lands, because BIO's fixes 4 and 5 edit P2's `ReferenceBundleViewportController.swift` | lge-worker, sonnet, effort max | BIO's six fixes (BIO-perf section 2.4), plus `MappingResult.swift:146-158` and the `DurableReplace` write. `ManagedMappingPipeline.swift` and `ReferenceBundleViewportController.swift` stay within their baselines (`file-size.baseline:163`, `:47`) | BIO's tests, plus `MappingResultTests.testWithViewerBundleKeepsCounts` and a parity test that the builder with its default flag returns every row as before. Golden compare for mapping with BIO's three predictions | Schema 1 reads and exports unchanged, and nothing rewrites it. Released builds read schema 2. The builder's default stays `true` for other callers | `analyses-layout.md`, a new `mapping-result.json` section |
| F5a, with F5c's thin manifest | Phase 2.12, its fifth lane | lge-worker, opus, effort max | new `BundleManifest+StoredForm.swift`, `BundleManifest.swift:820`, `BundleBrowserLoader.swift:47-67`, `ProjectCommand.swift:402-404` | `BundleManifestTests.testSaveOmitsDerivableBrowserSummary` and `testSaveKeepsSummaryThatSynthesisCannotGive`. `BundleBrowserLoaderTests.testGenomeBundleWithoutSummaryWritesNoMirror`, hashing the project before and after (UX 6). `ProjectMigrateTests.testDerivableMissingSummaryIsCurrent`. `MappingViewerBundlePreparerTests.testViewerManifestStoresNoBrowserSummary`. A golden prediction for each reference `manifest.json` | Stored summaries stay until the next save. Released builds read the new manifest. The migrate action stays in code until the panel removes it | `reference-bundle.md` (`:57`, `:61`) |
| F5b | Phase 3, by panel vote (Q-A2) | Two lanes, each lge-worker, opus, effort max: the import writer with the catalog, then the move of the readers | the import, a new catalog in LungfishIO, about 45 readers | Section 4.2 and BIO's six conditions | `1.0` bundles read as now. `2.0` only above the threshold, and released builds refuse it cleanly | `reference-bundle.md`, `bundle-kinds.md` |
| Hard links | Phase 3, with F5b | none now | | | | a row in `docs/contracts/EXTERNAL-VOLUMES.md` if adopted |
| Persistent index | Per check C4 | lge-worker, opus, effort max | a new store in `Sources/LungfishWorkflow/Provenance/` | After a relaunch a cache hit reads no sidecar, a changed sidecar is read again, a purged cache rebuilds, and the project's bytes do not change | Nothing is written into a project | none, since it is not a project layout |

Order in this session. P4 shares no file with P1, P2, P3, UA or UB and can start at any time. P5 waits for P2 to land. The cut order, first to cut first, is P5 and then P4. Each lane gets a fresh field review by lge-expert, sonnet, effort max: ARCH and BIO for P4 (ARCH 4 to 7, BIO 4, 6 and 7, QA 1, 2 and 5), and BIO, ARCH and QA for P5, with SWIFT 4 added. Landing is by lge-worker, sonnet, effort max.

Phase 2.12 names four lanes and allows five (`2.12-cli-equivalence-3-and-exit.md`, Lanes), so F5a takes the last place. F5b does not fit there. It needs a new format version and moves about 45 readers, in a sub-phase whose purpose is the Phase 2 exit review. Moving it out of Phase 2 changes scope across fields, so it goes to a panel vote.

## 10. Checks and open questions

| Id | What | Agent |
|---|---|---|
| C4 | Once P1 lands, with Preview closed, time the first and second lineage walk of one launch on project 32616, read only, and record the peak footprint | lge-worker, sonnet, effort max |
| C5 | List every caller of `ReferenceBundle.fetchSequence` and `fetchSequenceSync` on the viewer and mapping paths, and the actor each runs on | lge-expert, opus, effort max |
| P4 report | Confirm that the app's EsViritu batch reaches `recordBuildDbProvenance` through the CLI, so the fix covers both surfaces (ARCH 2) | inside lane P4 |

| Id | Field | Question |
|---|---|---|
| Q-A1 | SWIFT | Should the `.fai` parse on every fetch and the linear name scan in `ReferenceBundle` be fixed now, as a small lane through a new extension file (`ReferenceBundle.swift` is at its 807-line baseline, `file-size.baseline:119`), or with F5b? |
| Q-A2 | Panel vote | Move F5b and hard links out of Phase 2 to Phase 3, and the persistent index too unless C4 pulls it into 2.12. |
| Q-A3 | BIO | May a focused BAM sidecar narrow the inputs of the batch-wide move, `_temp` removal and run steps to that file's own entries? |
