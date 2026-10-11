# Bundle kinds

A Lungfish Genome Explorer (LGE) project is a `.lungfish` folder, and most of what it holds are folders whose extension names their kind, such as a `.lungfishref` reference bundle. This page lists the 15 kinds that `BundleKindRegistry` knows, the facts the app applies to each, and the rule for provenance record names in new writes. It is written for developers. Every value in the tables below is in `Sources/LungfishIO/Bundles/BundleKindRegistry.swift`, and the types are in `Sources/LungfishIO/Bundles/BundleKind.swift`.

The layouts of the two kinds a user meets most are in [reference-bundle.md](reference-bundle.md) and [fastq-bundle.md](fastq-bundle.md). The `Analyses/` folder, which holds analysis results rather than one kind, is in [analyses-layout.md](analyses-layout.md).

## The registry

`BundleKindRegistry.all` holds one `BundleKindDescriptor` for each kind, in the order of the Phase 2.6 inventory. A kind is named by a `BundleKindID`, a string-backed struct with kebab-case raw values such as `reference` and `phylogenetic-tree`. An id from a newer build decodes and finds no descriptor, so an older reader keeps the artifact instead of dropping it (plan decision S9, `BundleKind.swift`). The descriptor initializer has no default values, so a new kind has to state every fact.

A descriptor changes no behavior until a caller reads it. Since lane B7 the deletion planner reads the deletion fact (`Sources/LungfishApp/Services/ProjectDeletionPlanner.swift`) and the cross-project copier reads the refused copy policy (`Sources/LungfishApp/Services/CrossProjectItemCopier.swift`). `Sources/LungfishIO/Registry/FileTypeUtility.swift`, `Sources/LungfishApp/App/DocumentType.swift`, `Sources/LungfishApp/Services/CLIMSAActionRunner.swift` and `Sources/LungfishApp/App/AppFilePanelFactory.swift` take folder extensions from it, and `CLIEventArtifact.bundleKind` reads it in `Sources/LungfishWorkflow/CLIEvents/CLIEventLine.swift`.

Other tables still decide a kind on their own. The sidebar uses `SidebarProjectScanner.bundleClassification` in `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift` and the tables in `Sources/LungfishApp/Views/Sidebar/SidebarItem.swift`, and it moves to the registry in 2.9 (plan decision S21). `ProvenanceCoverageMonitor` in `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel.swift`, `FormatIdentifier` in `Sources/LungfishIO/Registry/FormatIdentifier.swift` and `ProvenanceWriter.isBundleDirectory` in `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift` keep their own rules too. `BundleKindParityTests` in `Tests/LungfishAppTests/SafetyNets/BundleKindParityTests.swift` freezes what each of these tables answers and fails when an answer moves, so a caller that converts to the registry must keep its old answer.

## Extension, manifest and recognition

| Kind id | Folder extension | Manifest | Recognition | UTType |
| --- | --- | --- | --- | --- |
| `project` | `lungfish` | `metadata.json` | Extension | None |
| `reference` | `lungfishref` | `manifest.json` | Extension | `org.lungfish.reference-bundle` |
| `fastq` | `lungfishfastq` | None | Extension | None |
| `multiple-sequence-alignment` | `lungfishmsa` | `manifest.json` | Extension | `org.lungfish.msa-bundle` |
| `phylogenetic-tree` | `lungfishtree` | `manifest.json` | Extension | `org.lungfish.tree-bundle` |
| `primer-scheme` | `lungfishprimers` | `manifest.json` | Extension | None |
| `primer-analysis` | `lungfishprimeranalysis` | `manifest.json` | Extension | `org.lungfish.primer-analysis` |
| `mhc-reference` | `lungfishmhcref` | `mhc-reference.json` | Extension and manifest | `org.lungfish.mhc-reference-bundle` |
| `genotype-result` | `lungfishgenotype` | `genotype-result.json` | Extension | None |
| `12s-result` | `lungfish12s` | `12s-result.json` | Extension | None |
| `12s-reference` | `lungfish12sref` | `12s-reference.json` | Extension and manifest | None |
| `cz-id-result` | `lungfishtax` | `cz-id-manifest.json` | Extension and manifest | None |
| `workflow-run` | `lungfishrun` | `manifest.json` | Extension | None |
| `workflow-bundle` | `lungfishflow` | None | Extension | `org.lungfish.workflow` |
| `workflow-package` | `lungfishflowpkg` | `manifest.json` | Extension | None |

