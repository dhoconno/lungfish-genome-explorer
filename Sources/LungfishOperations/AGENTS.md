# LungfishOperations

Paths were checked at the Phase 2.9 lane A14 head. When a path has moved, search for the named symbol.

## Purpose

The UI-free services that LungfishApp calls to change or read a project. It holds 69 files. 67 moved out of `Sources/LungfishApp/Services` in Phase 2.9 with no change of logic. The other two hold code that the moved files call and that sat in files which stay in LungfishApp, `FASTQDerivativeService+FastpRun.swift` (the fastp run functions from `FASTQDerivativeService+FastpTrim.swift`) and `VariantChromosomeLookupKey.swift` (one function from `Views/Viewer/VariantChromosomeHelpers.swift`). Each file names no AppKit, SwiftUI, LungfishKit or LungfishApp type, so it builds on Core, IO and Workflow alone. New logic that the CLI must also run still belongs in LungfishWorkflow. This module is the home for App-side services that are not UI and that the CLI does not run.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow and system frameworks that carry no UI (Foundation, Darwin, os, CryptoKit, SQLite3, CoreServices, Observation). Never LungfishKit, a leaf UI module, LungfishApp, LungfishCLI, AppKit or SwiftUI. Among the source modules only LungfishApp imports this module. LungfishOperationsTests, LungfishAppTests and LungfishAppViewTests import it with `@testable`. LungfishCLI never imports it.

## What lives here

| Area | Types and files |
|---|---|
| FASTQ derivatives and statistics | `FASTQDerivativeService` and its `+BBTools`, `+HumanScrub`, `+Materialization`, `+MixedOutput`, `+RecipePipeline`, `+SubsetHelpers` and `+TrimExtraction` files, `FASTQBundleMergeService`, `FASTQStatisticsService`, `FASTQAutoBundleWorkflow`, `FASTQOperationProvenanceRehydrator`, `FASTQOperationStagingCleanup` |
| Bundle browsing and merging | `BundleBrowserLoader`, `BundleBrowserMirrorStore`, `BundleDataProvider`, `BundleMergeProvenance`, `BundleSequenceSummarySynthesizer`, `ReadAnnotationProvider` |
| Annotations | `AnnotationSearchIndex`, `AnnotationExportService`, `MSAExtractionAnnotationProvenance`. `ReferenceBundleManualAnnotationService` moved down to `Sources/LungfishWorkflow/SequenceAnnotation/` in Phase 2.10, where `lungfish-cli` reaches it |
| Variants | `VariantSampleMetadataMutationService`, `VariantFormatOverlay`, `VariantTableExportResolverSnapshot`, `BookmarkedVariantExportService`. `VariantDeletionMutationService`, `VariantSampleMetadataImportService` and the `VariantMutationPublication` they share moved down to `Sources/LungfishWorkflow/Variants/` in Phase 2.10, where `lungfish-cli` reaches them. `VariantSampleMetadataMutationService` still builds the publication through its `package` access |
| Project files and search | `FileSystemWatcher`, `ProjectFilesystemRefreshCoordinator`, `ProjectDeletionPlanner`, `UniversalProjectSearchService`, `SidebarRefreshScheduler`, `SidebarSearchScheduler`, `NativeProjectCopyImportService`, `ProvenanceAwareAttachmentImporter`, `ProvenancePathRehydrator` |
| Helper processes | `BAMImportHelperClient`, `MetagenomicsImportHelperClient` |
| AI assistant | `AI/AIAssistantService`, `AI/AIToolRegistry`, `AI/AICredentialFields`, `AI/AICredentialPersistence` |

## Access rule

A moved type or member that LungfishApp uses takes `package` access, so nothing outside the package can reach it, and no move adds a `public` declaration. Declarations that were already `public` when they sat in LungfishApp keep that access, so the module map lists them under LungfishOperations instead of LungfishApp and the package gains no public type. A declaration that only the module's own tests use stays internal, and the test file imports the module with `@testable`.

## Where a service stays in LungfishApp

A service stays in `Sources/LungfishApp/Services` when it names `OperationCenter`, a view model, a view controller or a type declared in `Sources/LungfishApp/Views`. The types that hold the most services back are in `Views/FASTQ/FASTQOperationDialogState.swift` (`FASTQOperationLaunchRequest`, `FASTQOperationToolID`, `FASTQOperationOutputMode`) and in `Views/Sidebar` (`SidebarItem`, `SidebarProjectScanner`). Move those model types first when a service needs to come here.

## Tests

Target LungfishOperationsTests in Tests/LungfishOperationsTests. Run only it with `swift test --skip-update --filter LungfishOperationsTests`. The test catalog (`config/test-catalog.json`) lists the target in the `ui-diagnostics` collection and excludes it from every other collection, the same as LungfishAppTests, so each moved class runs in the profiles it ran in before. A test that needs a shared helper which stays in LungfishAppTests, such as `FASTQOperationTestHelper`, stays there too.

## Known traps

| Trap | Evidence |
|---|---|
| The target has no resources, so `Bundle.module` does not exist here. A service that needs a bundle takes it as a parameter or uses `RuntimeResourceLocator` | `BuiltInPrimerSchemeService.listBuiltInSchemes(in:)`, `Tests/LungfishOperationsTests/PrimerTrim/BuiltInPrimerSchemeServiceTests.swift` |
| `MetagenomicsBatchResultStore.swift` holds internal aliases for Workflow types. A LungfishApp file that names one of them imports LungfishWorkflow and gets the Workflow type | `Sources/LungfishOperations/MetagenomicsBatchResultStore.swift` |
| `waitUntil` in the test target is a copy of the one in `Tests/LungfishAppTests/AssemblyViewportTestSupport.swift`. Keep the two in step | `Tests/LungfishOperationsTests/WaitUntil.swift` |
| `NativeToolRunner` is still named in `FASTQBundleMergeService+Join.swift`, `FASTQDerivativeService.swift` and `FASTQStatisticsService.swift`. The `native-tool-runner-in-app` ratchet counts only LungfishApp, so these three no longer count | `scripts/ratchets/native-tool-runner-in-app.sh` |
