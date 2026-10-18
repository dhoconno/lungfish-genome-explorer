# SWIFT inventory: large-reference load stalls (pre-2.12)

Model and effort: opus, effort max (agent type lge-expert, field SWIFT, letter S).

Code: worktree `laptop-golden-runner-setup-e5434b` at `c59241aceb2cbedde51482212ccc67928e4e9a45`, read only. Every `path:line` below is at that commit. Data: R and M as the brief names them, read only. Measured on 2026-10-17 between 18:56 and 19:10 on this laptop (M4 Pro, 14 cores, 48 GB). The measurement script is `inv/measure_open_costs.swift`.

## 1. Verdict

Three causes, ranked by cost.

1. **Inspector provenance lookups that never stop (the whole-machine stall).** Every sidebar selection starts a detached lineage walk, and each open starts one or two more for the same item. No walk is ever cancelled. For both surfaces the walk falls back to a project-wide sidecar index, which reads and re-roots every provenance sidecar in the project. In project 32616 that includes 301 EsViritu sidecars of about 17.4 MB each (5,242 MB). One sidecar costs at least 1.8 s, so one walk costs at least 9 CPU-minutes. At 18:56 the live Lungfish Preview process had all 14 cooperative threads busy, a 25.8 GB footprint (25 GB compressed) and 184 CPU-minutes after 22 minutes of uptime. Seven new 1 GiB swap files appeared between 18:42 and 18:50. The manager's 19:10 sample shows the same Lungfish call chain on all 14 threads, decoding `PortablePath.JSONNode` trees (section 5.1). The code that starts these decodes is `updateProvenanceTarget`. Each call launches a new `Task.detached` walk (`InspectorViewController+Notifications.swift:466`, `ProvenanceInspectorViewModel.swift:494-497`), and each walk builds its own sidecar index (`ProvenanceLineageResolver.swift:48-52`, `:122-125`). The concurrent full decodes are of those same sidecars, not of `manifest.json` or `mapping-result.json`.
2. **The 706 MB manifest decoded on the main actor three to five times per open.** Each decode takes 4.7 s and peaks at 2.3 GB. The reference open decodes it 3 times on main and the mapping open 5 times, plus the 252 MB result (2.6 s, 1.3 GB peak). Menu validation decodes them again.
3. **Per-sequence work over 905,628 records on the main actor.** `naturalChromosomeSort` takes 12.2 s per call and runs 2 to 3 times on the reference open and once on the mapping open. The alias maps take 5.5 s and keep 1,264 MB. The sequence table sort takes at least 3.3 s. The stats database is read in full up to three times, and `samtools coverage` emits a row for every reference.

Main-thread time per open, summed from the measured steps: about 47 to 60 s for the reference bundle and about 45 to 50 s for the mapping. That matches the owner's "a minute". The background lookups (cause 1) then keep the machine saturated for many minutes after first paint.

## 2. Measurements

### 2.1 The live process (read only: `top`, `ps`, `sample`, `vm_stat`, `ls` of `/System/Volumes/VM`)

| Fact | Value |
|---|---|
| Process | pid 98257, `/Applications/Lungfish Preview.app`, 2026.10.20 (9488), launched 18:33:50 |
| Footprint at 18:56 | 25.8 GB (peak 25.8 GB), 25 GB of it compressed, RSS 1.2 GB |
| CPU time | 3:04:09 after 22:24 elapsed (about 8.2 cores on average) |
| Threads in a 3 s sample | Main thread idle in the run loop. 14 threads of `com.apple.root.user-initiated-qos.cooperative` busy in all 2,023 samples |
| Hot frames | `__CFDataSearchBoyerMoore` 1,953 samples inside one `Data.range(of:)`, `Substring.index(_:offsetBy:)` 2,055 under `StringProtocol.contains`, `JSONDecoderImpl.unwrapString`, `Dictionary<>.init(from:)`, `stat`, `fileExists(atPath:)`, `destroy for DecodingError` |
| One thread's chain | a function reads a file with `Data(contentsOf:)`, scans it with `Data.range(of:)`, then calls `JSONDecoder.decode`. This is the shape of `ProvenanceEnvelopeReader.resolvedSidecar` (`Sources/LungfishWorkflow/Provenance/ProvenanceEnvelopeReader.swift:88-98`) into `PortablePath.resolveJSON` (`Sources/LungfishCore/Storage/PortablePath.swift:377-394`) |
| Swap | 18,648 MB used of 19,456 MB. `swapfile12` to `swapfile18` created 18:42:35 to 18:50:36, after the owner opened M at 18:37:49 |
| Memory | 167 MB unused, compressor 25 GB, load average 127 over 15 minutes |
| Volume | `/dev/disk4s1` on `/Volumes/corella_geneious` (hfs, journaled). Swap is on the internal APFS VM volume (`/dev/disk3s6`), never on the USB volume |

The binary is stripped, so the attribution of the 14 threads to the lineage walk is an inference from the frame chain and from the 18 MB sidecars. A symbol check would confirm it (section 9, C1).

### 2.2 Script timings (`swiftc -O`, one run each, `/usr/bin/time -l`)

The machine was under the memory pressure above, and the manifest read came from the page cache. A cold read from the USB volume adds about 2 s per 706 MB.

| Step | Code mirrored | Time | Memory |
|---|---|---|---|
| Read `manifest.json` (706,679,137 bytes) | `BundleManifest.swift:582` | 0.76 s | 676 MB `Data` |
| Decode it (905,628 chromosomes plus 905,628 summaries) | `BundleManifest.swift:584-587` | 3.95 s | peak footprint 2,318 MB, about 1.4 GB held while decoded |
| Decode only `format_version`, `name`, `identifier` from the same bytes | none (fix probe) | 0.90 s | JSONDecoder still parses the whole document |
| Decode `mapping-result.json` (252 MB, 905,628 contigs, 94 with reads) | `MappingResult.swift:241-242` | 0.29 s read plus 2.32 s | peak 1,327 MB |
| Parse the `.fai` into 905,628 (name, length, offset) | fix probe | 1.1 s with `String.split` | under 200 MB |
| `naturalChromosomeSort` of 905,628 | `ChromosomeNavigatorView.swift:25-53` | 12.17 s | small |
| The same order with each key built once | fix probe | 0.49 s | small |
| Sort by name with `localizedStandardCompare` | `ReferenceBundleRecordTable.swift:363-364` | 3.26 s (the table adds a metadata hook per comparison) | small |
| Plain `String <` sort | fix probe | 0.20 s | small |
| `rebuildBundleAliasMaps` | `AnnotationSearchIndex.swift:1696-1716` | 5.51 s | +1,264 MB, 3,408,914 and 798,829 keys |
| One 17.4 MB EsViritu sidecar through a `resolveJSON` approximation | `PortablePath.swift:377-423` | 1.79 s (tree decode 0.82, `contains` on 236,690 strings 0.65, re-encode 0.17) | peak 168 MB |

