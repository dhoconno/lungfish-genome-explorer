# Reference bundles

A `.lungfishref` folder holds one reference genome of Lungfish Genome Explorer (LGE) together with the tracks drawn on it, such as annotations, variants and alignments. This page gives its layout, its `manifest.json`, its tracks, its view state and its provenance records. It is written for developers. The kind id is `reference` in `Sources/LungfishIO/Bundles/BundleKindRegistry.swift`, and [bundle-kinds.md](bundle-kinds.md) lists how the sidebar, the deletion planner and the copier treat it.

## Layout

The manifest names every file the bundle uses by a path relative to the bundle, so a reader follows the manifest and never guesses from folder names. The folders below are the ones the writers create.

```
Name.lungfishref/
  manifest.json
  .viewstate.json
  .lungfish-provenance.json
  genome/
    sequence.fa.gz
    sequence.fa.gz.fai
    sequence.fa.gz.gzi
  annotations/
    <track id>.db
  variants/
    <track id>.bcf
    <track id>.bcf.csi
    <track id>.db
  tracks/
  alignments/
    <name>.bam
    <name>.bam.bai
    <track id>.stats.db
  metadata/
    genbank_records.sqlite
  provenance/
    bundle.lungfish-provenance.json
    manifest.json.lungfish-provenance.json
    genome/sequence.fa.gz.lungfish-provenance.json
```

`NativeBundleBuilder` in `Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift` creates `genome`, `annotations`, `variants`, `tracks` and `metadata`. It copies the FASTA to `genome/sequence.fa`, compresses it with bgzip when the build asks for it, and indexes it to a `.fai` file plus a `.gzi` file for a compressed sequence. It writes each annotation track's SQLite index to `annotations/<track id>.db`, each variant track to `variants/<track id>.bcf` with a `.csi` index and a `.db`, and a GenBank record store to `metadata/genbank_records.sqlite`. `BAMImportService` in `Sources/LungfishWorkflow/Mapping/BAMImportService.swift` creates `alignments`, described under Tracks.

The released MHC teaching demo in `Tests/Fixtures/demo-projects/lge-demo-mhc-genotyping-2026.9.58.zip` holds a reference bundle with this layout, where the annotations folder keeps the imported GFF3 beside its database, and empty `tracks` and `variants` folders.

## The manifest

`manifest.json` is a `BundleManifest`, defined in `Sources/LungfishCore/Bundles/BundleManifest.swift` and named by `BundleManifest.filename`. The JSON keys are snake case.

| Key | Holds |
| --- | --- |
| `format_version` | The bundle format version, a string such as `1.0` |
| `name`, `identifier`, `description` | The display name, a reverse-DNS identifier and an optional description |
| `origin_bundle_path` | The reference bundle this one was copied from, as `@/` project-relative, `../` relative or absolute, or absent |
| `created_date`, `modified_date` | ISO 8601 dates |
| `source` | Organism, assembly, accession, database, source URL and download date (`SourceInfo`) |
| `genome` | The sequence file and its indexes, total length and chromosomes (`GenomeInfo`), or absent in a variant-only bundle |
| `record_store` | An optional indexed record store, such as one built from GenBank (`ReferenceRecordStoreInfo`) |
| `warnings` | Recoverable import problems, empty for a lossless import |
| `annotations`, `variants`, `tracks`, `alignments` | The four track lists |
| `metadata` | Optional groups of labelled values, kept by source |
| `browser_summary` | An optional summary of the bundle browser rows, stored only when it differs from the one synthesized from `genome` and the track lists |

`SourceInfo`, `GenomeInfo`, `ChromosomeInfo` and the track types are in `Sources/LungfishCore/Bundles/BundleTracks.swift`, and `BundleBrowserSummary` is in `Sources/LungfishCore/Bundles/BundleBrowserSummary.swift`.

