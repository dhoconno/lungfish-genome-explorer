# The Analyses folder

`Analyses/` at the root of a Lungfish Genome Explorer (LGE) project holds the results of analysis runs, one folder per run, beside the bundles some runs make. This page gives how result folders are named, created and marked, what `analysis-metadata.json` holds, and how the sidebar, search and the deletion planner recognize a result. It is written for developers. The folder name is `AnalysesFolder.directoryName`, and the lifecycle is in `AnalysesFolder` in `Sources/LungfishIO/Bundles/AnalysesFolder.swift`.

## Folder names

A single run gets `<id>-<timestamp>` and a batch run gets `<id>-batch-<timestamp>`. The timestamp is `yyyy-MM-dd'T'HH-mm-ss` in the Mac's local time zone with a POSIX locale, so a folder made at 14:03:22 on 10 October 2026 is `kraken2-2026-10-10T14-03-22`. When another run already holds the name, `-2`, `-3` and so on are appended (`AnalysesFolder.createAnalysisDirectory`).

The id is an analysis kind from `AnalysisToolRegistry.all` in `Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift`, which holds 23 kinds. In registry order they are `esviritu`, `kraken2`, `taxtriage`, `minimap2`, `bwa-mem2`, `bowtie2`, `bbmap`, `spades`, `megahit`, `skesa`, `flye`, `hifiasm`, `naomgs`, `nvd`, `cz-id`, `mafft`, `ont-genotyping`, `viralrecon`, `primer-order`, `pbaa`, `savont`, `illumina-amplicon-genotyping` and `ont-sample-bundle-genotyping`. Name parsing tries the kinds in that order, and `testNoIDPlusHyphenPrefixesAnotherIDPlusHyphen` in `Tests/LungfishIOTests/Analysis/AnalysisToolRegistryTests.swift` fails when one id plus a hyphen starts another. An analysis id is not a managed tool id, so `bbmap` is the analysis and `bbtools` its lock entry (`Sources/LungfishIO/AGENTS.md`).

Results imported from NAO-MGS, NVD and CZ ID may instead be named `<id>-<sample name>`, because their descriptors accept imported sample names (`AnalysisToolRegistry.importedResultIDs`).

## Creating a result folder

`createAnalysisDirectory(tool:in:isBatch:date:command:)` builds the folder under a hidden staging name, `.<name>.creating-<UUID>`. It writes two files there and then renames the folder into place with `RENAME_EXCL` through `PortableRename`, which falls back on ExFAT, FAT and SMB volumes, so no listing ever sees the folder without its record.

| File | Purpose |
| --- | --- |
| `.lungfish-run-in-progress.json` | The `AnalysisRunRecord` of `Sources/LungfishCore/Services/AnalysisRunRecord.swift`, which marks the run as not finished |
| `analysis-metadata.json` | The kind, batch flag and creation date, described below |

A folder that holds the run record is incomplete and is never listed, by the sidebar, by `AnalysesFolder.listAnalyses` or by the CLI. The record counts by its presence, so an unreadable record still hides the folder, and a folder without one is complete, which keeps results from builds older than the record visible. The run removes the record with `markAnalysisComplete` as its last step after success, and completed with warnings counts as success.

A failed or cancelled run removes its folder with `discardFailedAnalysisDirectory`, which touches only a folder inside a project's `Analyses/` tree and removes an empty batch folder after its last sample folder. An interrupted run keeps its record and stays hidden, and the Operations panel lists it for review and removal through `InterruptedAnalysisRunDiscovery` in `Sources/LungfishApp/Services/InterruptedAnalysisRunDiscovery.swift`. A created folder that no run ever tracks stays hidden too, and `Sources/LungfishIO/AGENTS.md` lists the creation sites that ignore a failure with `try?` as a known trap.

A run that writes into a folder the user chose, such as a `lungfish-cli` output folder, claims it with `beginRunInOutputDirectory`. The claim applies only inside a project, never to the project or its `Analyses/` folder, and only to a folder that is empty or already carries a record.

A batch run puts each sample in a subfolder from `batchSampleDirectory(named:in:)`, which cleans the sample name and appends `-2`, `-3` and so on when names collide. `removeBatchDirectoryIfEffectivelyEmpty` removes the whole batch once every sample has finished and none left content.

## analysis-metadata.json

