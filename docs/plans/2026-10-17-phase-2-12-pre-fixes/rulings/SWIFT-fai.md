# SWIFT ruling: the per-fetch `.fai` parse and the linear name scan (C5, Q-A1)

Model and effort: lge-expert on opus (Opus 5.5), effort max. Seat SWIFT, letter S.
Code read at `65539ddcd2fbe756390d0890cda0b5181e77ffc0`. Every `path:line` below is at that commit. SCR = `/Users/dho/Documents/lungfish-branch-archive/pre-2-12-fixes`.

## 1. Ruling

| Id | Ruling |
|---|---|
| Q-A1 | Fix now, as one small lane (P6, section 4), not with F5b. Parse the `.fai` once per open `ReferenceBundle`, find names through a first-wins name and alias index built once, remember the rare fallback answers, and move this code into a new extension file. `ReferenceBundle.swift` then falls from 807 lines to about 680. F5b keeps the same seam and only replaces what the name index reads. |
| C5 | Five direct callers and four indirect routes reach the two fetches on the viewer and mapping paths (section 3). One runs on the serial sequence queue and three run on the cooperative pool (row 3 is awaited from the main actor, but the fetch body runs on the global concurrent executor). The four `ClampedSequenceProvider` routes run synchronously on the main actor. Six fetch starts also scan the names on the main actor before they dispatch. |

Why now and not with F5b.

1. The cost comes with every fetch, and the viewer and mapping paths fetch on every navigation. One parse of the SILVA `.fai` costs 28.8 G instructions, 5.6 G cycles and 1.85 s of CPU on this M4 Pro (section 2). Its peak adds 469 MB to the footprint, and the footprint stays up after the parse ends (142 MB after one parse, 540 MB after five).
2. The name scan runs on the main actor at the start of six fetches (section 3.2). It takes 59 to 110 ms for a name near the end of SILVA. A name that the bundle lacks costs 17 to 18 s in the `mapVCFChromosomes` fallback.
3. F5b does not make the fix unnecessary. The `.fai` stays the byte-offset index of `genome/sequence.fa.gz`, because Q-S5 moves `genome.chromosomes` into `genome/sequences.sqlite` and leaves the `.fai` alone (`SCR/rulings/ARCH-perf.md:13`). F5b is in Phase 3 by panel vote (`ARCH-perf.md:19`), so waiting for it leaves Phase 2.12 with these costs.
4. The lane shares no file with P2 or P3 (section 4.6) and needs no ruling from another field.

## 2. Measurement

Script: `SCR/inv/measure_fai_parse.swift`. It mirrors these, line for line in logic:
- `FASTAIndex.init(url:)` (`Sources/LungfishIO/Index/FASTAIndex.swift:67-103`)
- `GZIIndex.init(url:)` (`Sources/LungfishIO/Formats/FASTA/BgzipIndexedFASTAReader.swift:57-94`, `:127-140`)
- `ReferenceBundle.chromosome(named:)` (`Sources/LungfishIO/Bundles/ReferenceBundle.swift:210-219`) and `mapVCFChromosomes` (`Sources/LungfishCore/Bundles/ChromosomeNameMapping.swift:20-117`), over the stored fields of `ChromosomeInfo` (`Sources/LungfishCore/Bundles/BundleTracks.swift:245-299`)
- the proposed name and alias index of section 4.2

It reads the `.fai` and `.gzi` of `/Volumes/corella_geneious/32616/32616.lungfish/Reference Sequences/SILVA_144_SSURef_NR99_tax_silva_trunc.lungfishref/genome/` and writes nothing there. I built it with `xcrun swiftc -O -swift-version 5` into the session scratchpad and ran each mode as its own process under `/usr/bin/time -l` on 2026-10-17.

Load. Other lanes were building and testing on the same 14 cores. Wall time ran 3 to 4 times the CPU time, with 2,458 to 37,142 involuntary context switches per run. Instructions, cycles and CPU time do not depend on that load, so the table gives them first. Wall times are upper bounds.