`BundleManifest.save(to:)` encodes with ISO 8601 dates, pretty printing and sorted keys. It writes the manifest's `storedForm` (`Sources/LungfishCore/Bundles/BundleManifest+StoredForm.swift`), which leaves out a browser summary equal to the one synthesized from `genome` and the track lists, compared on every field, and keeps a summary that differs as it is. A reader that needs the rows builds the summary in memory with `withSynthesizedBrowserSummaryIfNeeded()`. Opening a bundle with a genome does so once, off the main actor, and writes no mirror into the project. Reading never rewrites the file, so an older bundle keeps its stored summary until its next save, and `lungfish-cli project migrate` reports a manifest without a derivable summary as current. `save` publishes the file through `DurableReplace`, so the name always holds a complete old or new manifest and a bundle that is itself a link is refused (plan decisions S1, V1 and V2, lane P2). `BundleManifest.load(from:)` decodes ISO 8601 dates. A manifest without `alignments` or `warnings` decodes them as empty, because older bundles lack them, while `annotations`, `variants` and `tracks` must be present. The mutators that add a track clear the cached browser summary and set a new modified date.

`validate()` in `Sources/LungfishCore/Bundles/BundleManifest+Validation.swift` reports, among other problems, a missing name, identifier, genome path, genome index path or chromosome list, and a record store whose format or schema version it does not support. `validatedBundleMemberURL` in the same file accepts a manifest path only when it stays inside the bundle after links are resolved.

## Tracks

| Manifest key | Type | Paths it records | Written by |
| --- | --- | --- | --- |
| `genome` | `GenomeInfo` | `path`, `index_path`, `gzip_index_path`, plus `md5_checksum` | `NativeBundleBuilder` |
| `annotations` | `AnnotationTrackInfo` | `path` and `database_path` | `NativeBundleBuilder` |
| `variants` | `VariantTrackInfo` | `path`, `index_path` and `database_path` | `NativeBundleBuilder` and variant calling |
| `tracks` | `SignalTrackInfo` | `path` to a BigWig file | `NativeBundleBuilder` and `ReferenceBundleBuilder`, called with none today |
| `alignments` | `AlignmentTrackInfo` | `source_path`, `index_path` and `metadata_db_path`, plus `checksum_sha256` and `file_size_bytes` | `BAMImportService` and `PreparedAlignmentAttachmentService` |

BAM import writes a sorted, indexed copy of the alignment into `alignments/`, collects its statistics into `alignments/<track id>.stats.db`, records paths relative to the bundle and leaves the two bookmark fields empty (`BAMImportService.swift`). `PreparedAlignmentAttachmentService` in `Sources/LungfishWorkflow/Alignment/PreparedAlignmentAttachmentService.swift` attaches BAM files that another step prepared, such as duplicate marking and filtering. Alignments are always sorted, indexed BAM, and a SAM is converted and deleted (`AGENTS.md`).

Variant calling attaches a new variant track through `BundleVariantTrackAttachmentService` in `Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift`, with its record at `variants/<track>.lungfish-provenance.json`. `processSignalTracks` in `Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift` and `Sources/LungfishCore/Bundles/ReferenceBundleBuilder.swift` copies a BigWig to `tracks/<id>.bw`, and no caller passes one (`Sources/LungfishCLI/Commands/GenomeSubcommand.swift`, `Sources/LungfishCLI/Commands/BundleCreateSubcommand.swift`). The test genome `TestData/TestGenome.lungfishref` holds a BigWig at `tracks/gc_content.bw`.

Three code paths find or make a reference bundle by name rather than through the sidebar. The Viral Recon viewport opens the `.lungfishref` that a Viral Recon analysis folder holds, whose manifest registers the run's BAM, and `ViralReconAnalysisBundleLocator` in `Sources/LungfishApp/Views/MainWindow/ViralReconAnalysisBundleLocator.swift` takes the first one by name with an exact, lowercase extension compare. A mapping makes a viewer bundle with `MappingViewerBundlePreparer` in `Sources/LungfishWorkflow/Mapping/MappingViewerBundlePreparer.swift`, which copies the files the source manifest names into a new bundle, sets `origin_bundle_path` to the source and starts with no alignments. A raw ONT genotyping BAM opens the sibling `<stem>.mapped.lungfishref` or `<stem>.retained-demux.lungfishref` (`Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift`).

## View state

