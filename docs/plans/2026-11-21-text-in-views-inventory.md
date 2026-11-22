# Text in views, the ranked inventory (sub-phase 5.6)

**Status:** active. This is the full ranked table of `docs/plans/2026-11-21-text-in-views.md`, read at base `c2612e446`. UX's script (`~/lungfish-phase-records/ux-text/scratch/UX/inventory.py`) counts the in-view words of every surface's Swift literals, all states summed, and classes words behind help tags, for VoiceOver only, and in alerts and errors apart (`~/lungfish-phase-records/ux-text/inv/UX-INVENTORY.md:5-23`). "Prose" is an in-view literal of 8 words or more. The longest line is the surface's longest prose literal, from `scratch/UX/out/prose-literals.tsv`. A surface's count holds every word its files can show, not what one state shows.

"No lane, not met" means no walk and no owner met the surface's words, so the work does not earn a lane (`docs/contracts/SCOPE-AND-DELIVERY.md:58`), its words alone are S4 (`:79`), and the rule of 5.6 U1 binds the next lane that edits the file.

## Viewports, dialogs and Inspector tabs

| Rank | Surface | Prose words | Longest line | Lane, or no lane and why |
|---:|---|---:|---|---|
| 1 | FASTQ/FASTA Operations dialog | 1,715 | `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState+ChanceCaption.swift:109` | TV-SHELL (sections, every tool) and TV-DEMUX (the demultiplex pane). Other tools' captions: no lane, not met |
| 2 | Inspector shell | 990 | `Sources/LungfishApp/Views/Inspector/InspectorViewController+TrimDuplicateWorkflows.swift:334` | no lane: launch refusals and alerts, which stay (UX 8) |
| 3 | Import Center | 831 | `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel+ActionText.swift:40` | no lane, not met. The same 27-word action text shows twice (`ImportCenterViewModel+RNASeqLinuxCards.swift:37`) |
| 4 | Workflow Operations dialog | 777 | `Sources/LungfishApp/Views/WorkflowOperations/RNASeqWorkflowPanes.swift:33` | TV-SHELL (sections) and TV-PSEUDOBULK (pseudobulk pane and cards). The cell map import pane (`:25-33`): no lane, not met, and `:33` stays bound to C5 |
| 5 | Genotype result | 656 | `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:3698` | no lane: outcomes of one result, which are exceptional and stay |
| 6 | Primer design dialog | 631 | `Sources/LungfishApp/Views/PrimerDesign/PrimerDesignDialog.swift:243` | TV-SHELL reaches its readiness line. Its general rules (`:134`, `:243`) fit popovers: no lane, not met |
| 7 | Viewer | 615 | `Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift:235` | no lane: failure and repair words (UX 8) |
| 8 | Sequence viewer | 506 | `Sources/LungfishApp/Views/Viewer/SequenceViewerView+ExtractionRefusals.swift:76` | no lane: refusals (UX 8) |
| 9 | Main split | 505 | `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:1036` | no lane: failure words (UX 8) |
| 10 | Inspector, ReadStyle section | 496 | `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection+ReadTotals.swift:87` | no lane, not met. BIO has not rated whether its count caveats (`:85`, `:87`) are exceptional |
| 11 | RNA-seq plan sheet model | 470 | `Sources/LungfishApp/Views/ImportCenter/RNASeqPlanSheetModel.swift:87` | no lane, not met: provenance lines in a sheet |
| 12 | Cell map view | 461 | `Sources/LungfishRNASeqUI/CellMap/RNASeqEmbeddingWords.swift:39` | TV-CELLMAP, with TV-INSPECT for the fact lines |
| 13 | BLAST search pane | 366 | `Sources/LungfishKit/BlastSearchPaneState.swift:113` | no lane, not met |
| 14 | Inspector, Provenance tab | 365 | `Sources/LungfishApp/Views/Inspector/ProvenanceInspectorViewModel+NodeRuntime.swift:32` | TV-INSPECT adds the cell map's provenance there, with no word change |
| 15 | Sidebar | 324 | `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift:294` | no lane, not met |
| 16 | Reference results | 306 | `Sources/LungfishApp/Views/Results/Reference/ReferenceBundleViewportController+MappingRows.swift:183` | no lane, not met |
| 17 | NAO-MGS result | 294 | `Sources/LungfishNaoMgsUI/NaoMgsResultViewController+StrandFixNote.swift:48` | no lane: a note exceptional for the results it names |
| 18 | FASTQ dataset view | 257 | `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift:1010` | no lane, not met |
| 19 | Storage settings | 249 | `Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift:221` | no lane, not met |
| 20 | IQ-TREE dialog | 233 | `Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialogState.swift:116` | TV-SHELL keeps its one readiness line (its in-pane one is already gone) and writes "Branch Support" in sentence case (`IQTreeInferenceDialog.swift:176`, 5.6 U4). Captions: no lane, not met |
| 21 | Welcome window | 231 | `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift:1284` | no lane, not met |
| 22 | Classifier result actions | 225 | `Sources/LungfishKit/Classifiers/ClassifierResultActions.swift:78` | no lane, not met |
| 23 | Genotype display section | 216 | `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift:789` | no lane, not met |
| 24 | FASTQ metadata drawer | 171 | `Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift:190` | no lane, not met |
| 25 | Operations panel | 164 | `Sources/LungfishApp/Views/Operations/OperationsPanelFailureReports.swift:15` | no lane: failure words (UX 8) |
| 26 | FASTQ import sheet | 158 | `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift:134` | no lane, not met |
| 27 | Project storage sheet | 157 | `Sources/LungfishApp/Views/ProjectStorage/ProjectStorageSheetViewModel.swift:204` | no lane, not met |
| 28 | Single-cell result view | 154 | `Sources/LungfishRNASeqUI/SingleCell/RNASeqSingleCellSummary.swift:26` | TV-SCVIEW (walk shot a-B3) |
| 29 | ViralRecon wizard | 149 | `Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift:833` | TV-SHELL drops its Readiness when embedded in the dialog (`:211`). Captions: no lane, not met |
| 30 | Primer binding inspection | 148 | `Sources/LungfishApp/Views/PrimerAnalysis/PrimerBindingInspectionView.swift:83` | no lane, not met |
| 31 | Primer design dialog state | 146 | `Sources/LungfishApp/Views/PrimerDesign/PrimerDesignDialogState+Grouping.swift:15` | no lane, not met |
| 32 | RNA-seq plan sheet | 146 | `Sources/LungfishApp/Views/ImportCenter/RNASeqPlanSheet.swift:268` | no lane, not met |
| 33 | Primer order export | 145 | `Sources/LungfishApp/Views/PrimerAnalysis/PrimerOrderExportView.swift:126` | no lane, not met |
| 34 | Annotation table drawer | 139 | `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+ExportUI.swift:56` | no lane, not met |
| 35 | RNA-seq import sheet | 135 | `Sources/LungfishApp/Views/ImportCenter/RNASeqImportSheetModel.swift:179` | no lane, not met |
| 36 | Inspector, MSA discriminating sites | 132 | `Sources/LungfishApp/Views/Inspector/Sections/MSADiscriminatingSitesSection.swift:20` | no lane, not met |
| 37 | Mapping wizard | 130 | `Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift:384` | TV-SHELL writes its section heading in sentence case (`:215`, 5.6 U4). Captions: no lane, not met |
| 38 | Primer scheme advanced options | 129 | `Sources/LungfishApp/Views/PrimerDesign/PrimerSchemeAdvancedOptionsView.swift:39` | no lane, not met |
| 39 | Genotype call evidence | 123 | `Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift:551` | no lane, not met |
| 40 | Primer order result | 119 | `Sources/LungfishApp/Views/PrimerAnalysis/PrimerOrderResultView.swift:92` | no lane, not met |
| 41 | EsViritu wizard | 117 | `Sources/LungfishApp/Views/Metagenomics/EsVirituWizardSheet.swift:36` | no lane, not met |
| 42 | Genotype comparison matrix | 115 | `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:2438` | no lane, not met |
| 43 | TaxTriage confidence cell | 114 | `Sources/LungfishTaxTriageUI/TaxTriageConfidenceCellView.swift:57` | no lane, not met |
| 44 | BLAST results drawer | 111 | `Sources/LungfishKit/BlastResultsDrawerTab+Waiting.swift:116` | no lane, not met |
| 45 | Genotype sample comparison | 111 | `Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift:177` | no lane, not met |
| none | Inspector Bundle tab on an RNA-seq result | 12 | `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift:1614-1617` | TV-INSPECT (walk shots a-B1 and a-B3) |
| none | Bulk RNA-seq view | 58 | `Sources/LungfishRNASeqUI/Bulk/RNASeqBulkViewController.swift:235,257` | TV-SCVIEW |