| What | Result |
|---|---|
| One parse of the 38 MB `.fai` (37,908,707 bytes, 905,628 entries), three separate runs | 28.7 to 28.9 G instructions, 5.6 to 5.7 G cycles, 1.85 to 1.88 s of CPU. On one 4.5 GHz performance core alone that is about 1.25 s. Wall 5.5 to 8.0 s under the load. |
| Where a parse spends it (wall, under the load) | `String(contentsOf:)` 78 ms, `split(separator: "\n")` 2.2 s, `split(separator: "\t")` 3.5 s. The four `Int` parses add almost nothing beyond the field split. The two `Character` splits are the cost. |
| Peak memory of one parse | Footprint up 469 MB. `/usr/bin/time` reports a peak memory footprint of 493,749,016 bytes and a maximum resident set of 497,975,296 bytes for the whole process. In this file MB means 2^20 bytes, as the script prints it. |
| Memory the parsed index holds while alive | 219 MB of live allocations. Each `Entry` is 48 bytes and is held twice, in `orderedEntries` and in `entriesByName` (`FASTAIndex.swift:48-51`). |
| Footprint left after the index is released | 142 MB after one parse. After five parses in a row it is 540 MB, and it stays at 540 MB after the last index is released. |
| Five parses in a row | 5.5, 7.8, 7.7, 8.0 and 8.0 s wall, 9.26 s of CPU in all |
| `.gzi` parse (375,672 bytes, 23,480 entries) | 38 ms cold, 1.4 to 1.9 ms warm |
| `chromosome(named:)` scan, first name (`HG374866.9.1343`) | under 0.1 ms |
| the same, middle name | median 52 ms of 5, minimum 12 ms |
| the same, last name (`JAVXZB010000280.34707.36497`) | median 110 ms of 5, minimum 59 ms |
| the same, a name SILVA lacks (`NO_SUCH_SEQUENCE.1`), through `mapVCFChromosomes` | median 17.7 s of 5, minimum 17.0 s. The `.fai` holds no descriptions, so a fixed 127-character taxonomy string stood in for each one. |
| Proposed name and alias index, build | median 251 ms, minimum 215 ms |
| the same, live allocations | 64 MB |
| the same, lookup | under 1 µs (886 ns under the load, hashing included). It gave the scan's answer for every present probe. |

What this costs in the app today, derived from the table and section 3 rather than timed in the app:
- Each viewer or mapping navigation to a SILVA sequence outside the cached window parses the `.fai` once before its bases draw (1.25 to 1.9 s of CPU on the sequence queue). Up to six main-actor scans come before that, about 0.35 to 0.66 s for a name near the end.
- Copy Sequences in the reference or mapping table parses once per selected row. Copying the bases of an annotation parses once per interval.
- `lungfish-cli convert` of the SILVA bundle fetches each of the 905,628 sequences in turn, which is about 19 days of CPU in parses alone (`Sources/LungfishCLI/Commands/ConvertCommand.swift:469-472`, `:499-507`).

## 3. C5. The callers and the actor each runs on

How the isolation was read. `Package.swift:1` declares `swift-tools-version: 6.2`, and `Package.swift` sets no `swiftSettings`, so no target enables `NonisolatedNonsendingByDefault`. A nonisolated `async` function such as `ReferenceBundle.fetchSequence` (`ReferenceBundle.swift:273`) therefore runs on the global concurrent executor, whatever actor awaits it (SE-0338). A synchronous function runs on its caller's thread. Both fetches build a new reader per call, and each reader init parses the `.fai` (`ReferenceBundle.swift:298`, `:305`, `:351`, `:359`, `BgzipIndexedFASTAReader.swift:264`, `:560`, `FASTAIndex.swift:185`). Both also call the linear `chromosome(named:)` first (`ReferenceBundle.swift:280`, `:330`).

The mapping viewport embeds a viewer whose view is a `SequenceViewerView` (`ReferenceBundleViewportController.swift:618`). Rows 1, 2 and 4 below therefore serve the mapping path too, against the viewer bundle whose `genome/` resolves into the source bundle (`ReferenceBundle.swift:755-763`), so the same 38 MB `.fai`.

### 3.1 Callers on the viewer and mapping paths