`AnalysisMetadata` holds three keys. `tool` is the analysis id as a string, `isBatch` says whether the run was a batch, and `created` is the creation date in ISO 8601.

```json
{
  "created" : "2026-10-10T19:03:22Z",
  "isBatch" : false,
  "tool" : "kraken2"
}
```

`writeAnalysisMetadata` encodes with pretty printing and sorted keys and publishes the file through `DurableReplace`, so the name always holds a complete old or new file (plan decisions S1, V1 and V2, lane P2). `readAnalysisMetadata` returns nothing for a missing or unreadable file, which is the case for folders made before the file existed. The file is the authoritative way to identify a result, because it survives a rename of the folder.

## mapping-result.json

A mapping run, from `lungfish-cli map` or the app's Map Reads, writes `mapping-result.json` at the top of its result folder. `MappingResult` in `Sources/LungfishWorkflow/Mapping/MappingResult.swift` reads and writes it. `save(to:relativeTo:)` encodes with pretty printing and sorted keys and publishes the file through `DurableReplace`, so the name always holds a complete old or new file and every save gives it a new modification date. `load(from:)` reads `alignment-result.json`, the older name, when the folder has no `mapping-result.json`.

| Key | What it holds |
| --- | --- |
| `schemaVersion` | 1 or 2, described below |
| `mapper` | The mapper id, such as `minimap2` |
| `modeID` | The mapping mode id, such as `short-read-default` |
| `bamPath`, `baiPath` | The sorted BAM and its index, relative to the result folder when they are inside it |
| `sourceReferenceBundlePath`, `viewerBundlePath` | The reference bundle the reads were mapped against and the viewer bundle made from it, when known |
| `totalReads`, `mappedReads`, `unmappedReads` | Read counts from `samtools flagstat` |
| `wallClockSeconds` | The wall time of the run |
| `contigs` | One row per reference sequence, described below |
| `referenceCount` | Schema 2 only. How many reference sequences the BAM header lists |
| `unalignedReferenceCount` | Schema 2 only. How many reference sequences no alignment record names, which `contigs` leaves out |

A row of `contigs` holds `contigName`, `contigLength`, `mappedReads` (primary reads), `mappedReadPercent`, `meanDepth`, `coverageBreadth`, `medianMAPQ`, `meanIdentity` and `readGroupIDs`, and a row made from one alignment track adds `sampleID` and `alignmentTrackID`. `MappingSummaryBuilder` makes the rows from `samtools coverage`, which lists every sequence of the BAM header, and from one `samtools view` pass, which measures MAPQ and identity.

The two schema numbers differ in which rows `contigs` holds.

- Schema 1 lists every reference sequence of the BAM header, zero rows included, and holds neither count. Results made before schema 2, and results whose counts are unknown such as the filtered results of ONT genotyping, are schema 1.
- Schema 2 lists only the reference sequences that at least one alignment record names, primary, secondary or supplementary. A sequence with only secondary or supplementary records keeps its row with 0 in `mappedReads` and its measured MAPQ and identity. Both counts are present, and `contigs.count + unalignedReferenceCount == referenceCount`.
- `save` writes schema 2 when both counts are known and schema 1 with neither count otherwise. An absent count means unknown, never that `contigs` lists every reference sequence.
- Readers accept both numbers and never refuse a higher one. A build released before schema 2 reads a schema-2 file, ignores the counts and shows its rows. Nothing rewrites a schema-1 file, and its table export keeps its bytes.

The mapping table export writes the rows the file holds, never more, and its provenance record adds `referenceCount` and `unalignedReferenceCount` to the resolved values of a schema-2 result.

## How a folder is recognized

`AnalysesFolder.analysisInfo(for:)` names the kind of a result folder, its date and whether it is a batch. It tries five rules in order:

1. `analysis-metadata.json`, when it decodes.
2. The name `<id>-batch-<timestamp>`.
3. The name `<id>-<timestamp>`.
4. The name `<id>-<sample name>` for the three imported kinds, dated by the folder's creation date.
5. The files inside the folder, for a folder the user renamed.