At 100,000 names the natural sort took 1.21 s against 0.043 s with keys built once, so the cost grows as n log n times an allocation-heavy key.

## 3. The open path of each surface (question 1)

### 3.1 Reference bundle R, sidebar click

All rows run on the main actor unless the thread column says otherwise. "Decode" means a full `BundleManifest.load` of the 706 MB file (4.7 s, 2.3 GB peak).

| # | Step | Code | Thread | Cost |
|---|---|---|---|---|
| 1 | The Inspector receives the selection and starts a provenance lookup | `InspectorViewController+Notifications.swift:25-45`, `:478-486`, `:466` | detached, user-initiated | lineage walk, section 5 |
| 2 | `displayContent` routes `.referenceBundle` | `MainSplitViewController+ContentDisplay.swift:80-83` | main | |
| 3 | Shows "Loading…", then hops with `DispatchQueue.main.async` and decodes | `ContentDisplay.swift:799-817` | main | decode 1 |
| 4 | `viewerController.display(route)` then `configure(input:)` | `ContentDisplay.swift:818-822`, `ReferenceBundleViewportController.swift:521-573` | main | |
| 5 | Browser summary taken from the manifest, 905,628 table rows built | `ReferenceBundleViewportController.swift:670-680`, `:724` | main | |
| 6 | The table sorts all rows by sequence with `localizedStandardCompare` | `ReferenceBundleRecordTable.swift:255-256`, `BatchTableView.swift:536-540`, `:760-768` | main | at least 3.3 s |
| 7 | Row 0 selected, so the embedded viewer opens the bundle and decodes it again | `ReferenceBundleViewportController.swift:803-815`, `:845-859`, `ViewerViewController+BundleDisplay.swift:113-145` | main | decode 2 |
| 8 | Natural sort of all chromosomes to choose the first | `ViewerViewController+BundleDisplay.swift:260-278` | main | 12.2 s |
| 9 | Annotation search index, whose alias maps cover every chromosome | `ReferenceBundleViewportController.swift:1094-1111`, `AnnotationSearchIndex.swift:407-416` | main (`AnnotationSearchIndex` is `@MainActor`, `:18-19`) | 5.5 s, +1,264 MB |
| 10 | `onEmbeddedReferenceBundleLoaded`, if a callback is already set, updates the Inspector: natural sort again, plus a provenance lookup through `updateBundleMetadata` | `InspectorViewController+MetadataImport.swift:960-971`, `InspectorViewController+PublicAPI.swift:40-54`, `:74-92` | main, plus detached | 12.2 s and lookup 2 |
| 11 | `installBAMMetadataPresentation` decodes the manifest to list alignment tracks (R has none) | `MainSplitViewController+ClassifierDisplay.swift:47-56` | main | decode 3 |
| 12 | `wireDirectReferenceViewportInspectorUpdates` calls the callback again | `ContentDisplay.swift:837-854`, `ReferenceBundleViewportController.swift:1001-1005` | main, plus detached | 12.2 s and lookup 3 |

Rows 10 and 12 both fire when the viewport controller is reused. A first-time controller has no callback at row 10, so the sort and lookup run once there. Total on main: 3 decodes (14.1 s), 2 or 3 natural sorts (24.4 to 36.6 s), the table sort (3.3 s or more) and the alias maps (5.5 s), about 47 to 60 s. The page cache usually holds the file after the first read, so later decodes are CPU-bound.

### 3.2 Mapping analysis M, sidebar click

"Decode" here means the nested viewer bundle's 706 MB manifest.

| # | Step | Code | Thread | Cost |
|---|---|---|---|---|
| 1 | Inspector selection lookup | `InspectorViewController+Notifications.swift:45` | detached | lookup 1 |
| 2 | `MappingResult.load` decodes all 905,628 contigs | `ContentDisplay.swift:914`, `MappingResult.swift:235-272` | main | 2.6 s, 1.3 GB peak |
| 3 | The route decodes the viewer manifest for display labels | `ViewerDisplayRoute.swift:42-60` | main | decode 1 |
| 4 | "Already displayed" check with synthesized `==` over the input (manifest arrays and contigs) | `ContentDisplay.swift:927-929`, `ReferenceBundleViewportInput.swift:5-23` | main | full compare on a re-select of the same result |
| 5 | Inspector provenance target | `ContentDisplay.swift:937-941` | detached | lookup 2 |
| 6 | `updateMappingProvenanceSources` decodes the viewer manifest to list variant tracks | `InspectorViewController+PublicAPI.swift:60-72` | main | decode 2 |
| 7 | 905,628-entry description dictionary for the contig table | `ReferenceBundleViewportController.swift:699-713` | main | under 1 s (estimate) |
| 8 | Contig table gets all 905,628 rows and sorts by reads | `ReferenceBundleViewportController.swift:1297-1303`, `:1485-1493`, `MappingContigTableView.swift:98-100` | main | 1 to 2 s (estimate) |
| 9 | Row 0 selected, so the embedded viewer opens the bundle: decode, natural sort, alias maps | `ReferenceBundleViewportController.swift:1114-1158`, `ViewerViewController+BundleDisplay.swift:116`, `:260`, `ReferenceBundleViewportController.swift:857` | main | decode 3, 12.2 s, 5.5 s |
| 10 | Stats database opened three times: read groups, flag stats, all 905,628 `chromosome_stats` rows | `ReferenceBundleViewportController.swift:592-616`, `:1500-1596`, `AlignmentMetadataDatabase.swift:320-335` | main | full-table read |
| 11 | `refreshMappingRowsForVisibleAlignmentTrack` decodes the manifest again and repeats row 10 | `ReferenceBundleViewportController.swift:1305-1373` | main | decode 4, second full-table read |
| 12 | `samtools coverage` and `samtools view`, building 905,628 summaries | `ReferenceBundleViewportController.swift:33-61`, `:1375-1417`, `MappingSummaryBuilder.swift:49-104`, `:128` | `NativeToolRunner` actor (`NativeToolRunner.swift:108`) and the global executor | coverage prints one row for each `@SQ` line |
| 13 | `installMappingBAMMetadataPresentation` decodes the manifest | `MainSplitViewController+ClassifierDisplay.swift:36-56` | main, after `display(route)` returns (`ContentDisplay.swift:953-954`) | decode 5 |
| 14 | Mapping Inspector section | `ContentDisplay.swift:856-869`, `InspectorViewController+MetadataImport.swift:865-942` | main | no natural sort |