## Words that show only on an outcome

These are failures, refusals, alerts and operation rows. They are exceptional for their result by definition and stay in view (UX 8), so no lane moves them. A lane may still make one shorter if it already edits the file (`SCOPE-AND-DELIVERY.md:105`).

| Rank | Surface | Prose words | Longest line |
|---:|---|---:|---|
| 1 | App delegate alerts and rows | 2,122 | `Sources/LungfishApp/App/AppDelegate+TaxTriageCLIRoute.swift:149` |
| 2 | Viewer failure reports | 623 | `Sources/LungfishApp/Views/Viewer/ViewerFailureReports+Drawers.swift:82` |
| 3 | Main window failure reports | 537 | `Sources/LungfishApp/Views/MainWindow/MainWindowFailureReports+ClassifierResults.swift:54` |
| 4 | Viewer refusal words | 346 | `Sources/LungfishApp/Views/Viewer/ViewerRefusalWords.swift:103` |
| 5 | Genotype failure reports | 330 | `Sources/LungfishGenotypeUI/GenotypeFailureReports.swift:32` |
| 6 | Sidebar failure reports | 241 | `Sources/LungfishApp/Views/Sidebar/SidebarFailureReports+Merge.swift:27` |
| 7 | Assembly failure reports | 240 | `Sources/LungfishAssemblyUI/AssemblyFailureReports.swift:53` |
| 8 | Workflow library | 196 | `Sources/LungfishApp/Services/WorkflowLibrary.swift:147`, a card subtitle that TV-PSEUDOBULK makes one line |
| 9 | Cell map import run | 187 | `Sources/LungfishApp/Services/RNASeqCellMapImportRun.swift:47` |
| 10 | LGE zip import resolver | 169 | `Sources/LungfishApp/Services/LGEZipImportResolver.swift:34` |
| 11 | Operation failure issue reporter | 149 | `Sources/LungfishApp/Services/OperationFailureIssueReporter.swift:168` |
| 12 | FASTQ operation output importer | 139 | `Sources/LungfishApp/Services/FASTQOperationOutputImporter+ReadRoles.swift:106` |
| none | Exact Bare refusal | 25 | `Sources/LungfishWorkflow/Demultiplex/DemultiplexError.swift:157-158`, which TV-DEMUX rewords (BIO-EXACT-BARE-RC item 3) |

All 524 surfaces: 55,919 words in view, 29,014 of them in prose lines, 5,338 behind help tags and 1,269 for VoiceOver only (`~/lungfish-phase-records/ux-text/inv/UX-INVENTORY.md:117`).