A folder extension is lowercase, has no dot and is unique across the registry. A FASTQ bundle has no single manifest, and its files are in [fastq-bundle.md](fastq-bundle.md). The retired `.lungfishflow` kind has none either, and nothing creates it, but `Lungfish-Info.plist` still declares its type. The UTType column is what `Lungfish-Info.plist` declares for the extension, and no Swift file declares a UTType.

The names are declared as typed constants, and two test classes tie the registry to them. `BundleKindRegistryTests` in `Tests/LungfishIOTests/Bundles/BundleKindRegistryTests.swift` checks the Core and IO constants and the Info.plist types. `BundleKindAgreementTests` in `Tests/LungfishWorkflowTests/BundleKindAgreementTests.swift` checks the Workflow constants.

| Constant | File |
| --- | --- |
| `ProjectFile.fileExtension` | `Sources/LungfishCore/Storage/ProjectFile.swift` |
| `BundleManifest.filename` | `Sources/LungfishCore/Bundles/BundleManifest.swift` |
| `FASTQBundle.directoryExtension` | `Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift` |
| `MultipleSequenceAlignmentBundle.directoryExtension` | `Sources/LungfishIO/Bundles/MultipleSequenceAlignmentBundle.swift` |
| `PrimerAnalysisManifest.filename` | `Sources/LungfishIO/Bundles/PrimerAnalysisManifest.swift` |
| `MHCAmpliconReferenceBundle.directoryExtension` and `MHCAmpliconReferenceBundleManifest.manifestFilename` | `Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift` |
| `ONTGenotypeResultBundle.directoryExtension` | `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift` |
| `ONTGenotypeResultBundleManifest.filename` | `Sources/LungfishIO/Bundles/ONTGenotypeResultBundleManifest.swift` |
| `TwelveSAmpliconResultBundle.directoryExtension` | `Sources/LungfishIO/Bundles/TwelveSAmpliconResultBundle.swift` |
| `TwelveSAmpliconResultBundleManifest.filename` | `Sources/LungfishIO/Bundles/TwelveSAmpliconResultModels.swift` |
| `TwelveSReferenceBundle.directoryExtension` and `TwelveSReferenceBundleManifest.manifestFilename` | `Sources/LungfishIO/Bundles/TwelveSReferenceBundle.swift` |
| `NFCoreRunBundleStore.directoryExtension` | `Sources/LungfishWorkflow/nf-core/NFCoreRunBundleManifest.swift` |
| `WorkflowPackageValidator.packageExtension` and `manifestFilename` | `Sources/LungfishWorkflow/WorkflowPackages/WorkflowPackageManifest.swift` |
| `CrossProjectItemCopier.ItemKind.workflowBundleExtension` | `Sources/LungfishApp/Services/CrossProjectItemCopier.swift` |

The tree, primer scheme and CZ ID kinds have no typed name constant. `PhylogeneticTreeBundle.swift` writes the tree manifest with `bundleKind` set to `phylogenetic-tree`, `PrimerSchemeBundle.swift` loads `manifest.json` and refuses a scheme without `PROVENANCE.md`, and `CzIdDataConverter.swift` in `Sources/LungfishWorkflow/Metagenomics/CzId` writes `cz-id-manifest.json`.

Recognition says what a reader needs before it accepts a folder as the kind. Twelve kinds need the extension alone. For the MHC reference, the 12S reference and the CZ ID import at least one reader also needs the manifest, and `recognizedKind(at:)` returns those three kinds only when the manifest exists. It is the only lookup in the registry that reads the file system (`BundleKindRegistry.swift`). The sidebar still classifies an MHC reference by extension alone, so a caller keeps its own rule until its lane converts it.

### Extension case

The registry has two lookups by extension (plan decision V9). `descriptor(forExactExtension:)` keeps the answer of a site that compares case-sensitively, so `LUNGFISHREF` finds nothing. `descriptor(forLowercasedExtension:)` keeps the answer of a site that lowercases first, so `LungfishRef` finds the reference kind. A converted site keeps its own case rule until a reviewed change says otherwise.

## Sidebar, deletion and copy