Total on main: the result (2.6 s), 5 manifest decodes (23.5 s), one natural sort (12.2 s), the alias maps (5.5 s) and the table, dictionary and stats work (3 to 5 s), about 45 to 50 s. The cooperative pool is saturated by the lookups, so row 12 and every other async step of the viewer then waits behind them. The viewer looks stuck even after the main thread is free.

### 3.3 Large-file reads per open

| File | Reference open | Mapping open | Readers |
|---|---|---|---|
| `manifest.json`, 706 MB | 3 on main | 5 on main | rows above |
| `mapping-result.json`, 252 MB | 0 | 1 on main | `ContentDisplay.swift:914` |
| `.fai`, 38 MB | not read at open (the chromosome list comes from the manifest) | same | lazy reader on first sequence fetch, not verified (section 9, C2) |
| `stats.db`, 68 MB | 0 | 3 opens on main, 2 full `chromosome_stats` reads (a third on the error fallback, `:1395`, `:1425`) | `AlignmentMetadataDatabase.swift:58-62` opens read-only |
| BAM and BAI | 0 | `samtools coverage` and `samtools view` read the whole 16 MB BAM, header included | `MappingSummaryBuilder.swift:66-71`, `:196-202` |
| Provenance sidecars, all of the project's | 3 lookups, each may build the full index | 2 lookups | section 5 |

The sidebar scanner reads no reference manifest. Its `manifest.json` reads are for NAO-MGS and NVD folders only (`SidebarProjectScanner.swift:807-828`, `:1015-1026`). `mapping-result.json` appears there only in a list of names to hide (`:467-492`).

### 3.4 Reads outside the open that hit the same files

- **Menu validation.** `validateMenuItem` resolves the current bundle for Import BAM/CRAM (`AppDelegate.swift:2477-2479`) and loads a whole `ReferenceBundle` for Call Variants (`:2487-2493`, `:1598-1601`, `:1620-1623`). `currentReferenceBundleURL` builds `referenceBundleCandidates` before it looks at the viewer's own bundle URL (`:1569-1582`). For a selected mapping folder that runs `MappingResult.load` (`:1606-1618`). Opening the menu that holds these items costs 2.6 s with M selected, and 4.7 s more for Call Variants. `AppDelegate+ToolsMenu.swift:103` also calls `currentReferenceBundle(in:)`, so whatever runs there pays the same decode. Its caller was not traced.
- **The universal search index.** Opening a project schedules a full rebuild (`SidebarViewController.swift:1005`), and so does every full sidebar reload (`:1622`). The rebuild decodes every `.lungfishref` manifest, 2 x 706 MB here, only to list `manifest.variants` (`ProjectUniversalSearchIndex.swift:396`, `+Indexers.swift:134-174`). It runs on the `UniversalProjectSearchService` actor (`UniversalProjectSearchService.swift:26`), off main.
- **View-state saves re-index the bundle.** A `.viewstate.json` write is a JSON file inside a `.lungfishref`, so the watcher calls it a sidecar change (`FileSystemWatcher.swift:470-476`). The sidecar branch sends it to the search index (`SidebarViewController.swift:1036-1039`, `UniversalProjectSearchService.swift:128-139`), which re-indexes the enclosing bundle (`ProjectUniversalSearchIndex.swift:537-560`, `:516`) with a full manifest decode. A save follows each pan or zoom pause, 0.5 s later (`ViewerViewController+BundleDisplay.swift:736-743`). So browsing the mapping viewer starts a 706 MB decode after every pause. The selected-item refresh does skip `.viewstate.json` (`SidebarViewController.swift:1859-1861`).

## 4. Per-sequence structures and quadratic steps (question 2)

| Structure | Built by | Size | Cost |
|---|---|---|---|
| `GenomeInfo.chromosomes` | every decode (`BundleTracks.swift:195-312`) | 905,628 `ChromosomeInfo` per decode | inside the 3.95 s decode |
| `BundleBrowserSummary.sequences` | every decode (`BundleBrowserSummary.swift:7-69`) | 905,628, the same facts again | inside the decode |
| Sequence table rows | `ReferenceBundleViewportController.swift:724`, `:1261-1295` | 905,628 `ReferenceBundleRecordRow` (times the samples when tracks resolve samples) | sorted on every `configure` and every filter change (`BatchTableView.swift:742-777`) |
| Contig table rows | `ReferenceBundleViewportController.swift:1301` | 905,628 then 94 | numeric sort |
| Description dictionary | `ReferenceBundleViewportController.swift:699-713` | 905,628 entries for 94 visible rows | O(n) |
| Sorted chromosome copy | `ViewerViewController+BundleDisplay.swift:260`, `InspectorViewController+PublicAPI.swift:89-91` | 905,628 copy each | 12.2 s each, used only to take the first element |
| Alias maps | `AnnotationSearchIndex.swift:1696-1716` | 3,408,914 plus 798,829 keys, each holding a `Set<String>` | 5.5 s, 1,264 MB, built though R has no annotation or variant tracks |
| Chromosome navigator | `ViewerViewController+BundleDisplay.swift:222-226`, `:452-498` | all chromosomes | not built here, because `.sequence` mode passes `installChromosomeNavigator: false` (`:60-65`) |
| Stats rows | `AlignmentMetadataDatabase.swift:320-335` | 905,628 `ChromosomeStats` to keep 94 | full table read, though `idx_chromstats_mapped` exists (`:139-140`) |
| Coverage summaries | `MappingSummaryBuilder.swift:127-144` | 905,628 rows, 94 kept by `applyVisibleAlignmentRows` (`ReferenceBundleViewportController.swift:1455-1456`) | off main, then filtered on main |