| Row | Caller | API | Route | Runs on | Parses per action today |
|---|---|---|---|---|---|
| 1 | `SequenceViewerView+Alignment.swift:1089` in `fetchSequenceAsync` | `fetchSequenceSync` | `drawBundleContent` calls it when the cached window does not cover the visible region (`SequenceViewerView+Rendering.swift:184-192`) | the serial queue `com.lungfish.sequenceFetch`, QoS user-interactive (`SequenceViewerView+Alignment.swift:1060`, `:1086`). The name lookup before the dispatch (`:1069`) runs on the main actor. | one per new window |
| 2 | `SequenceViewerView+Interaction.swift:1731` in `fetchBundleRegionOffMain` | `fetchSequence` | `fetchAnnotationBasesAsync` (`:1665-1677`), one call per interval, from the annotation menu actions at `:1330`, `:1361`, `:1381`, `:1451` and `:1637`. Copy Sequence, for one, runs in `Task { @MainActor }` (`:1324-1340`). | `Task.detached(priority: .userInitiated)` on the cooperative pool (`:1726`). The loop and `bundle.chromosomeNames.first` (`:1668`) run on the main actor. | one per interval |
| 3 | `ReferenceBundleViewportController.swift:635`, through `BundleDataProvider.fetchSequence` (`BundleDataProvider.swift:124`) | `fetchSequence` | Copy Sequences in the viewport's sequence table (`ReferenceBundleViewportController.swift:342-344`, `:626-649`), which direct bundle rows show (`:651-655`). Each action makes a new provider (`:629`) and so a new `ReferenceBundle` (`BundleDataProvider.swift:212-221`). | The `Task` at `:630` and `BundleDataProvider` (`BundleDataProvider.swift:35`) are on the main actor. The `ReferenceBundle.fetchSequence` body runs on the global concurrent executor. | one per selected row, each a whole sequence (`:635`) |
| 4 | `ClampedSequenceProvider.swift:38`, with its extent through `chromosome(named:)` (`:35`) | `fetchSequenceSync` | the four routes 4a to 4d | the caller's thread | one per segment read |
| 4a | `SelectionSection.swift:197` in `computeTranslation(for:)` (`:194-207`), called at `:1432` and `:1451` | through row 4 | Inspector CDS translation | main actor, synchronous (`SelectionSectionViewModel` is `@MainActor`, `:55-57`) | one per CDS interval |
| 4b | `SequenceViewerView.swift:2193` in `showCDSTranslation(for:)` (`:2188-2223`), called at `ViewerViewController.swift:848` | through row 4 | CDS translation track | main actor, synchronous | one per CDS interval |
| 4c | `SequenceViewerView+Tooltips.swift:638` in `cdsCodingContext(for:)` | through row 4 | hover text for variants in a CDS (`:423`, `:523`), only for segments outside the cached window (`:625-634`), cached per annotation (`:614-616`, `:659`) | main actor, synchronous | one per uncached segment |
| 4d | `ViewerViewController+Extraction.swift:646` and `:661` (an extension of `SequenceViewerView`, `:25`) | through row 4 | `SequenceExtractor.extract` at `:105`, `:132`, `:161`, `:192`, `:227` and `:356` (copy as FASTA, copy translation, extraction sheet, visible region) | main actor, synchronous | one per exon or region |
| 5 | `VariantTableExportResolverSnapshot.swift:275` in `sequence(chromosome:start:end:featureLabel:)` (`:246-291`) | `fetchSequenceSync` | `preparingForBackgroundExport` (`:94-128`), called at `AnnotationTableDrawerView+ExportCapture.swift:127` inside the export run at `AnnotationTableDrawerView+ExportUI.swift:137-140`, and at `AnnotationTableExportQuery.swift:100`. It also calls `chromosome(named:)` per feature (`VariantTableExportResolverSnapshot.swift:203`). | `Task.detached(priority: .userInitiated)`, the cooperative pool | one per CDS segment outside the cached window |

### 3.2 Name scans on the main actor before a dispatch

Each of these calls the linear `chromosomeLength(named:)` on the main actor before it hands work to a queue. A mapping onto SILVA runs at least the sequence, depth and reads fetches on each navigation.
- `fetchVariantsAsync` (`SequenceViewerView+Alignment.swift:216`, scan at `:225`)
- `fetchDepthAsync` (`:340`, scan at `:343`)
- `fetchReadsAsync` (`:662`, scan at `:665`)
- `fetchGenotypesAsync` (`:879`, scan at `:891`)
- `fetchSequenceAsync` (`:1062`, scan at `:1069`)
- `fetchAnnotationsAsync` (`SequenceViewerView+Rendering.swift:903`, scan at `:909`)

