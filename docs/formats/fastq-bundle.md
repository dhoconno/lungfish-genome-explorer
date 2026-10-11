# FASTQ bundles

A `.lungfishfastq` folder holds one read dataset of Lungfish Genome Explorer (LGE) with the files that describe it. A physical bundle holds its reads, and a virtual bundle points into the reads of another bundle. This page gives both layouts, their manifests, the `<reads>.lungfish-meta.json` sidecar and why a view never rewrites it, and the provenance records. It is written for developers. The kind id is `fastq` in `Sources/LungfishIO/Bundles/BundleKindRegistry.swift`, which records no single manifest for the kind, and the helpers are `FASTQBundle` in `Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift`.

## Physical bundles

A bundle made by an import holds the FASTQ file, its metadata sidecar and its records. The released MHC demo in `Tests/Fixtures/demo-projects/lge-demo-mhc-genotyping-2026.9.58.zip` has two bundles with this layout.

```
Sample.lungfishfastq/
  Sample.fastq.gz
  Sample.fastq.gz.lungfish-meta.json
  .lungfish-provenance.json
  provenance/
    bundle.lungfish-provenance.json
    Sample.fastq.gz.lungfish-provenance.json
    Sample.fastq.gz.lungfish-meta.json.lungfish-provenance.json
```

A FASTQ file is one whose extension is `fastq` or `fq`, with or without `.gz`, and an AppleDouble `._` file never counts (`FASTQBundle.isFASTQFileURL`). `FASTQBundle.resolvePrimaryFASTQURL(for:)` returns the first file that `source-files.json` lists when the bundle has that manifest, and otherwise the first FASTQ file at the top of the bundle in name order. It prefers any file to `preview.fastq` and returns `preview.fastq` only when no other FASTQ file is there.

Two optional manifests describe a bundle with more than one file. `source-files.json` (`FASTQSourceFileManifest` in `Sources/LungfishIO/Formats/FASTQ/FASTQSourceFiles.swift`) lists files that read as one dataset in the listed order, such as ONT chunk files linked under `chunks/`. `resolveAllFASTQURLs(for:)` returns them in that order. When a derived bundle reads such a root, `rootSequenceURLs(rootFASTQFilename:in:)` refuses a root with a missing member rather than reading it as a shorter dataset (`FASTQBundlePathError.missingMember`). `read-manifest.json` (`ReadManifest` in `Sources/LungfishIO/Formats/FASTQ/ReadManifest.swift`) gives each file its role when a bundle holds files of different read types, such as paired, merged and orphan reads after a merge.

## Virtual bundles

A derived bundle holds `derived.manifest.json`, which is `FASTQBundle.derivedManifestFilename`, and decodes as a `FASTQDerivedBundleManifest` (`Sources/LungfishIO/Formats/FASTQ/FASTQDerivedBundleManifest.swift`). The manifest names its parent and root bundles by relative path, the root FASTQ file it reads, the operation and the lineage that made it, the cached statistics, the pairing mode and read classification, payload checksums, and a materialization state.

The payload says what the bundle stores, and `FASTQDerivativePayload` in `Sources/LungfishIO/Formats/FASTQ/FASTQDerivativePayload.swift` names nine kinds.

| Payload | What the bundle stores |
| --- | --- |
| `subset` | A list of read IDs, by default `read-ids.txt` |
| `trim` | A TSV of trim positions, `trim-positions.tsv` |
| `orientMap` | A TSV of read orientations and a preview FASTQ |
| `demuxedVirtual` | A barcode's read IDs and a preview FASTQ, with optional trim positions and orientation map |
| `demuxGroup` | The folder of per-barcode bundles |
| `full` | A materialized FASTQ file |
| `fullPaired` | Materialized R1 and R2 files |
| `fullMixed` | Materialized files with classified read roles |
| `fullFASTA` | A materialized FASTA file |

The first four keep pointers into the root bundle's reads. A materialization state is `virtual`, `materializing` with a task id, or `materialized` with the SHA-256 of the written file (`Sources/LungfishIO/Formats/FASTQ/VirtualFASTQState.swift`). A manifest without a state reads as materialized for the four full payloads and as virtual for the others, and a `materializing` state left by a crashed session reads as virtual (`FASTQDerivedBundleManifest.resolvedState`).

### preview.fastq

A virtual bundle holds a small `preview.fastq` so the dashboard has reads to show. Demultiplexing writes the first 1,000 reads of each barcode by default (`ExactBarcodeDemux` in `Sources/LungfishWorkflow/Demultiplex/ExactBarcodeDemux.swift`), and the ONT directory import writes the first 1,000 reads of the first chunk (`Sources/LungfishIO/Formats/FASTQ/ONTDirectoryImporter.swift`).

Because `preview.fastq` is then the only FASTQ file in the bundle, `resolvePrimaryFASTQURL(for:)` returns it. A classifier or mapper that took that answer would see about 1,000 reads instead of the dataset, so every run first materializes a virtual bundle with `FASTQCLIMaterializer` in `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift`. This is a binding rule of `AGENTS.md` and a trap that `Sources/LungfishIO/AGENTS.md` lists.

### Paths inside the manifests