| Kind id | Sidebar | Symbol | Deletion | Copy to another project |
| --- | --- | --- | --- | --- |
| `project` | The root, or walked when nested | `folder.badge.gearshape` | Not one object | Refused |
| `reference` | One row | `cylinder.split.1x2` | One object | `Reference Sequences` |
| `fastq` | One row | `doc.text` | One object | `Imports` |
| `multiple-sequence-alignment` | One row | `rectangle.grid.1x2` | One object | `Analyses/Multiple Sequence Alignments` |
| `phylogenetic-tree` | One row | `point.3.connected.trianglepath.dotted` | One object | `Phylogenetic Trees` |
| `primer-scheme` | One row | `line.horizontal.3.decrease.circle` | One object | `Primer Schemes` |
| `primer-analysis` | One row | `list.bullet.rectangle` | One object | `Analyses` |
| `mhc-reference` | One row | `cylinder.split.1x2` | One object | Refused |
| `genotype-result` | One row | `tablecells.badge.ellipsis` | One object | `Analyses`, and it must stay there |
| `12s-result` | One row | `tablecells` | One object | `Analyses` |
| `12s-reference` | Walked | `shippingbox` | One object | The project root |
| `cz-id-result` | One row | `c.circle` | One object | `Classifications` |
| `workflow-run` | Hidden | `shippingbox` | Not one object | The project root |
| `workflow-bundle` | Walked | `shippingbox` | Not one object | `Workflows` |
| `workflow-package` | Walked | `shippingbox` | Not one object | Refused |

A kind shown as one row has its own viewport or preview, and the sidebar never lists the files inside it. A walked kind has no viewport, so the sidebar shows a document row and lists its children (plan decision S10). The `.lungfish12sref` kind is its own kind and not a genome reference, and `FileTypeUtility` stopped calling it a reference bundle in lane B7. A `.lungfishtax` folder without `cz-id-manifest.json` is a walked document row, and the copier treats it as another native bundle that lands in the project root. A run bundle is a working artifact of a pipeline, and the sidebar hides it by its lowercase extension only. These rules are in the comments and values of `BundleKindRegistry.swift`.

Deletion as one object means that `ProjectDeletionPlanner` treats the folder as a single project object and never lists the files inside it. The planner also treats a folder that holds one of its marker files, such as `analysis-metadata.json` or `classification-result.json`, as one object, and it removes the `<name>.lungfish-meta.json` and `<name>.lungfish-provenance.json` files beside a deleted item (`ProjectDeletionPlanner.swift`).

The copy column is the folder of the target project where `CrossProjectItemCopier` lands an item when the source gives no hint. A refused kind has its own import path or cannot be copied. A genotype result must live under `Analyses/`, so the copier moves it there. The folder names `Reference Sequences`, `Primer Schemes` and `Analyses` are the constants `ReferenceSequenceFolder.folderName`, `PrimerSchemesFolder.folderName` and `AnalysesFolder.directoryName` in `Sources/LungfishIO/Bundles`.

## Records, app state and producers

| Kind id | Record names | App state | Produced by |
| --- | --- | --- | --- |
| `multiple-sequence-alignment` | Frozen. A root `.lungfish-provenance.json` in the bundle's own schema | None | `mafft` |
| `phylogenetic-tree` | Frozen. A root `.lungfish-provenance.json` in the bundle's own schema | None | None |
| `primer-scheme` | Frozen. `PROVENANCE.md` | None | None |
| `primer-analysis` | Frozen. `provenance/wrapper.json` | None | None |
| `reference` | The standard rule | `.viewstate.json` | None |
| `genotype-result` | The standard rule | `.genotype-viewstate.json` | `ont-genotyping` |
| `cz-id-result` | The standard rule | None | `cz-id` |
| The other eight kinds | The standard rule | None | None |

The standard rule is `SidecarNaming.rootRecordAndProvenanceFolder`. A bundle has a root record named `.lungfish-provenance.json`, which is `ProvenanceWriter.provenanceFilename`, and a `provenance` folder, which is `ProvenanceWriter.bundleProvenanceDirectoryName`. `BundleKindAgreementTests` checks that the registry and the writer agree on both names. The writer puts a roll-up record named `bundle.lungfish-provenance.json` in that folder, and one record for each output under the output's own path inside the bundle, such as `provenance/genome/sequence.fa.gz.lungfish-provenance.json` (`ProvenanceWriter.swift`). [RECORDING-PROVENANCE.md](../contracts/RECORDING-PROVENANCE.md) says what a record holds and which code writes one.