| Files in the folder | Kind |
| --- | --- |
| `cz-id-manifest.json` and `classification-result.json` | `cz-id` |
| `classification-result.json` | `kraken2` |
| `viralrecon-result.json` | `viralrecon` |
| `assembly-result.json` | The `tool` it names when that is a known kind, otherwise `spades` for schema version 1 or the SPAdes keys |
| `mapping-result.json` | The `mapper` it names when that is a known kind |
| `manifest.json` with `bundleKind` set to `multiple-sequence-alignment`, and `alignment/primary.aligned.fasta` | `mafft` |
| `manifest.json` and `hits.sqlite` | `nvd` when the manifest has `experiment`, otherwise `naomgs` |
| A file ending in `detected_virus.info.tsv` | `esviritu` |
| `hits.sqlite` alone | `taxtriage` |

The probes run in the order of the table (`AnalysesFolder.swift`). `listAnalyses(in:)` walks user folders inside `Analyses/` too, so grouped runs stay visible, and skips incomplete runs.

## The sidebar

`SidebarProjectScanner.collectAnalysisItems` in `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift` reads `Analyses/` one entry at a time and skips hidden names. It also skips an entry that is still being built, which holds the `.processing` marker or a run record, and the pipeline's own working folders, which are `.lungfishrun` run bundles and Viral Recon's raw `viralrecon-results-<token>` trees. For each other folder it decides in this order:

- A folder whose extension the sidebar classifies as a bundle shows as that bundle, such as a `.lungfishmsa` alignment or a `.lungfishgenotype` result.
- A folder that `analysisInfo` recognizes becomes an analysis row titled with the folder name and the kind's icon. Its subtitle is the timestamp, or a title read from the result for Kraken2, EsViritu and CZ ID. A classifier batch is one row with a text badge, and a batch of another tool lists its sample folders.
- Any other folder is a grouping folder whose entries are read the same way, and it shows only when it holds something, except at the top of `Analyses/`.

The bundle kinds that the copier sends to `Analyses/` are in [bundle-kinds.md](bundle-kinds.md). A genotype result must live there, and alignments go to `Analyses/Multiple Sequence Alignments`.

## Search

Universal search recognizes the result folders of five indexed kinds through `ProjectUniversalSearchResultKind.recognize(directory:)` in `Sources/LungfishIO/Search/ProjectUniversalSearchModels.swift` (plan decision V12, lane B56). A folder holds a result only when the kind's finished-run file is present.

| Result kind | Analysis id | File that must be present |
| --- | --- | --- |
| `classification_result` | `kraken2` | `classification-result.json` |
| `esviritu_result` | `esviritu` | `esviritu-result.json` |
| `taxtriage_result` | `taxtriage` | `taxtriage-result.json` |
| `naomgs_result` | `naomgs` | `manifest.json` |
| `nvd_result` | `nvd` | `hits.sqlite` |

The folder name decides first, because it costs nothing. A Kraken2 result is named by `classification-` or `kraken2-`, and the others by their id and a hyphen. When no name claims the folder, `analysisInfo` decides, so a renamed folder is still found. A query reaches a kind by its result kind, its analysis id, its `lungfish-cli` command group or its sidebar name, ignoring case, hyphens, underscores and spaces, so `type:Kraken2` and `type:nao-mgs` both work. The index lives in the hidden `.universal-search.db` at the project root (`Sources/LungfishIO/Search/ProjectUniversalSearchIndex.swift`), and the GUI writes no record for it (plan decision S12).

## Deletion

`ProjectDeletionPlanner` in `Sources/LungfishOperations/ProjectDeletionPlanner.swift` treats a folder that holds `analysis-metadata.json`, a result file such as `classification-result.json` or `mapping-result.json`, or another of its twelve marker files as one project object. A folder under `Analyses/` that holds a `manifest.json` counts as one object too.

## A bundle's analysis history

A run can also note itself inside the bundle its inputs came from, in `analyses-manifest.json`. `AnalysisManifestStore.recordAnalysis` in `Sources/LungfishIO/Bundles/AnalysisManifest.swift` appends an entry with the kind, the date, the result folder's path relative to `Analyses/`, a display name, the parameters, a summary and a status. The classification runs in `Sources/LungfishApp/App/AppDelegate+Classification.swift`, mapping in `Sources/LungfishWorkflow/Mapping/MappingResultLayoutService.swift`, the cross-project copier and one Tools menu path write it.

`AnalysisManifestStore.load(bundleURL:projectURL:)` hides entries whose result folders are gone and never writes the file.