Quadratic or near-quadratic steps:

- `naturalChromosomeSort` builds the key inside the comparator (`ChromosomeNavigatorView.swift:51-53`). Each key allocates a `CharacterSet` and an uppercased `String` (`:25-47`), so about 18 million comparisons do 36 million allocating key builds. It is n log n with a heavy constant, 25 times the keyed sort.
- `BundleDataProvider.chromosomeInfo(named:)` scans the array linearly and checks aliases (`BundleDataProvider.swift:96-105`). It runs a few times per selection, so it is O(n) per call, not quadratic today. Any per-row caller would make it quadratic.
- `ReferenceBundleViewportInput` synthesizes `Equatable` over two 905,628 arrays and the contig array (`ReferenceBundleViewportInput.swift:5-23`). `configure(input:)` compares twice (`ReferenceBundleViewportController.swift:524`, `:549`), and the mapping route once more (`ContentDisplay.swift:927-929`). These are linear, but they run on main with each refresh.
- `selectSequence(named:)` and `selectContig(named:)` use `firstIndex(where:)` over displayed rows (`ReferenceBundleViewportController.swift:1227-1247`), linear per call.

## 5. Why the whole machine stalled (question 3)

**The provenance lineage walk.** `updateProvenanceTarget` always calls `load(item:)` (`InspectorViewController+Notifications.swift:450-474`). `load` starts `Task.detached(priority: .userInitiated)` for `performLookup` (`ProvenanceInspectorViewModel.swift:485-507`). A newer selection only discards the older result through `loadGeneration` (`:499`). The older walk keeps running. Each sidebar click starts one walk (`InspectorViewController+Notifications.swift:45`). The mapping open adds one (`ContentDisplay.swift:937`), and the reference open adds one or two through `updateBundleMetadata` (`InspectorViewController+PublicAPI.swift:43`).

`performLookup` runs `ProvenanceLineageResolver().resolve` (`ProvenanceInspectorViewModel.swift:525-535`). When a dependency path does not resolve, the walker builds a `ProjectSidecarIndex` for the project (`ProvenanceLineageResolver.swift:121-138`). Both surfaces hit that branch.

- R's record names its input as `<external>/SILVA_144_SSURef_NR99_tax_silva_trunc.fasta.gz`, with a checksum (`R/.lungfish-provenance.json` line 27). It is not an absolute path, so the walk goes to the checksum branch.
- M's record names `@/.tmp/mapping-reference-stage-41B36A8C-9FC1-49ED-82AD-F8D0F393B10B/reference.fa`, with a checksum and a size of 1,409,502,956 bytes (`M/.lungfish-provenance.json` lines 58-62). That staging file no longer exists, so the walk takes the same branch. M's walk also visits R (`ProvenanceLineageResolver.swift:93-97`).

The index enumerates up to 4,000 files (`:35`, `:346-371`) and reads every sidecar it finds (`:380-406`). Each read goes through `PortablePath.resolveJSON`. That does whole-file `Data.range` scans (`PortablePath.swift:382-383`, `:400-402`, `:530-534`) and a dynamic `JSONNode` decode (`:414`). It runs `contains(".lungfish/")` on every string (`:416-419`, `:430`) and a `fileExists` for each foreign path (`:447`), then re-encodes (`:422`). After that comes the typed decode with its fallbacks (`ProvenanceEnvelopeReader.swift:103-109`). The index keeps every decoded envelope in `byChecksum` until the walk ends (`:344`, `:396`).

Project 32616 holds 301 sidecars over 1 MB, all in `Analyses/esviritu-batch-2026-09-17T18-49-02`, 5,242 MB in total. In one of them the `steps` array alone is 17.8 MB (bytes 425,182 to 18,261,917 of `SRR35517702.third.filt.sorted.bam.lungfish-provenance.json`). The measured approximation costs 1.8 s per file, so one walk takes at least 9 CPU-minutes and reads about 5.3 GB from the USB volume. The cooperative pool is 14 wide, so 14 walks fill every core. They also starve the viewer's own async work, such as row 12 of section 3.2. The live sample shows exactly this pool, these frames and a 25.8 GB footprint.

**Weighing the candidate mechanisms.**

| Mechanism | Finding |
|---|---|
| Memory pressure from decoding | Main-thread decodes peak at 2.3 GB each (1.3 GB for the result), and 1.4 GB stays held per decoded manifest. The open keeps two or three decoded copies alive: the input's, the embedded viewer's (`ViewerViewController+BundleDisplay.swift:27-34`) and `currentInput.viewerBundleManifest`. Add the 1,264 MB alias maps and the walks' retained envelopes. The process reached 25.8 GB, 25 GB of it compressed. |
| Swap | 7 GB of new swap files between 18:42 and 18:50. Swap lives on the internal SSD, not on the USB volume. The machine stalls because the compressor and swap I/O take every app's pages. |
| USB volume | Each walk reads about 5.3 GB of sidecars, and each decode reads 706 MB when the page cache has dropped the file. HFS+ over USB serves Finder and the app from one queue, so the volume looks locked. |
| File coordination or presenters | None. No source file uses `NSFileCoordinator` or `NSFilePresenter`. |
| FSEvents | Yes, in a loop. A view-state write re-indexes the bundle with a 706 MB decode (section 3.4). A full sidebar reload, such as the one after a mapping run, schedules a full rebuild with every manifest decoded. |
| Writes on open | Small only, listed below. |

**Every write that opening either surface makes.** No write rewrites a large file.