Other main-actor lookups: `consequenceChromosomeName` (`SequenceViewerView+Tooltips.swift:596`), called twice per cached CDS annotation while the variant hover text is built (`:412-416`), `ViewerViewController+Extraction.swift:677`, `SequenceViewerView+Interaction.swift:1522` and `:1555`, and `AppDelegate+SequenceMenu.swift:678`. The full name list is rebuilt to take its first element at `SelectionSection.swift:198`, `SequenceViewerView+Interaction.swift:1668`, `SequenceViewerView.swift:2194` and `ViewerViewController+Extraction.swift:676` (`ReferenceBundle.swift:202-204` maps all 905,628 records each time, not measured).

### 3.3 Other callers, outside the viewer and mapping paths

Not traced for their actor. P6 removes their repeated parse as well.
- `ConvertCommand.swift:472`, one fetch per sequence in a sequential loop (`:470`, `:499-507`). It also keeps every sequence in memory, which P6 does not change.
- `BundleExtractAnnotationsSubcommand.swift:197`, one fetch per annotation record (`:195`)
- `ExtractSequenceSubcommand+Bundle.swift:196` and `:203`, through `ClampedSequenceProvider`
- `SequenceAnnotationTrackWorkflow.swift:314` and `:771`
- `MHCReferenceVisualizationArtifactBuilder.swift:156` (ONT genotyping)

A note on `SequenceViewerView+Interaction.swift:1714-1721`. The comment says a nonisolated `async` callee "can inherit the caller's (main) thread". Under this package's settings it does not. Keep the `Task.detached` anyway, because it stays correct if the package ever adopts `NonisolatedNonsendingByDefault`.

## 4. Lane P6: one parse and one name index per open bundle

Agent: lge-worker, opus, effort max. Own worktree from base `65539ddcd2fbe756390d0890cda0b5181e77ffc0`, rules `SCR/briefs/lane-rules.md`, report `SCR/lanes/P6/P6.md`, stop line 120 calls. It can start now. Opus rather than sonnet, because the lock scope, the `Sendable` shape and the exact lookup order must all hold at once.

Reviewers before landing: a fresh lge-expert for SWIFT, opus, effort max, applying SWIFT 1, 2, 5 and 7 and QA 1 and 2, and a fresh lge-expert for BIO, opus, effort max, for unchanged bases and unchanged name resolution.

### 4.1 Files

- New `Sources/LungfishIO/Bundles/ReferenceBundle+SequenceAccess.swift`, about 200 lines.
- `Sources/LungfishIO/Bundles/ReferenceBundle.swift`. Delete `:206-228` (`chromosome(named:)` and `chromosomeLength(named:)`) and `:264-371` (the Sequence Access section through `canonicalRegion`). Add one stored property after `:66`. The file falls to about 680 lines.
- `scripts/ratchets/file-size.baseline:119`, removed by `--update` (section 4.4).
- New `Tests/LungfishIOTests/ReferenceBundleSequenceAccessTests.swift`.
- Item 4 only: `SelectionSection.swift:198`, `SequenceViewerView+Interaction.swift:1668`, `SequenceViewerView.swift:2194`, `ViewerViewController+Extraction.swift:676`.

### 4.2 Design (milestone M1)

1. The stored property, `ReferenceBundle.swift` after `:66`. It is internal so the extension in the new file can reach it, and its default value serves all three inits (`:80`, `:142`, `:153`).

   ```swift
   /// The name index and the sequence reader, each built once on first use (`ReferenceBundle+SequenceAccess.swift`).
   let sequenceCache = ReferenceBundleSequenceCache()
   ```