The four frozen formats keep their own record names, and the rule for new writes below never applies to them. An alignment also writes `metadata/annotation-edit-provenance.json` after an annotation edit (`BundleKindRegistry.swift`).

App state is a file inside the bundle that holds viewer settings rather than scientific data (plan decision S11). Two kinds declare one, the reference kind's `.viewstate.json` ([reference-bundle.md](reference-bundle.md)) and the genotype result kind's `.genotype-viewstate.json` (`Sources/LungfishIO/Bundles/GenotypeResultViewState.swift`), each outside every checksum and record and written only after a user change. An alignment or tree bundle also holds a `.viewstate.json`, but its creation writes it and its manifest checksums cover it, so it is not app state (`MultipleSequenceAlignmentBundle.swift`, `PhylogeneticTreeBundle.swift`).

The produced by column lists the analyses whose sidebar row is a folder of the kind, and every id it names must exist in `AnalysisToolRegistry`, which `BundleKindAgreementTests` checks. The join runs one way, from the bundle kind to the analysis. Viral Recon and mapping results show as generic analysis rows, so the reference kind names no producer. The genotyping pipeline names its result folder `illumina-amplicon-genotyping` or `ont-sample-bundle-genotyping` in its other two modes (`Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`), and lane B56 added both ids to the analysis registry. `SidebarProjectScanner.analysisItemType` gives the genotype row type to `ont-genotyping` alone, so the genotype kind lists only that id.

## The record name rule for new writes

Plan decision V10 sets one rule for every kind under the standard rule. It is written into `SidecarNaming.rootRecordAndProvenanceFolder` in `BundleKind.swift`, and a new writer follows it:

- A record file is never an output, so no record of a record is written.
- An app cache is never an output.
- A manifest stays an output of its bundle record, because a reference manifest decides which BAM and VCF tracks the bundle shows.

Phase 2.6 enforced the first part where walk F6 found a record of a record. `TwelveSReferenceBundleBuilder.bundleOutputDescriptors` in `Sources/LungfishWorkflow/TwelveS/TwelveSReferenceBundleBuilder.swift` now leaves every file whose name ends in `.lungfish-provenance.json` out of the outputs, where the layout had written `provenance/target-metadata.tsv.lungfish-provenance.json.lungfish-provenance.json`. Some older writers already leave record files out when they list a folder's files as outputs, such as `Sources/LungfishWorkflow/PBAA/PBAAClusteringPipeline.swift` and `Sources/LungfishApp/Services/FASTQOperationPlanner.swift`.

The writer itself does not filter yet. `ProvenanceWriter.writeBundleLayout` writes a record for every output inside the bundle, skipping only folders and files under `provenance/`, and it writes no output records at all when there are more than 100, `maximumBundleOutputSidecars` (`ProvenanceWriter.swift`). A writer-wide filter is planned for wave 4 or sub-phase 2.7. Bundles written before the rule keep the records they have. In the committed MHC demo (`Tests/Fixtures/demo-projects/lge-demo-mhc-genotyping-2026.9.58.zip`) the project's reference bundle carries `provenance/manifest.json.lungfish-provenance.json`, which the rule keeps, and both FASTQ bundles carry a record of their `.lungfish-meta.json`. `<reads>.lungfish-meta.json` is a scientific sidecar that recorded digests cover, not an app cache, so it stays an output and the writer-wide filter keeps its record.

## Names that are not kinds

`WorkflowPackageBundleType` in `Sources/LungfishWorkflow/WorkflowPackages/WorkflowPackageManifest.swift` lists `lungfishbam`, `lungfishvcf` and `lungfishproject`, which nothing creates. Package manifests store its raw values, so they stay, and `BundleKindAgreementTests` pins that none of them is a registry kind. `.lungfishhaplotypedef.json` is the suffix of a haplotype definition file, not a folder kind (`Sources/LungfishIO/Bundles/HaplotypeDefinitionStore.swift`). No code creates a `.lungfishbundle`.

## Changing a kind

A change to a kind's folder extensions, its deletion fact or a refused copy policy changes what the converted callers do, so review it like a parity diff. Any other fact changes nothing until a caller reads it. `Sources/LungfishIO/AGENTS.md` describes the order of a conversion, one table at a time, with a reviewed diff of the files in `Tests/Fixtures/bundle-kinds`.