`.viewstate.json` holds what the viewer last showed, as a `BundleViewState` defined in `Sources/LungfishCore/Bundles/BundleViewState.swift`. It is declared app state (plan decision S11) and the registry lists it as the reference kind's only app state file. Its name is hidden, so `ProvenanceFileHasher.directoryManifest` in `Sources/LungfishWorkflow/Provenance/ProvenanceFileHasher.swift` skips it and no checksum or record covers it.

The file holds annotation colors, row height and spacing, which annotation and variant types show, the two filter texts, the hidden variant tracks, the genotype sample display, the translation color scheme, RNA mode, and the last chromosome, origin and scale. It is written with pretty printing and sorted keys by a Foundation atomic write, and a read-only bundle is skipped without an error. A file that is missing or cannot be decoded loads as the default state. Seven keys are required when the file decodes and the other ten are optional, which the type calls backward-compatible decoding.

The viewer writes the file only after a user change (lane B3). `ViewerViewController+BundleDisplay.swift` in `Sources/LungfishApp/Views/Viewer` marks the state it restores with `markRestored()`, and `saveUnlessRestored(to:)` writes nothing while the state still equals it, so showing a bundle with no input changes no byte. An alignment or tree bundle also holds a `.viewstate.json`, but that file is not app state, as [bundle-kinds.md](bundle-kinds.md) explains.

## Provenance

A reference bundle follows the standard record rule of [bundle-kinds.md](bundle-kinds.md). `ProvenanceWriter.write(_:to:)` in `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift` writes the root record `.lungfish-provenance.json` and, because the folder extension starts with `lungfish`, a `provenance` folder. It holds `bundle.lungfish-provenance.json`, a roll-up of the bundle's outputs, and one record for each output under the output's own path inside the bundle. The writer skips folders, files under `provenance/` and the record, signing and app state files that the record rule of [bundle-kinds.md](bundle-kinds.md) keeps out of the outputs, writes no output records when more than 100 outputs remain, and removes output records that it wrote earlier and that no output now needs.

A bundle record that lists `manifest.json` among its outputs gives the bundle `provenance/manifest.json.lungfish-provenance.json`, as the demo's reference bundle shows. The rule for new writes keeps that record, because the manifest decides which BAM and VCF tracks the bundle shows (plan decision V10). The import saves the manifest into its staging folder before it builds the output records from that folder, so the digest that the record gives `manifest.json` is the digest of the published bytes. The demo bundle carries records for its genome, annotation and record store files in the same way.

Some operations keep records of their own inside the bundle, and the finder in `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder+SidecarLookup.swift` reads each of them.

| Record | Written by |
| --- | --- |
| `<file>.lungfish-provenance.json` beside a file | Any writer of a single file record (`ProvenanceRecorder.fileSidecarURL`) |
| `variants/<track>.lungfish-provenance.json` | `BundleVariantTrackAttachmentService` |
| `<bam stem>.primer-trim-provenance.json` | `BAMPrimerTrimPipeline` in `Sources/LungfishWorkflow/Primers/BAMPrimerTrimPipeline.swift`, read by `PrimerTrimProvenanceLoader.swift` beside it |
| `<bam stem>.adopt-mapping-provenance.json` | `lungfish-cli bam adopt-mapping`, in `Sources/LungfishCLI/Commands/BAMAdoptMappingSubcommand.swift` |
| `annotations/manual-annotation-provenance.json` | `ReferenceBundleManualAnnotationService` in `Sources/LungfishWorkflow/SequenceAnnotation/ReferenceBundleManualAnnotationService.swift` |

A mapping result folder keeps `mapping-provenance.json` (`MappingProvenance.filename` in `Sources/LungfishWorkflow/Mapping/MappingProvenance.swift`), and the finder reads it for a mapping output. For a selected bundle folder the finder first returns the one operation record under `variants`, `annotations` or `alignments` when exactly one of them names an output in the bundle. Otherwise it tries the root record, then `provenance/bundle.lungfish-provenance.json`, then other root files whose names end in `-provenance.json`, then the operation records it knows by name, such as `annotations/manual-annotation-provenance.json`, and then `mapping-provenance.json`. Finding and reading a record never writes into the project, as [RECORDING-PROVENANCE.md](../contracts/RECORDING-PROVENANCE.md) requires.