2. The cache, in the new file. Two independent slots, each behind its own `OSAllocatedUnfairLock` (the type `ReferenceBundle.swift:66` already uses), so a name lookup on the main actor never waits behind a `.fai` parse. Each slot is built while its lock is held, so concurrent first callers build it once and the others wait. A failed reader build throws and is not stored, so a later fetch retries and throws what it throws today.

   ```swift
   final class ReferenceBundleSequenceCache: Sendable {
       enum Reader: Sendable {
           case bgzip(SyncBgzipFASTAReader)
           case plain(IndexedFASTAReader)
       }

       /// First position of each name and of each alias in `genome.chromosomes`.
       struct NameIndex: Sendable {
           let byName: [String: Int]
           let byAlias: [String: Int]

           init(_ chromosomes: [ChromosomeInfo]) {
               var byName: [String: Int] = [:]
               byName.reserveCapacity(chromosomes.count)
               var byAlias: [String: Int] = [:]
               for (position, chromosome) in chromosomes.enumerated() {
                   if byName[chromosome.name] == nil { byName[chromosome.name] = position }
                   for alias in chromosome.aliases where byAlias[alias] == nil { byAlias[alias] = position }
               }
               self.byName = byName
               self.byAlias = byAlias
           }

           /// The answer of `first(where: { $0.name == name || $0.aliases.contains(name) })`.
           func position(of name: String) -> Int? {
               switch (byName[name], byAlias[name]) {
               case let (named?, aliased?): return min(named, aliased)
               case let (named?, nil): return named
               case let (nil, aliased?): return aliased
               case (nil, nil): return nil
               }
           }
       }

       private struct NameState: Sendable {
           var index: NameIndex?
           var fallbackAnswers: [String: Int?] = [:]
           var indexBuilds = 0
           var fallbackRuns = 0
       }

       private struct ReaderState: Sendable {
           var reader: Reader?
           var builds = 0
       }

       private static let fallbackAnswerLimit = 1_024
       private let names = OSAllocatedUnfairLock(initialState: NameState())
       private let readers = OSAllocatedUnfairLock(initialState: ReaderState())

       func position(of name: String, in chromosomes: [ChromosomeInfo]) -> Int? {
           let known: Int?? = names.withLock { state in
               if state.index == nil {
                   state.index = NameIndex(chromosomes)
                   state.indexBuilds += 1
               }
               if let position = state.index?.position(of: name) { return .some(position) }
               return state.fallbackAnswers[name]
           }
           if let known { return known }
           // The fallback scans every record several times (17 s for a missing SILVA name), so it runs outside the lock.
           let mappedName = mapVCFChromosomes([name], toBundleChromosomes: chromosomes)[name]
           return names.withLock { state in
               let answer = mappedName.flatMap { state.index?.byName[$0] }
               if state.fallbackAnswers.count < Self.fallbackAnswerLimit { state.fallbackAnswers[name] = answer }
               state.fallbackRuns += 1
               return answer
           }
       }

       func reader(for bundle: ReferenceBundle, path: String, indexPath: String, gzipIndexPath: String?) throws -> Reader {
           try readers.withLock { state in
               if let reader = state.reader { return reader }
               let genomeURL = try bundle.memberURL(for: path, field: "genome.path")
               let faiURL = try bundle.memberURL(for: indexPath, field: "genome.indexPath")
               let reader: Reader
               if let gzipIndexPath {
                   let gziURL = try bundle.memberURL(for: gzipIndexPath, field: "genome.gzipIndexPath")
                   reader = .bgzip(try SyncBgzipFASTAReader(url: genomeURL, faiURL: faiURL, gziURL: gziURL))
               } else {
                   reader = .plain(try IndexedFASTAReader(url: genomeURL, indexURL: faiURL))
               }
               state.reader = reader
               state.builds += 1
               return reader
           }
       }

       // Counting seams for the tests.
       var nameIndexBuildCount: Int { names.withLock { $0.indexBuilds } }
       var fallbackRunCount: Int { names.withLock { $0.fallbackRuns } }
       var readerBuildCount: Int { readers.withLock { $0.builds } }
   }
   ```

   Why each part holds.
   - The two maps give exactly the answer of the scan at `ReferenceBundle.swift:212`. For a key, the scan returns the earliest record whose name or one of whose aliases equals it, and that is the smaller of the first name position and the first alias position.
   - The fallback keeps `:215-218` exactly. `mapVCFChromosomes` runs on the same records, and its answer is looked up by name only, as `chromosomes.first { $0.name == mappedName }` does at `:218`. Remembering it is exact because `manifest` is a `let` (`:54`). The 1,024-name cap bounds its memory.
   - `memberURL(for:field:)` is the public wrapper of `validatedBundleMemberURL` (`:767-769`, `:778-789`), so URL validation and its errors are unchanged, and no access level in `ReferenceBundle.swift` changes.
   - `SyncBgzipFASTAReader` and `IndexedFASTAReader` are `final class ... Sendable` with only `let` storage, and they open a `FileHandle` per read (`BgzipIndexedFASTAReader.swift:531-562`, `:614`, `FASTAIndex.swift:159-186`, `:202`, `:264`). One shared instance is therefore safe for concurrent reads.