1. `.viewstate.json`, 1,668 bytes, into the displayed bundle (M's nested bundle, written at 18:37:49). It is written only when a save is pending, after a user change or an Inspector-applied setting (`ViewerViewController+BundleDisplay.swift:736-756`, `ViewerViewController.swift:943`, `:978`, `:1015`, `:1031`). It is an atomic `Data.write` (`BundleViewState.swift:282-288`), and its FSEvent costs a 706 MB decode in the search index.
2. The search index database under the project, updated after FSEvents (`UniversalProjectSearchService.swift:113-125`). The rows are small.
3. The browser mirror store, only for a manifest without `browser_summary` (`BundleBrowserLoader.swift:52-60`). Not taken for R or M, but section 8 F5a must route around it.
4. A read-group list in the system temporary folder, only when read groups are set (`MappingSummaryBuilder.swift:372-381`).

There are no writes from the Inspector (`ProvenanceInspectorViewModel.swift:509-511` says the audit only reads), and the stats database opens read-only (`AlignmentMetadataDatabase.swift:58-62`).

### 5.1 What starts the many concurrent full decodes (the manager's 19:10 sample)

The code confirms cause 1. The concurrent decodes are not `manifest.json` or `mapping-result.json`. They are the project's provenance sidecars, and every Inspector lookup re-reads the same 301 EsViritu sidecars of about 17.4 MB each.

- **The same chain on every thread.** In `inv/preview-sample-1910.txt` all 14 cooperative threads enter Lungfish code through `0x3495320` and reach `0x3451ff8` and then `0x3453330` (lines 102-107, 3454-3459, 5870-5875 and the other 11 thread headers). That is the chain the 18:56 sample showed. There, `0x3453330` reads a file with `Data(contentsOf:)`, scans it with `Data.range(of:)` through `0x1369ac8`, and then calls `JSONDecoder.decode`. The 19:10 sample shows that shape again at lines 14848-14866.
- **The decoded type is the dynamic tree, not a manifest.** `Dictionary<>.init(from:)` comes from `PortablePath.JSONNode`, which decodes every object as `[String: JSONNode]` (`PortablePath.swift:952-976`). `unwrapFloatingPoint` comes from its number branch, which tries `Int` and then `Double` with `try?` (`:967-969`). `BundleManifest` has no `Double` field and decodes no dictionary, so these frames cannot be manifest decodes. `JSONNode` runs only inside `PortablePath.resolveJSON` (`:365`, `:414`), which the provenance readers call (`ProvenanceEnvelopeReader.swift:62`, `:81`, `:90`, `MappingProvenance.swift:333`).
- **Who starts them.** Each call of `updateProvenanceTarget` starts a new `Task.detached(priority: .userInitiated)` walk (`InspectorViewController+Notifications.swift:466`, `ProvenanceInspectorViewModel.swift:494-497`). There is no check for the same item and no cancellation. The generation check only drops the old result (`:499`). Calls per open are as follows:
  - the selection, on every click (`InspectorViewController+Notifications.swift:45`)
  - the mapping display (`ContentDisplay.swift:937`)
  - `updateBundleMetadata`, once or twice per reference open (`InspectorViewController+PublicAPI.swift:43`)
  - a content-mode change (`InspectorViewController+Notifications.swift:353-370`)
  - a sidebar selection refresh, which re-runs `displayContent` (`MainSplitViewController+SidebarSelection.swift:273-287`)

  So 2 to 4 walks start per open, and 4 or 5 clicks fill the 14-wide pool.
- **A cache miss on every walk.** Each `resolve` makes a new `Walker` (`ProvenanceLineageResolver.swift:48-52`) whose `ProjectSidecarIndex` is built on first need (`:65`, `:122-125`, `:175-177`). Nothing shares it across walks, and the doc comment says "Built once per resolution" (`:335-337`). R's `<external>` input and M's deleted `.tmp` reference both send the walk there (section 5).
- **The same large JSON, decoded concurrently.** Every walk reads and decodes the same sidecars in the same sorted order (`:372-381`). Up to 14 copies of one 17.4 MB sidecar are therefore decoded at once, each as a tree, then re-encoded and decoded as a typed record. Each walk also keeps all decoded envelopes until it ends (`:344`, `:396`), which is how the footprint reached a 29.8 GB peak.

The large files are decoded serially, not concurrently: 3 to 5 times per open on main, plus once per search re-index on the single `UniversalProjectSearchService` actor (section 3.4). A walk decodes a reference manifest only for a bundle without its own record (`ProvenanceLineageResolver.swift:168-188`, `:261-262`). R has a record that names its manifest, and the copy inside M is never a dependency, so the walks did not decode either manifest here.

The measurements in section 2.2 ran one at a time, and the 706 MB manifest was decoded once in total.

## 6. What the mapping viewer needs (question 4)

It needs none of the 905,628 records to draw 96 reads on 94 contigs. It loads them all because of four habits of the code.

1. The route loads the whole viewer manifest for a bundle name and the alignment track list (`ViewerDisplayRoute.swift:47-54`, `ReferenceBundleViewportInput.swift:17-23`).
2. The embedded viewer opens the nested bundle through the generic `displayBundle`, which decodes the manifest and works from `genome.chromosomes` (`ViewerViewController+BundleDisplay.swift:113-145`). `BundleDataProvider` answers `chromosomeInfo(named:)` from that array (`BundleDataProvider.swift:68-105`).
3. The contig table and its labels are built over every contig (`ReferenceBundleViewportController.swift:699-713`, `:1301`).
4. The stats rows and the coverage summary enumerate every `@SQ` line (`AlignmentMetadataDatabase.swift:320-335`, `MappingSummaryBuilder.swift:66-71`, `:128`).

What it truly needs:

| Need | Source today | Cost if read narrowly |
|---|---|---|
| Totals (96 mapped of 100) | `mapping-result.json` scalars or `flag_stats` | a few rows |
| The contigs with reads (94) | `chromosome_stats WHERE mapped_reads > 0`, served by `idx_chromstats_mapped` (`AlignmentMetadataDatabase.swift:139-140`) | 94 rows |
| Name, length and description of those contigs | the manifest today. The `.fai` has name, length and offset. Descriptions have no other home | 94 lookups in an index |
| Reads for the shown region | BAM plus BAI through the existing fetch path, region by region | the region only |
| Bases for the shown region | `.fa.gz` with `.fai` and `.gzi` | one block |
| Bundle name and alignment track declarations | manifest top-level keys | small, if they live outside the per-sequence arrays |

The BAM header itself holds 905,628 `@SQ` lines, which explains most of its 16 MB for 100 reads. Tools that parse the header pay for that once per call. A "go to any contig" search can use the `.fai` or a sidecar index instead of a table of every contig.

## 7. Who writes the 706 MB manifest and the 252 MB result (question 5)

**The reference import.** `BundleManifest.save` writes pretty-printed, sorted-key JSON through `DurableReplace` (`BundleManifest.swift:813-822`). It calls `withSynthesizedBrowserSummaryIfNeeded` first (`:820`), which rebuilds `browser_summary` from `genome.chromosomes` whenever the stored summary is nil (`:778-811`). The summary copies name, description, length, aliases and two flags, so the file holds the same facts twice: 391.9 MB in `genome` and 314.7 MB in `browser_summary` (byte offsets 314,734,419 to 706,678,519 and 53 to 314,734,348). Every mutator clears the summary (`:637-771`), so every later save re-synthesizes and rewrites both arrays. The import builder was not traced to its save line (section 9, C3).

**The mapping run** writes five large things.

1. `MappingViewerBundlePreparer.prepareBaseBundle` decodes the source manifest (`MappingViewerBundlePreparer.swift:17`).
2. It copies `genome/` with `copyfile(COPYFILE_RECURSIVE | COPYFILE_CLONE)` (`:122-126`). The clone works on APFS only. On this HFS+ volume it became a 361 MB byte copy, and the nested files have link count 1.
3. It writes a new manifest with `browserSummary: nil` (`:35-52`), so `save` synthesizes the summary again. That is 706 MB of encode and write.
4. The alignment attach loads the viewer manifest again (`MappingViewerBundlePublicationService.swift:1479`, `BAMImportService.swift:293`) and saves it. The nested manifest's `modified_date` of 02:31:24Z and its 21:31:35 mtime show that second save.
5. `mapping-result.json` holds all 905,628 contigs. `summarizeMappedContigs` calls `MappingSummaryBuilder.build` without `includeUnmappedReferenceRows` (`ManagedMappingPipeline.swift:221-234`), whose default is `true` (`MappingSummaryBuilder.swift:55`, `:128`). `result.save` writes it with a plain atomic `Data.write`, not `DurableReplace` (`ManagedMappingPipeline.swift:162`, `MappingResult.swift:229-232`). Publication writes it again into staging (`MappingViewerBundlePublicationService.swift:712`).

The stats database holds a `chromosome_stats` row for every reference (68 MB).

**Why the mapping copies the whole manifest.** The viewer bundle is a standalone `.lungfishref`, so the generic viewer can open it and the BAM track can attach to it. It already records `origin_bundle_path` back to R (`MappingViewerBundlePreparer.swift:40`, `:146-162`), so the copy is not needed for lineage. The cost of one mapping run onto R is two 706 MB encodes and writes, a 361 MB genome copy, a 252 MB result written twice and about 4.7 s of decode per manifest load inside the run.

## 8. Fixes, ranked by stall removed for the least change

| Rank | Fix | Removes | Size | Ruling needed |
|---|---|---|---|---|
| 1 | F1 cancel, de-duplicate and share the provenance walk | the whole-machine stall (14 concurrent walks become 1) | small to medium | none for F1a and F1b. Q-S1 and Q-S2 for later work |
| 2 | F3a build each natural-sort key once | 12 to 37 s of main time per reference open, 12 s per mapping open | a few lines | none |
| 3 | F2 one manifest decode per open, off main, shared | 14 to 24 s of main time per open, 2 to 4 GB of peaks, menu stalls | medium | none |
| 4 | F3b to F3e the rest of the per-sequence work | about 10 s and 1,264 MB per open | small | none |
| 5 | F6 search index ignores app-state files | a 706 MB decode after every pan or zoom pause | small | none |
| 6 | F4 results list only contigs with reads | 2.6 s and 1.3 GB per mapping open, a 905,628-row table | small | Q-S3 (BIO) |
| 7 | F5 slim manifests and a thin viewer bundle | half or more of every manifest load, write and copy | large | Q-S4, Q-S5, Q-S6 (ARCH) |

### F1. Provenance walk: cancel, de-duplicate, share (cause 1)

**Design.**
- **F1a.** `ProvenanceInspectorViewModel.load(item:)` keeps the detached task's handle and cancels it before it starts another. A detached task does not inherit the outer task's cancellation, so the handle itself must be cancelled. `load` returns at once when the item equals `currentItem` and a lookup for it is running or done. That folds the 2 to 4 calls per open into one.
- **F1b.** `ProvenanceLineageResolver.resolve` takes an `isCancelled` closure that defaults to `{ Task.isCancelled }`. It is checked in `Walker.visit`, in the index enumeration loop and before each sidecar read.
- **F1c.** One `ProjectSidecarIndex` per project, held in an actor and keyed by sidecar path, size and modification date. It stores only checksum, record id, creation date and sidecar URL, not whole envelopes. A matched sidecar is re-read with full path resolution only when the walk visits it. A light `Decodable` that reads only checksums skips the `JSONNode` re-rooting, because checksums need no path resolution. The FSEvents sidecar branch invalidates changed entries.

**Files.** `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift:485-544`, `Sources/LungfishWorkflow/Provenance/ProvenanceLineageResolver.swift:43-65`, `:102-138`, `:338-435`, `Sources/LungfishApp/Views/Inspector/InspectorViewController+Notifications.swift:450-474`.

**Older layouts.** Unchanged.

**Tests.**
- `ProvenanceInspectorViewModelTests.testRepeatedLoadOfSameItemRunsOneLookup` counts entries through the DEBUG `loadThreadingProbe` (`ProvenanceInspectorViewModel.swift:520-523`) and asserts 1 after three `load` calls, using `waitUntil`.
- `testSupersededLookupStopsWalking` holds the first walk on `loadFetchGate`, loads another item, releases the gate, and asserts that the first walk's index loop saw cancellation.
- `ProvenanceLineageResolverTests.testSidecarIndexReadsEachSidecarOncePerProject` asserts that two walks in one fixture project read each sidecar once.

**Lane.** lge-worker, opus, effort max. Review against SWIFT 1, SWIFT 2 and SWIFT 7.

### F2. One manifest decode per open, off the main actor (cause 2)

**Design.**
- `displayReferenceBundleViewportFromSidebar` and `displayMappingAnalysisFromSidebar` load the manifest, and for M the result, in `Task.detached(priority: .userInitiated)` behind the existing display token (`ContentDisplay.swift:796-813`). The "Loading…" indicator shows meanwhile. The commit back on main passes the same `BundleManifest` value to every consumer:
  - the route (`ViewerDisplayRoute.swift:52-54` takes it as an argument)
  - the embedded viewer (`displayBundle(at:mode:manifest:)`, so `loadBundleDisplayContext` skips `:116`)
  - `installBAMMetadataPresentation` (`ClassifierDisplay.swift:55`)
  - `updateMappingProvenanceSources` (`PublicAPI.swift:65`)
  - `refreshMappingRowsForVisibleAlignmentTrack`, which uses `currentInput?.viewerBundleManifest` instead of `:1323`
- Replace the synthesized `==` of `ReferenceBundleViewportInput` with an identity compare: URLs, manifest `identifier` and `modifiedDate`, and the result file's modification date.
- Menus. `currentReferenceBundleURL` builds `referenceBundleCandidates` only when the viewer shows no bundle (`AppDelegate.swift:1573-1581`). A mapping folder's viewer bundle is found by listing its `*.lungfishref` child, not by decoding `mapping-result.json` (`:1606-1618`). Call Variants validation uses a manifest the open already holds, or a small per-URL cache keyed by modification date, instead of `loadReferenceBundle` (`:2487-2493`, `:1620-1623`).

**Files.** the cited lines in `MainSplitViewController+ContentDisplay.swift`, `ViewerDisplayRoute.swift`, `ViewerViewController+BundleDisplay.swift`, `ReferenceBundleViewportController.swift`, `ReferenceBundleViewportInput.swift`, `MainSplitViewController+ClassifierDisplay.swift`, `InspectorViewController+PublicAPI.swift` and `AppDelegate.swift`. `ViewerViewController.swift` (4283 lines) sits at its size baseline, so put new code in the extensions.

**Older layouts.** Unchanged.

**Tests.** A counting `BundleManifest` loader seam that asserts it is off main with `dispatchPrecondition(condition: .notOnQueue(.main))`:
- `ReferenceOpenManifestLoadTests.testReferenceOpenDecodesOnceOffMain`
- `MappingOpenManifestLoadTests.testMappingOpenDecodesViewerManifestOnceOffMain`
- `AppDelegateMenuValidationTests.testImportBAMValidationDoesNotLoadMappingResult`, with a counting seam on `MappingResult.load`

**Lane.** lge-worker, opus, effort max.

### F3. The per-sequence work on main (cause 3)

**Design.**
- **F3a.** Build each natural-sort key once (`ChromosomeNavigatorView.swift:51-53`):

  ```swift
  chromosomes.map { (chromosomeSortKey($0.name), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
  ```

  The measured time falls from 12.17 s to 0.49 s with the same order. Where only the first element is used, take `min(by:)` on precomputed keys instead (`ViewerViewController+BundleDisplay.swift:260-278`, `InspectorViewController+PublicAPI.swift:89-92`).
- **F3b.** Build the alias maps lazily, on the first alias lookup, and only when the bundle has annotation or variant tracks (`AnnotationSearchIndex.swift:416`, `:1696-1716`). That saves 5.5 s and 1,264 MB here.
- **F3c.** Add `chromosomeStats(mappedOnly:)`, using `WHERE mapped_reads > 0` on `idx_chromstats_mapped`, for `metadataFallbackRows` (`AlignmentMetadataDatabase.swift:320-335`, `ReferenceBundleViewportController.swift:1569-1596`). Open the stats database once per refresh, not three times (`:1500-1567`).
- **F3d.** Give the sequence column a precomputed sort key, so 905,628 rows are not compared with `localizedStandardCompare` (`ReferenceBundleRecordTable.swift:348-370`, measured 3.26 s against 0.20 s). Keep the same visible order: a key from `String.compare(options: [.numeric, .caseInsensitive])` folding, or a cached localized key. Do not re-sort rows that arrive in order (`BatchTableView.swift:760-763`).
- **F3e.** Build the description dictionary only for displayed rows (`ReferenceBundleViewportController.swift:699-713`). Give `BundleDataProvider.chromosomeInfo(named:)` a lazily built name-to-index dictionary (`BundleDataProvider.swift:96-105`).
- Also store and cancel the refresh task at `ReferenceBundleViewportController.swift:1375`, so a superseded refresh stops its `samtools` children instead of only dropping their output (`:1406-1410`).

**Tests.** No timing thresholds.
- `ChromosomeNavigatorSortTests.testNaturalSortBuildsEachKeyOnce`: a key-builder seam counts n calls.
- `AnnotationSearchIndexTests.testNoAliasMapsWithoutAnnotationOrVariantTracks`
- `AlignmentMetadataDatabaseTests.testMappedOnlyStatsSkipZeroReadRows`
- `ReferenceBundleRecordTableTests.testSequenceSortOrderUnchanged`, a golden order over names such as `chr2`, `chr10`, `NC_041754.1`, `HG374866.9.1343`

**Lane.** lge-worker, opus, effort max. F3a and F3c are mechanical and could go to sonnet, effort max, but F3b and F3d must keep behavior exactly, so one opus lane is safer.

### F4. Mapping results that list only contigs with reads (needs Q-S3, BIO)

**Design.** Pass `includeUnmappedReferenceRows: false` in `summarizeMappedContigs` (`ManagedMappingPipeline.swift:226-233`) and in the viewer's builder (`ReferenceBundleViewportController.swift:35-60`). Persist `referenceCount` and `zeroReadReferenceCount` as schema 2 of `PersistedMappingResult` (`MappingResult.swift:165-178`). The result falls from 252 MB to about 30 KB for this run. Write it through `DurableReplace` (SWIFT 4, `MappingResult.swift:229-232`).

**Older results.** Schema 1 still decodes. A reader may filter to `mappedReads > 0` after decode, as the viewer already does (`ReferenceBundleViewportController.swift:1455-1456`), but the first decode stays 2.6 s until F2 moves it off main.

**Tests.**
- `ManagedMappingPipelineTests.testResultOmitsZeroReadContigs`
- `MappingResultTests.testSchemaOneResultWithZeroReadRowsLoads`
- an export test for `delimitedContent` (`ReferenceBundleViewportController.swift:1796-1820`)

**Lane.** lge-worker, opus, effort max, after BIO rules.

### F5. Slim manifests and a thin viewer bundle (needs Q-S4, Q-S5, Q-S6, ARCH)

- **F5a.** Do not persist `browser_summary` when it equals the summary synthesized from `genome.chromosomes`. That halves the file to 392 MB. Load it from the manifest in memory (`BundleManifest.swift:805-811`). `BundleBrowserLoader` must use that path for a manifest without a summary, never `BundleSequenceSummarySynthesizer` plus the mirror store (`BundleBrowserLoader.swift:47-66`), or opening an older bundle would write a 905,628-row mirror.
- **F5b.** Move per-sequence records to a compact sidecar beside the `.fai`, such as `genome/sequences.sqlite` with name, length, description and flags. The manifest keeps counts and totals. Tables page rows by index from the sidecar, since `NSTableView` already asks for cells lazily. Older bundles keep their arrays, and readers prefer the sidecar when it exists.
- **F5c.** The mapping viewer bundle gets a manifest without per-sequence arrays that resolves its genome through `origin_bundle_path`. The alternative is hard-linking `genome/` on the same HFS+ or APFS volume, with a copy fallback on exFAT under `docs/contracts/EXTERNAL-VOLUMES.md`. Either saves the 361 MB copy and two 706 MB writes per run.

**Lane.** lge-worker, opus, effort max, per ARCH ruling.

### F6. The search index ignores app-state files

**Design.** Drop `BundleViewState.filename` and the other `appStateFileNames` (`BundleKindRegistry.swift:40`, `:249`) before calling `scheduleUpdate` (`SidebarViewController.swift:690-700`, `UniversalProjectSearchService.swift:128-139`). Make `update(changedPaths:)` skip a bundle whose changed paths are all app state (`ProjectUniversalSearchIndex.swift:537-560`). `indexReferenceBundle` still decodes the whole manifest to read `variants` (`+Indexers.swift:174`), which F5a and F5b shrink.

**Test.** `ProjectUniversalSearchIndexTests.testViewStateChangeDoesNotReindexBundle`, with a counting indexer seam.

**Lane.** lge-worker, sonnet, effort max.

### Progressive display

With F1 to F3 and F6 in place, the first paint can come from small data:
- the mapping table from the 94 rows with reads (F3c, later F4)
- the reference table from the manifest decoded off main (F2), later paged from the F5b sidecar

The embedded viewer then opens the first contig with reads behind its own "Loading reference viewer…" placeholder (`ReferenceBundleViewportController.swift:851`). Q-S1 asks UX to rule on what each pane shows meanwhile.

## 9. Open questions and checks

| Id | Field that rules | Question |
|---|---|---|
| Q-S1 | UX | Progress and partial display: may the list show before the embedded viewer and the Inspector lineage finish, with a progress line in the summary bar and "Loading lineage" in the Provenance pane? Which pane may stay empty, and for how long? |
| Q-S2 | ARCH | Each EsViritu BAM and BAI sidecar copies the batch record's 17.8 MB `steps` array (301 files, 5,242 MB in project 32616). Should the writer store the batch record once and have each output sidecar point at it? Older projects keep the big files, so readers must still accept them. |
| Q-S3 | BIO | May `mapping-result.json` and the contig table drop contigs with zero reads, keeping only a count of them? Does the result export need them? |
| Q-S4 | ARCH | May `browser_summary` be left out of `manifest.json` when it is derivable from `genome.chromosomes`? It is half of the file. |
| Q-S5 | ARCH | Layout and compatibility of a per-sequence sidecar: name, location, format, and how the manifest declares it. |
| Q-S6 | ARCH | Thin mapping viewer bundle: a manifest that resolves its genome through `origin_bundle_path`, or hard links with a copy fallback. What happens when the origin moves or is deleted, and on exFAT? |

Checks for the manager to call:

| Id | Check | Agent |
|---|---|---|
| C1 | Symbolicate both samples with the 2026.10.20 (9488) dSYM on the Mac Studio. Run `atos -l 0x102ab4000` on `0x105f49320`, `0x105f05ff8`, `0x105f07330`, `0x103e1dac8`, `0x103e23d94` and `0x102fd2aac`, and confirm `ProvenanceLineageResolver`, `ProjectSidecarIndex`, `ProvenanceEnvelopeReader` and `PortablePath.resolveJSON` | lge-worker, sonnet, effort max |
| C2 | Read `BgzipIndexedFASTAReader` and `ReferenceBundle` to learn how the 38 MB `.fai` loads on the first sequence fetch (whole file into a dictionary or not), so F5b can rely on it | lge-expert, opus, effort max |
| C3 | Trace the FASTA import writer of R and the alignment attach of the mapping publication to their exact `save` lines (section 7 cites the loads at `MappingViewerBundlePublicationService.swift:1479` and `BAMImportService.swift:293`) | lge-expert, opus, effort max |

## 10. SWIFT checklist notes for the lanes

- **SWIFT 1, isolation.** The detached provenance walks outlive their selection (`ProvenanceInspectorViewModel.swift:494-499`). The mapping refresh task is fire-and-forget (`ReferenceBundleViewportController.swift:1375`).
- **SWIFT 2, main thread.** File reads and decodes on main at `ContentDisplay.swift:817` and `:914`, `ViewerDisplayRoute.swift:53`, `InspectorViewController+PublicAPI.swift:65`, `ViewerViewController+BundleDisplay.swift:116`, `ReferenceBundleViewportController.swift:1323` and `MainSplitViewController+ClassifierDisplay.swift:55`. Menu validation decodes at `AppDelegate.swift:1611` and `:1621`. SQLite queries run on main at `ReferenceBundleViewportController.swift:1500-1596`.
- **SWIFT 4, durability.** `MappingResult.save` writes a scientific output with a plain atomic `Data.write` (`MappingResult.swift:229-232`).
- **SWIFT 5, cost.** Large inputs are loaded whole and decoded 3 to 5 times per open, and the lineage index re-reads the project's sidecars on every walk.
- **SWIFT 7, timing.** The proposed tests use counting seams and `waitUntil`, never wall-clock limits.
