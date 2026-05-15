import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishApp

@MainActor
final class SequenceMenuOperationTests: XCTestCase {
    nonisolated(unsafe) private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-sequence-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testSequenceMenuRemovesRestrictionSitesAndAddsAnnotationOperations() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let sequenceMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Sequence" }?.submenu)
        let titles = sequenceMenu.items.map(\.title)
        let toolsMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Tools" }?.submenu)
        let fastqMenu = try XCTUnwrap(toolsMenu.items.first { $0.title == "FASTQ/FASTA Operations" }?.submenu)
        let fastqTitles = fastqMenu.items.map(\.title)

        XCTAssertTrue(titles.contains("Reverse Complement\u{2026}"))
        XCTAssertTrue(titles.contains("Translate\u{2026}"))
        XCTAssertTrue(titles.contains("Go to Location\u{2026}"))
        XCTAssertTrue(titles.contains("Find ORFs\u{2026}"))
        XCTAssertFalse(titles.contains("Annotate Translations\u{2026}"))
        XCTAssertFalse(titles.contains("Find Restriction Sites..."))
        XCTAssertTrue(fastqTitles.contains("Reverse Complement\u{2026}"))
        XCTAssertTrue(fastqTitles.contains("Translate\u{2026}"))
    }

    func testORFAnnotationCommandArgumentsUseCLIBackedSequenceWorkflow() {
        let bundleURL = URL(fileURLWithPath: "/Project/Reference Sequences/example.lungfishref", isDirectory: true)
        let request = SequenceAnnotationOperationRequest(
            operation: .orf,
            bundleURL: bundleURL,
            sequenceName: "chrM",
            start: 9,
            end: 90,
            frames: ["+1", "-2"],
            codonTableID: 2,
            trackID: "orfs_chrM",
            trackName: "chrM ORFs",
            minimumORFLength: 60,
            includePartialORFs: true,
            allowAlternativeStarts: true
        )

        XCTAssertEqual(SequenceAnnotationOperationRunner.commandArguments(for: request), [
            "sequence", "annotate-orfs", bundleURL.path,
            "--sequence", "chrM",
            "--start", "9",
            "--end", "90",
            "--frames", "+1,-2",
            "--table", "2",
            "--track-id", "orfs_chrM",
            "--track-name", "chrM ORFs",
            "--min-length", "60",
            "--include-partial",
            "--allow-alternative-starts",
            "--quiet",
        ])
    }

    func testReverseComplementSelectionOperationUsesFASTQCLIInvocation() throws {
        let inputURL = URL(fileURLWithPath: "/Project/Temp/selection.lungfishfastq", isDirectory: true)
        let invocation = try FASTQOperationExecutionService().buildInvocation(
            for: .derivative(
                request: .reverseComplement,
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments, [
            "reverse-complement",
            inputURL.path,
            "-o",
            "<derived>",
        ])
    }

    func testTranslateSelectionOperationUsesFASTQCLIInvocation() throws {
        let inputURL = URL(fileURLWithPath: "/Project/Temp/selection.lungfishfastq", isDirectory: true)
        let invocation = try FASTQOperationExecutionService().buildInvocation(
            for: .derivative(
                request: .translate(frameOffset: 0),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )

        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments, [
            "translate",
            inputURL.path,
            "--frame",
            "1",
            "-o",
            "<derived>",
        ])
    }

    func testSelectedFASTAOperationInputFallsBackToIndexedReferenceBundle() throws {
        let bundleURL = try makeReferenceBundle(
            chromosomeName: "MN908947",
            sequence: "AAACCCGGGTTT"
        )
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewerController = ViewerViewController()
        viewerController.loadView()
        viewerController.referenceFrame = ReferenceFrame(
            chromosome: "MN908947.3",
            start: 3,
            end: 9,
            pixelWidth: 400,
            sequenceLength: 12
        )
        viewerController.viewerView.setReferenceBundle(bundle)
        viewerController.viewerView.selectVisibleRegion()

        let input = try viewerController.viewerView.selectedFASTAOperationInput()

        XCTAssertEqual(input.suggestedName, "MN908947_4_9")
        XCTAssertEqual(input.records, [">MN908947_4_9\nCCCGGG\n"])
    }

    func testSelectedFASTAOperationInputUsesVisibleRegionWhenNoExplicitSelectionExists() throws {
        let bundleURL = try makeReferenceBundle(
            chromosomeName: "MN908947",
            sequence: "AAACCCGGGTTT"
        )
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        let viewerController = ViewerViewController()
        viewerController.loadView()
        viewerController.referenceFrame = ReferenceFrame(
            chromosome: "MN908947.3",
            start: 3,
            end: 9,
            pixelWidth: 400,
            sequenceLength: 12
        )
        viewerController.viewerView.setReferenceBundle(bundle)
        viewerController.viewerView.clearSelection()

        let input = try viewerController.viewerView.selectedFASTAOperationInput()

        XCTAssertEqual(input.suggestedName, "MN908947_4_9")
        XCTAssertEqual(input.records, [">MN908947_4_9\nCCCGGG\n"])
    }

    func testGoToGenePrefersExactGeneNameOverSubstringMatches() {
        let appDelegate = AppDelegate()
        let results = [
            AnnotationSearchIndex.SearchResult(
                name: "id-MN908947.3:1..265",
                chromosome: "MN908947.3",
                start: 0,
                end: 265,
                trackId: "ncbi",
                type: "five_prime_UTR"
            ),
            AnnotationSearchIndex.SearchResult(
                name: "id-MN908947.3:29675..29903",
                chromosome: "MN908947.3",
                start: 29_674,
                end: 29_903,
                trackId: "ncbi",
                type: "three_prime_UTR"
            ),
            AnnotationSearchIndex.SearchResult(
                name: "M",
                chromosome: "MN908947.3",
                start: 26_522,
                end: 27_191,
                trackId: "ncbi",
                type: "gene",
                attributes: ["gene": "M"],
                annotationRowId: 11
            ),
            AnnotationSearchIndex.SearchResult(
                name: "MN908947.3:1..29903",
                chromosome: "MN908947.3",
                start: 0,
                end: 29_903,
                trackId: "ncbi",
                type: "region"
            ),
            AnnotationSearchIndex.SearchResult(
                name: "QHD43419.1",
                chromosome: "MN908947.3",
                start: 26_522,
                end: 27_191,
                trackId: "ncbi",
                type: "CDS",
                attributes: ["gene_name": "M"],
                annotationRowId: 12
            )
        ]

        let match = appDelegate.preferredGeneSearchResult(
            from: results,
            query: "M",
            currentChromosome: "MN908947"
        )

        XCTAssertEqual(match?.name, "M")
        XCTAssertEqual(match?.type, "gene")
    }

    func testSequenceAnnotationOperationCanonicalizesVersionedReferenceSequenceName() throws {
        let bundleURL = try makeReferenceBundle(
            chromosomeName: "MN908947",
            sequence: String(repeating: "A", count: 200)
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let viewerController = ViewerViewController()
        viewerController.loadView()
        viewerController.currentBundleDataProvider = BundleDataProvider(
            bundleURL: bundleURL,
            manifest: manifest
        )
        let context = SequenceAnnotationDraftContext(
            bundleURL: bundleURL,
            chromosome: "MN908947.3",
            range: 34..<171,
            sequenceLength: 200
        )

        let sequenceName = AppDelegate().sequenceAnnotationOperationSequenceName(
            for: context,
            viewerController: viewerController
        )

        XCTAssertEqual(sequenceName, "MN908947")
    }

    func testSequenceTransformMenuItemsReuseFASTQFASTAOperationsDialog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )
        let sequenceViewerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegateSource.contains("viewerView.runSelectedSequenceFASTAOperation(toolID: .reverseComplement)"))
        XCTAssertTrue(appDelegateSource.contains("viewerView.runSelectedSequenceFASTAOperation(toolID: .translate)"))
        XCTAssertTrue(sequenceViewerSource.contains("presentFASTAOperationDialog("))
    }

    func testFindORFsPreflightsBundleOperationLockBeforeRunning() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegateSource.contains("OperationCenter.shared.canStartOperation(on: context.bundleURL)"))
        XCTAssertTrue(appDelegateSource.contains("activeLockHolder(for: context.bundleURL)"))
    }

    func testFindORFsUsesSharedOperationsDialogShell() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )
        let dialogSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Sequence/SequenceORFOperationDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegateSource.contains("SequenceORFOperationDialogPresenter.present"))
        XCTAssertFalse(appDelegateSource.contains("makeSequenceAnnotationOperationDialogForm"))
        XCTAssertFalse(appDelegateSource.contains("sequence-annotation-operation-dialog"))
        XCTAssertTrue(dialogSource.contains("DatasetOperationsDialog("))
        XCTAssertTrue(dialogSource.contains("accessibilityNamespace: \"sequence-orf-operation\""))
        XCTAssertTrue(dialogSource.contains("TextField(\"Minimum ORF length\""))
        XCTAssertTrue(dialogSource.contains("sequence-orf-min-length-field"))
        XCTAssertTrue(dialogSource.contains("sequence-orf-codon-table-picker"))
    }

    func testFindORFsReadingFrameControlsUseCompactColumns() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dialogSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Sequence/SequenceORFOperationDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(dialogSource.contains("readingFrameColumnWidth"))
        XCTAssertTrue(dialogSource.contains(".frame(width: Self.readingFrameColumnWidth, alignment: .leading)"))
        XCTAssertTrue(dialogSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    func testORFAnnotationStoredTranslationBuildsRenderableTranslationResult() {
        let annotation = SequenceAnnotation(
            type: .orf,
            name: "ORF_+1_10_19",
            chromosome: "chr1",
            start: 10,
            end: 19,
            strand: .forward,
            qualifiers: [
                "translation": AnnotationQualifier("MK*"),
                "genetic_code_table": AnnotationQualifier("1")
            ]
        )

        let result = SequenceViewerView.storedAnnotationTranslationResult(for: annotation)

        XCTAssertEqual(result?.protein, "MK*")
        XCTAssertEqual(result?.codonTable.id, 1)
        XCTAssertEqual(result?.aminoAcidPositions.map(\.aminoAcid), ["M", "K", "*"])
        XCTAssertEqual(result?.aminoAcidPositions.map(\.genomicRanges.first), [
            GenomicRange(start: 10, end: 13),
            GenomicRange(start: 13, end: 16),
            GenomicRange(start: 16, end: 19),
        ])
        XCTAssertEqual(result?.aminoAcidPositions.first?.isStart, true)
        XCTAssertEqual(result?.aminoAcidPositions.last?.isStop, true)
    }

    func testDrawerSelectsViewportAnnotationByCoordinatesWhenNamesCollide() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        drawer.setAnnotations([
            AnnotationSearchIndex.SearchResult(
                name: "ORF_+1",
                chromosome: "chr1",
                start: 10,
                end: 70,
                trackId: "orfs",
                type: "ORF",
                strand: "+"
            ),
            AnnotationSearchIndex.SearchResult(
                name: "ORF_+1",
                chromosome: "chr1",
                start: 120,
                end: 210,
                trackId: "orfs",
                type: "ORF",
                strand: "+"
            )
        ])
        let selected = SequenceAnnotation(
            type: .orf,
            name: "ORF_+1",
            chromosome: "chr1",
            start: 120,
            end: 210,
            strand: .forward,
            qualifiers: ["annotation_db_track_id": AnnotationQualifier("orfs")]
        )

        XCTAssertTrue(drawer.selectAnnotation(matching: selected))
        XCTAssertEqual(drawer.debugSelectedAnnotationNames, ["ORF_+1"])
        XCTAssertEqual(drawer.debugSelectedAnnotationStarts, [120])
    }

    func testAnnotationDrawerExposesTrackIDAndTrackNameColumnsForFilteringAndSorting() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
        let rows = [
            AnnotationSearchIndex.SearchResult(
                name: "alpha",
                chromosome: "chr1",
                start: 10,
                end: 40,
                trackId: "ncbi_gff3_annotations",
                trackName: "NCBI GFF3 annotations",
                type: "gene"
            ),
            AnnotationSearchIndex.SearchResult(
                name: "orf",
                chromosome: "chr1",
                start: 50,
                end: 110,
                trackId: "orfs_mn908947",
                trackName: "MN908947 ORFs",
                type: "ORF"
            )
        ]
        drawer.setAnnotations(rows)

        XCTAssertTrue(drawer.tableView.tableColumns.contains { $0.title == "Track ID" })
        XCTAssertTrue(drawer.tableView.tableColumns.contains { $0.title == "Track Name" })
        XCTAssertEqual(
            drawer.applyAnnotationColumnFilters(
                to: rows,
                clauses: [AnnotationTableDrawerView.ColumnFilterClause(key: "track_id", op: "~", value: "orfs")]
            ).map(\.name),
            ["orf"]
        )
        XCTAssertEqual(
            drawer.applyAnnotationColumnFilters(
                to: rows,
                clauses: [AnnotationTableDrawerView.ColumnFilterClause(key: "track_name", op: "~", value: "NCBI")]
            ).map(\.name),
            ["alpha"]
        )

        drawer.tableView.sortDescriptors = [NSSortDescriptor(key: "track_name", ascending: true)]
        drawer.tableView(drawer.tableView, sortDescriptorsDidChange: [])
        XCTAssertEqual(drawer.displayedAnnotations.map(\.name), ["orf", "alpha"])
    }

    func testAnnotationDrawerClearsTrackStateWhenTracksDisappear() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
        drawer.setAnnotations([
            AnnotationSearchIndex.SearchResult(
                name: "orf",
                chromosome: "chr1",
                start: 50,
                end: 110,
                trackId: "orfs_mn908947",
                trackName: "MN908947 ORFs",
                type: "ORF"
            )
        ])
        drawer.debugSetAnnotationTrackVisible(trackId: "orfs_mn908947", visible: false)
        XCTAssertEqual(drawer.debugAnnotationTrackDisplayState.order, ["orfs_mn908947"])
        XCTAssertEqual(drawer.debugAnnotationTrackDisplayState.hiddenTrackIDs, ["orfs_mn908947"])

        drawer.setAnnotations([])

        XCTAssertTrue(drawer.debugAnnotationTrackDisplayState.order.isEmpty)
        XCTAssertTrue(drawer.debugAnnotationTrackDisplayState.hiddenTrackIDs.isEmpty)
        XCTAssertTrue(drawer.debugAnnotationTrackDisplayState.displayNames.isEmpty)
    }

    func testAnnotationTracksMenuRemainsVisibleForSingleTrackDeletion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let drawerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(drawerSource.contains("annotationTracksButton.isHidden = activeTab != .annotations || annotationTrackOrder.isEmpty"))
        XCTAssertFalse(drawerSource.contains("annotationTracksButton.isHidden = activeTab != .annotations || annotationTrackOrder.count <= 1"))
    }

    func testSequenceAnnotationRefreshReloadsActiveSequenceViewerFromDisk() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )
        let bundleDisplaySource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appDelegateSource.contains("reloadReferenceBundleAfterAnnotationTrackMutation("))
        XCTAssertTrue(bundleDisplaySource.contains("func reloadReferenceBundleAfterAnnotationTrackMutation("))
        XCTAssertTrue(bundleDisplaySource.contains("viewerView.setReferenceBundle(context.bundle)"))
        XCTAssertTrue(bundleDisplaySource.contains("index.buildIndex(bundle: context.bundle"))
        XCTAssertTrue(bundleDisplaySource.contains("annotationDrawerView?.setSearchIndex(index)"))
        XCTAssertTrue(bundleDisplaySource.contains("viewerView.invalidateAnnotationTile()"))
    }

    func testSequenceAnnotationRefreshDoesNotReplaceActiveSequenceViewerWithBrowseMode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDelegateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )

        let activeMatchRange = try XCTUnwrap(appDelegateSource.range(of: "let activeSequenceViewer = targetViewerController.activeSequenceViewerController"))
        let reloadRange = try XCTUnwrap(appDelegateSource.range(of: "try activeSequenceViewer.reloadReferenceBundleAfterAnnotationTrackMutation(bundleURL: bundleURL)"))
        let wrapperReloadRange = try XCTUnwrap(appDelegateSource.range(
            of: "try referenceViewport.reloadViewerBundleForInspectorChanges()",
            range: activeMatchRange.upperBound..<appDelegateSource.endIndex
        ))
        let displayRange = try XCTUnwrap(appDelegateSource.range(of: "try targetViewerController.displayBundle(at: bundleURL)", range: activeMatchRange.upperBound..<appDelegateSource.endIndex))
        XCTAssertLessThan(activeMatchRange.lowerBound, reloadRange.lowerBound)
        XCTAssertLessThan(reloadRange.lowerBound, wrapperReloadRange.lowerBound)
        XCTAssertLessThan(reloadRange.lowerBound, displayRange.lowerBound)
    }

    func testAnnotationImportUsesSharedTrackIdentityPresenter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainSplitSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift"),
            encoding: .utf8
        )
        let appDelegateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(mainSplitSource.contains("ReferenceBundleAnnotationImportConfigurationPresenter.choose"))
        XCTAssertFalse(mainSplitSource.contains("private func promptForAnnotationImportConfiguration"))
        XCTAssertTrue(appDelegateSource.contains("ReferenceBundleAnnotationImportConfigurationPresenter.present"))
        XCTAssertTrue(appDelegateSource.contains("trackID: configuration.trackID"))
        XCTAssertTrue(appDelegateSource.contains("trackName: configuration.trackName"))
        XCTAssertFalse(appDelegateSource.contains("chooseReferenceBundleForAnnotation("))
    }

    func testReferenceBundleReloadInvalidatesInFlightAnnotationFetches() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(viewerSource.contains("annotationFetchGeneration += 1"))
        XCTAssertTrue(viewerSource.contains("variantFetchGeneration += 1"))
        XCTAssertTrue(viewerSource.contains("viewer.currentReferenceBundle?.url.standardizedFileURL == bundle.url.standardizedFileURL"))
    }

    func testAnnotationRowDeletionIsCLIBacked() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let drawerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift"),
            encoding: .utf8
        )
        let viewerDrawerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(drawerSource.contains("didRequestDeleteAnnotations"))
        XCTAssertFalse(drawerSource.contains("searchIndex.deleteAnnotations(rowIDsByTrack: rowIDsByTrack)"))
        XCTAssertTrue(viewerDrawerSource.contains("\"delete-annotations\""))
        XCTAssertTrue(viewerDrawerSource.contains("--row-id"))
    }

    func testViewportAnnotationSelectionSyncsBottomDrawer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift"),
            encoding: .utf8
        )
        let drawerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(viewerSource.contains("viewController?.selectAnnotationInDrawer(annotation)"))
        XCTAssertFalse(viewerSource.contains("viewController?.selectAnnotationInDrawer(variant)"))
        XCTAssertTrue(drawerSource.contains("func selectAnnotationInDrawer(_ annotation: SequenceAnnotation)"))
    }

    private func makeReferenceBundle(
        chromosomeName: String,
        sequence: String
    ) throws -> URL {
        let bundleURL = tempDirectory.appendingPathComponent("tiny.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let fastaContent = ">\(chromosomeName)\n\(sequence)\n"
        try fastaContent.write(
            to: genomeDir.appendingPathComponent("sequence.fa"),
            atomically: true,
            encoding: .utf8
        )

        let offset = ">\(chromosomeName)\n".utf8.count
        try "\(chromosomeName)\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(
                to: genomeDir.appendingPathComponent("sequence.fa.fai"),
                atomically: true,
                encoding: .utf8
            )

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Tiny Reference",
            identifier: "org.lungfish.tests.sequence-menu",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosomeName,
                        length: Int64(sequence.count),
                        offset: Int64(offset),
                        lineBases: sequence.count,
                        lineWidth: sequence.count + 1
                    )
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