3. The moved methods, in an `extension ReferenceBundle` in the new file, with their signatures and doc comments unchanged.
   - `chromosome(named:)` returns `sequenceCache.position(of: name, in: chromosomes).map { chromosomes[$0] }` after the same `manifest.genome?.chromosomes` guard as `:211`. `chromosomeLength(named:)` stays a one-line wrapper.
   - `fetchSequence(region:)` and `fetchSequenceSync(region:)` share one private body. It keeps today's order of checks and their errors: no genome gives `""`, an unknown name throws `chromosomeNotFound`, a bad range throws `regionOutOfBounds` with the `FASTAOutOfBoundsLog` level (`:274-288`, `:324-340`), and `canonicalRegion` (`:367-370`, moved) gives the record's own name. It then reads through `sequenceCache.reader(...)` with `fetchSync`.
   - `fetchSequence` therefore no longer builds a `BgzipIndexedFASTAReader` actor per call. The actor's read code (`BgzipIndexedFASTAReader.swift:299-334`, `:357-498`) matches the sync reader's (`:568-609`, `:612-746`) step for step, apart from its logging and the file handle, so the bases are the same. The actor stays for its own users and tests.
   - The extension declares its own `Logger`, since the one at `ReferenceBundle.swift:69` is private. Drop the per-fetch "Creating SyncBgzipFASTAReader" lines (`:349`, `:352`), since no reader is made per fetch.

4. Two small additions in the extension.
   - `public var firstChromosomeName: String? { manifest.genome?.chromosomes.first?.name }`, and the four `bundle.chromosomeNames.first` sites of section 3.2 use it, so they stop copying 905,628 names to read one.
   - `public func prepareSequenceAccess() throws`, which builds the name index and the reader without a lookup. Its doc comment says to call it off the main actor. P6 adds no caller. Section 4.7 wires it after P2.

Memory and the main actor after M1, for SILVA.
- One open bundle holds the reader's index (219 MB live, measured) and the name index (64 MB live, measured), each built once. Today each fetch peaks 469 MB higher and leaves 142 to 540 MB in the footprint. The viewer and a mapping viewport on the same reference are two bundles, so about 570 MB. M2 lowers the reader's share.
- The reader is first built by the first fetch, which in the viewer runs on the sequence queue (row 1). A main-actor `ClampedSequenceProvider` read that comes first builds it on the main actor once, where today it parses on every read.
- The name index is first built by the first lookup, today on the main actor in the first `fetch…Async` of section 3.2. That costs 215 to 251 ms once for SILVA and about 1 ms for a genome of 3,000 contigs (scaled, not measured), and it replaces up to six 59 to 110 ms scans per navigation. Section 4.7 moves that one build off the main actor after P2 lands.

### 4.3 Tests

New file `Tests/LungfishIOTests/ReferenceBundleSequenceAccessTests.swift`, with `@testable import LungfishIO`. Counting seams only, no timing thresholds. Build the bgzip and plain bundle fixtures the way the existing `ReferenceBundleTests` and `BgzipIndexedFASTAReaderCRLFTests` do, which the lane reads first.