A derived manifest records other bundles as project-relative paths that start with `@/`, or as older `../` paths relative to the bundle, and `FASTQBundle.resolveBundle(relativePath:from:)` reads both. A path that names a file inside a bundle must stay inside it, and it may not name a control file, which is `derived.manifest.json`, `source-files.json`, `read-manifest.json`, `.lungfish-provenance.json` or anything under `provenance/` (`FASTQBundle.validatedBundleMemberURL`).

## Nested bundles and other files

A bundle can hold other bundles, and the sidebar lists them under the bundle's row while it never lists the bundle's own files (`Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift`).

| Path | What it holds | Source |
| --- | --- | --- |
| `derivatives/` | Derived bundles, listed by creation date | `FASTQBundle.scanDerivatives` |
| `demux/`, then `demux-2` and on | One bundle per barcode, from one demultiplex run each | `FASTQBundle+DemultiplexOutput.swift` |
| `demux-manifest.json` | The demultiplex configuration and the links to the barcode bundles | `DemultiplexManifest.swift` |
| `demux/batch-operations.json` | One operation run across the barcode bundles | `FASTQBatchManifest.swift` |
| Top-level `.lungfishfastq` folders | Read bundles that taxonomy extraction wrote | `SidebarProjectScanner.swift` |

A bundle may also hold `metadata.csv` with sample metadata (`FASTQBundleCSVMetadata.swift`) and `analyses-manifest.json` with the analyses run on it ([analyses-layout.md](analyses-layout.md)). While an operation builds a bundle it holds the hidden `.processing` marker of `OperationMarker` in `Sources/LungfishCore/Services/OperationMarker.swift`, and the sidebar hides the bundle until the marker goes. The files without a folder in the Source column are in `Sources/LungfishIO/Formats/FASTQ`.

## The reads metadata sidecar

`<reads>.lungfish-meta.json` sits beside the FASTQ file it describes, named by `FASTQMetadataStore.metadataURL(for:)` in `Sources/LungfishIO/Formats/FASTQ/FASTQMetadataStore.swift`. It is a `PersistedFASTQMetadata` (`Sources/LungfishIO/Formats/FASTQ/PersistedFASTQMetadata.swift`) and holds two sorts of facts. Some describe the reads and steer tools, such as the sequencing platform with its evidence, the assembly read type, the read classification, the ingestion steps and the SRA or ENA record. Others are computed and could be computed again, such as the dataset statistics and the `seqkit stats` summary.

The store writes the file with ISO 8601 dates, pretty printing and sorted keys by a Foundation atomic write, and never for a FASTQ file that is missing. `loadIfPresent(for:)` throws when a sidecar exists but cannot be decoded, so a caller that rewrites the file never replaces one it could not read.

For a bundle that `source-files.json` describes, the dashboard reads its statistics from a sidecar named after the bundle, `<name>.lungfishfastq.lungfish-meta.json`, which sits beside the bundle in its parent folder (`loadFASTQDatasetInBackground` in `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift`). The deletion planner removes such a sidecar with the bundle ([bundle-kinds.md](bundle-kinds.md)).

### Why a view never rewrites it

The sidecar's name is not hidden, so `ProvenanceFileHasher.directoryManifest` in `Sources/LungfishWorkflow/Provenance/ProvenanceFileHasher.swift` covers it in every directory digest of the bundle. The bundle's record also lists it as an output, so the bundle carries `provenance/<reads>.lungfish-meta.json.lungfish-provenance.json` with its SHA-256, as both demo bundles do. A rewrite at view time would make that digest and that record stale.

Since lane B3 the FASTQ dashboard keeps the statistics it computes on view in memory instead (plan decision S11). It keeps at most 32 datasets for the session, each while the payload file keeps its device, inode, size and dates, and the view writes nothing into the project (`MainSplitViewController+GenomicsDisplay.swift`). `ReadTimeWriteTests` in `Tests/LungfishAppTests/ReadTimeWriteTests.swift` fails when viewing a FASTQ bundle changes a byte.

An explicit action may still write the sidecar. The imports, the operations that make a bundle, bundle merging, the SRA window and read extraction call `FASTQMetadataStore.save`. The demultiplex metadata drawer saves it when the user saves the drawer (`Sources/LungfishApp/Views/Viewer/ViewerViewController+FASTQDrawer.swift`). A Quality Report rewrites it with no record until sub-phase 2.7 (`FASTQDatasetViewController.swift` in `Sources/LungfishApp/Views/Viewer`, and [RECORDING-PROVENANCE.md](../contracts/RECORDING-PROVENANCE.md)).

Neither the code nor a ruling settles whether this sidecar counts as an app cache under the record name rule of [bundle-kinds.md](bundle-kinds.md). It holds facts that steer tools beside its cached statistics, and the panel has not classed it.

## Provenance

A FASTQ bundle follows the standard record rule, with a root `.lungfish-provenance.json` and a `provenance` folder that holds `bundle.lungfish-provenance.json` and one record for each output ([reference-bundle.md](reference-bundle.md) describes the writer). Some operations keep a record of their own in the bundle. Read extraction writes `extraction-metadata.json` at the bundle root (`Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift`), and the finder in `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder+SidecarLookup.swift` reads it by name. pbAA clustering writes `artifacts/pbaa-clusters/<id>/pbaa-clustering-provenance.json` beside each set of clusters (`FASTQPBAAArtifactStore` in `Sources/LungfishIO/Formats/FASTQ/FASTQPBAAArtifactStore.swift`).