1. `testChromosomeNamedMatchesTheLinearScan`, a freeze, written and passing at the base first (QA 1). The fixture manifest holds eight records: `chr1` with alias `1`, `chr2` with aliases `2` and `chrX`, a later record named `chrX`, `MN908947`, `NC_041754.1` with description `Macaca mulatta chromosome 7`, two records that share alias `shared`, and a name that appears twice. The oracle is the old body of `ReferenceBundle.swift:210-219`, copied into the test as a free function. Assert that `bundle.chromosome(named: probe)` and the oracle return the same `name` and `length` for every name, every alias and the probes `MN908947.3`, `X`, `7` and `nope`.
2. `testLookupsBuildTheNameIndexOnceAndNeverParseTheFai`. After 100 lookups, `bundle.sequenceCache.nameIndexBuildCount == 1` and `readerBuildCount == 0`.
3. `testFallbackRunsOncePerMissingName`. Look up `MN908947.3` and `nope` three times each. Assert `fallbackRunCount == 2` and that each answer equals the oracle's.
4. `testFetchesParseTheIndexOncePerBundle`. A bgzip bundle with three records. Two `fetchSequenceSync` calls and two `fetchSequence` calls over two records, one of them through an alias. Assert `readerBuildCount == 1` and that each result equals the known bases. At the base the seam does not exist, so the test fails to build there (QA 1).
5. `testConcurrentFirstFetchesBuildTheReaderOnce`. Sixteen `fetchSequence` calls in one `withThrowingTaskGroup` on a fresh bundle. Assert `readerBuildCount == 1` and sixteen equal results.
6. `testUncompressedBundleReadsThroughTheCache`. A plain FASTA bundle, two reads. Assert `readerBuildCount == 1` and the bases of `IndexedFASTAReader(url:indexURL:).fetchSync` for the same regions.

Then run, each with `swift test --skip-update --filter`: `ReferenceBundleSequenceAccessTests`, `ReferenceBundleTests`, `BgzipIndexedFASTAReaderCRLFTests`, and the app tests that use `fastaOperationThreadingProbe`, which the lane finds with `rg fastaOperationThreadingProbe Tests`.

### 4.4 Ratchets and checks

- `python3 scripts/ratchets/file-size.sh` reports the shrink. `python3 scripts/ratchets/file-size.sh --update` then removes `ReferenceBundle.swift 807` (`file-size.baseline:119`), because a file at 800 lines or fewer leaves the baseline (`file-size.sh:5-8`). The new file stays under 800.
- `python3 scripts/ratchets/concurrency-hatches.sh` stays flat. It counts `MainActor.assumeIsolated`, `@unchecked Sendable` and `nonisolated(unsafe)` (`concurrency-hatches.sh:31-37`), and P6 adds none of them. The counters are instance state behind the locks, not a `static var`.
- P6 adds no public type, so `docs/architecture/MODULES.md` does not change (`lane-rules.md:21`).
- The landing, not the lane, runs `python3 scripts/golden/golden.py compare`, because genotyping (`MHCReferenceVisualizationArtifactBuilder.swift:156`) and the CLI extraction commands (section 3.3) read through the changed fetch.

### 4.5 Milestone M2, optional in the same lane

Only after M1 is committed and its tests pass, and only within the stop line. Otherwise M2 waits for Phase 3 with F5b and Q-S10.

- `FASTAIndex.swift:47-51` and `:101-119`. Keep `orderedEntries` and replace `entriesByName: [String: Entry]` with `positionByName: [String: Int]`, so each entry is stored once. The last duplicate wins, as `byName[entry.name] = entry` does at `:98`. `init(entries:)` keeps trapping on a duplicate name, as `Dictionary(uniqueKeysWithValues:)` does at `:108`.
- `FASTAIndex.swift:72-99`. Parse the bytes of the file instead of splitting `Character`s. Lines end at byte 10 and empty lines are skipped, as `split` omits them. Fields split at byte 9, at least five are needed and more are allowed. Integers follow `Int(_:)` (an optional `+` or `-`, then decimal digits). Names are UTF-8 and fail as `String(contentsOf:encoding: .utf8)` fails. The two error texts keep their line numbers, which count non-empty lines only (`:79`, `:86`).
- One edge to settle with BIO before landing. Today a CRLF `.fai` is read as one line, because `"\r\n"` is a single `Character`. A five-field CRLF file therefore throws, but a six-field one yields only its first record. The byte parser must match both results or list the difference in the lane report.
- Estimate, not measured: about 43 MB of entries (905,628 × 48 bytes) plus a position map near the 64 MB measured for the name index, so about 110 MB live instead of 219 MB, and a parse far below the 1.85 s of CPU of the two splits.
- Test `FASTAIndexTests.testByteParserMatchesStringParser`. The old `init(url:)` is the oracle, over fixtures with extra fields, blank lines, signed numbers, CRLF, invalid UTF-8, duplicate names and malformed lines. Assert the same entries in the same order, or the same error text.

### 4.6 Files shared with P2 and P3

None.
- P2 edits `MainSplitViewController+ContentDisplay.swift`, `ViewerDisplayRoute.swift`, `ViewerViewController+BundleDisplay.swift`, `ReferenceBundleViewportController.swift`, `ReferenceBundleViewportInput.swift`, `MainSplitViewController+ClassifierDisplay.swift`, `InspectorViewController+PublicAPI.swift`, `AppDelegate.swift` and `AlignmentMetadataDatabase.swift` (`SCR/inv/SWIFT-perf.md:276`, `SCR/briefs/lane-P2.md:19`).
- P3 edits `ChromosomeNavigatorView.swift`, `AnnotationSearchIndex.swift`, `ReferenceBundleRecordTable.swift`, `BatchTableView.swift` and `BundleDataProvider.swift`, and any other file that sorts every chromosome with the per-comparison key builder (`SCR/briefs/lane-P3.md:13-15`). If that search reaches one of the four item-4 files of section 4.1, the second lane to land rebases over a one-line change.
- P5 (F4) edits `ReferenceBundleViewportController.swift:35-38` and `:1906-1911` (`SCR/rulings/BIO-perf.md:66-67`), which P6 does not touch.

Shared logic, not a shared file.
- P3 gives `BundleDataProvider.chromosomeInfo(named:)` its own name-to-index dictionary (`lane-P3.md:15`). That method is a copy of `chromosome(named:)` (`BundleDataProvider.swift:96-105` against `ReferenceBundle.swift:210-219`). Follow-up 2 of section 4.7 makes it one index.
- Copy Sequences lives in P2's `ReferenceBundleViewportController.swift:626-649`. P6 removes its parse per row inside `ReferenceBundle` without touching that file. A new provider per action (`:629`) still means one parse per action.

### 4.7 Follow-ups after landing

1. After P2 and P6 have both landed: build both indexes off the main actor at open. Under F2 as written, `loadBundleDisplayContext` only skips its manifest decode (`SCR/inv/SWIFT-perf.md:269`), so it still builds the bundle on the main actor (`ViewerViewController+BundleDisplay.swift:134`). The fix makes `ReferenceBundle(url:manifest:)` in P2's detached load instead, calls `try? bundle.prepareSequenceAccess()` there, and hands that bundle to `loadBundleDisplayContext` in place of `:134`. Test `ReferenceOpenManifestLoadTests.testOpenBuildsSequenceIndexesOffMain`: after an open, `nameIndexBuildCount == 1` and `readerBuildCount == 1`, with `dispatchPrecondition(condition: .notOnQueue(.main))` in a build seam. Agent: lge-worker, sonnet, effort max, reviewed by a fresh lge-expert for SWIFT, opus, effort max.
2. After P3 and P6 have both landed: `BundleDataProvider.swift:96-105` becomes `(try? ensureBundle())?.chromosome(named: name)`, and P3's dictionary goes. `ensureBundle()` never throws in practice (`:212-221`). P3's test of present and missing names must still pass. The landing agent folds it in (lge-worker, sonnet, effort max).

## 5. Open questions

| Id | Field | Question |
|---|---|---|
| Q-S8 | SWIFT | `annotationQueryChromosomes` calls `mapVCFChromosomes` with every chromosome of the annotation database on each annotation query (`ReferenceBundle.swift:578-584`). Its first step alone scans every bundle record for each database name (`ChromosomeNameMapping.swift:26-30`), so each query costs database names times bundle records. SILVA has no annotation tracks, so it is off the owner's path. Fix it with F5b's indexed names in Phase 3, or sooner if a large annotated reference shows it? |
| Q-S9 | SWIFT, UX | The four `ClampedSequenceProvider` routes (rows 4a to 4d) read bgzip blocks synchronously on the main actor, which SWIFT 2 forbids. P6 removes their repeated parse but not the main-actor read. Should a later phase move them behind an async read with a progress state? |
| Q-S10 | BIO | After F5b, may a fetch take `offset`, `line_bases` and `line_width` from the sidecar row (`BundleTracks.swift:256-263`) instead of the `.fai`, so that no in-memory `.fai` index is held? That needs a build-time check that the sidecar matches the `.fai`. |
