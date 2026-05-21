import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishWorkflow

@MainActor
final class SidebarViewControllerSelectionTests: XCTestCase {
    func testDraggedItemIdentifiersReadsEveryPasteboardItem() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let first = NSPasteboardItem()
        first.setString("/tmp/project/A.lungfishref", forType: sidebarItemPasteboardType)
        let second = NSPasteboardItem()
        second.setString("/tmp/project/B.lungfishref", forType: sidebarItemPasteboardType)
        pasteboard.writeObjects([first, second])

        XCTAssertEqual(
            SidebarViewController.draggedItemIdentifiers(from: pasteboard),
            ["/tmp/project/A.lungfishref", "/tmp/project/B.lungfishref"]
        )
    }

    func testBatchSequenceExportTargetsCreatesOneFilePerBundle() {
        let folder = URL(fileURLWithPath: "/tmp/Exports", isDirectory: true)
        let bundles = [
            URL(fileURLWithPath: "/tmp/project/Alpha.lungfishref", isDirectory: true),
            URL(fileURLWithPath: "/tmp/project/Beta.lungfishref", isDirectory: true),
        ]

        let targets = AppDelegate.batchSequenceExportTargets(
            for: bundles,
            outputFolder: folder,
            format: .genbank,
            compression: .none
        )

        XCTAssertEqual(targets, [
            bundles[0]: folder.appendingPathComponent("Alpha.gb"),
            bundles[1]: folder.appendingPathComponent("Beta.gb"),
        ])
    }

    func testBatchSequenceExportCLICommandsUseConvertForEachBundle() {
        let folder = URL(fileURLWithPath: "/tmp/Exports", isDirectory: true)
        let bundles = [
            URL(fileURLWithPath: "/tmp/project/Alpha.lungfishref", isDirectory: true),
            URL(fileURLWithPath: "/tmp/project/Beta Name.lungfishref", isDirectory: true),
        ]

        let commands = AppDelegate.batchSequenceExportCLICommands(
            for: bundles,
            outputFolder: folder,
            format: .genbank,
            compression: .none
        )

        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[0].contains("lungfish convert"))
        XCTAssertTrue(commands[0].contains("--to-format genbank"))
        XCTAssertTrue(commands[0].contains("--include-annotations"))
        XCTAssertTrue(commands[0].contains("--force"))
        XCTAssertTrue(commands[1].contains("Beta Name.lungfishref"))
        XCTAssertTrue(commands[1].contains("Beta Name.gb"))
    }

    func testReferenceBundleSequenceExportCLIArgumentsUseConvertForceAndQuiet() {
        let bundle = URL(fileURLWithPath: "/tmp/project/Alpha.lungfishref", isDirectory: true)
        let output = URL(fileURLWithPath: "/tmp/Exports/Alpha.fa")

        let arguments = AppDelegate.referenceBundleSequenceExportCLIArguments(
            bundleURL: bundle,
            outputURL: output,
            format: .fasta
        )

        XCTAssertEqual(arguments, [
            "convert",
            bundle.path,
            "--to", output.path,
            "--to-format", "fasta",
            "--include-annotations",
            "--force",
            "--quiet",
        ])
    }

    func testBatchSequenceExportCLICommandsOmitUnsupportedCompressionWrapper() {
        let folder = URL(fileURLWithPath: "/tmp/Exports", isDirectory: true)
        let bundles = [
            URL(fileURLWithPath: "/tmp/project/Alpha.lungfishref", isDirectory: true),
        ]

        let commands = AppDelegate.batchSequenceExportCLICommands(
            for: bundles,
            outputFolder: folder,
            format: .genbank,
            compression: .gzip
        )

        XCTAssertTrue(commands.isEmpty)
    }

    func testSuggestedMergedBundleNameUsesFirstSelectedTitle() {
        let items = [
            SidebarItem(
                title: "Sample A",
                type: .fastqBundle,
                url: URL(fileURLWithPath: "/tmp/A.lungfishfastq")
            ),
            SidebarItem(
                title: "Sample B",
                type: .fastqBundle,
                url: URL(fileURLWithPath: "/tmp/B.lungfishfastq")
            ),
        ]

        XCTAssertEqual(
            SidebarViewController.suggestedMergedBundleName(for: items),
            "Sample A merged"
        )
    }

    func testDeepestCommonParentUsesSharedContainingDirectory() {
        let urls = [
            URL(fileURLWithPath: "/tmp/project/Reads/A.lungfishfastq"),
            URL(fileURLWithPath: "/tmp/project/Reads/B.lungfishfastq"),
            URL(fileURLWithPath: "/tmp/project/Reads/C.lungfishfastq"),
        ]

        XCTAssertEqual(
            SidebarViewController.deepestCommonParent(for: urls),
            URL(fileURLWithPath: "/tmp/project/Reads", isDirectory: true)
        )
    }

    func testInternalDropWithNoDestinationTargetsProjectRoot() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)

        XCTAssertEqual(
            SidebarViewController.internalDropDestinationURL(projectURL: projectURL, destinationItem: nil),
            projectURL.standardizedFileURL
        )
    }

    func testSelectItemFindsAnalysisWhenCallerUsesSymlinkedPath() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarSelection-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let aliasURL = tempRoot.appendingPathComponent("Fixture-alias.lungfish", isDirectory: false)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let analysisURL = try AnalysesFolder.createAnalysisDirectory(
            tool: "skesa",
            in: projectURL,
            date: Date(timeIntervalSince1970: 1_715_000_000)
        )
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: projectURL)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        let symlinkedAnalysisURL = aliasURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent(analysisURL.lastPathComponent, isDirectory: true)

        XCTAssertTrue(sidebar.selectItem(forURL: symlinkedAnalysisURL))
        XCTAssertEqual(
            sidebar.selectedFileURL?.resolvingSymlinksInPath(),
            analysisURL.resolvingSymlinksInPath()
        )
    }

    func testSelectItemFindsAnalysisInsideUserGroupingFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarNestedAnalysis-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let analysesDir = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let groupURL = analysesDir.appendingPathComponent("Map NHP genomic FASTA to Zhang pan-genomes", isDirectory: true)
        let analysisURL = groupURL.appendingPathComponent("minimap2-ont-2026-04-24T20-03-58", isDirectory: true)

        try FileManager.default.createDirectory(at: analysisURL, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(
            .init(tool: "minimap2", isBatch: false, created: Date(timeIntervalSince1970: 1_776_000_000)),
            to: analysisURL
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: analysisURL))
        XCTAssertEqual(sidebar.selectedFileURL?.resolvingSymlinksInPath(), analysisURL.resolvingSymlinksInPath())
    }

    func testSidebarIgnoresFASTQOperationStagingFoldersInAnalyses() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarStagingFolders-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let analysesDir = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let cliOutputURL = analysesDir.appendingPathComponent("cli-output-1234", isDirectory: true)
        let materializedURL = analysesDir.appendingPathComponent("materialized-inputs-1234", isDirectory: true)
        let analysisURL = try AnalysesFolder.createAnalysisDirectory(
            tool: "minimap2",
            in: projectURL,
            date: Date(timeIntervalSince1970: 1_776_000_000)
        )
        try FileManager.default.createDirectory(at: cliOutputURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materializedURL, withIntermediateDirectories: true)
        try "staged".write(
            to: cliOutputURL.appendingPathComponent(".lungfish-provenance.json"),
            atomically: true,
            encoding: .utf8
        )
        try "staged".write(
            to: materializedURL.appendingPathComponent("materialized.fastq.gz"),
            atomically: true,
            encoding: .utf8
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: analysisURL))
        XCTAssertFalse(sidebar.selectItem(forURL: cliOutputURL))
        XCTAssertFalse(sidebar.selectItem(forURL: materializedURL))
    }

    func testSelectItemFindsLooseAnalysisReportFileInAnalysesFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarAnalysesLooseFile-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let reportURL = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("ont-genotyping-report.csv")

        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "sample,genotype,reads\nDW472,A1,20\n".write(
            to: reportURL,
            atomically: true,
            encoding: .utf8
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: reportURL))
        let item = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(item.type, .document)
        XCTAssertEqual(item.title, "ont-genotyping-report.csv")
    }

    func testSelectItemFindsGroupedAnalysisReportFileBesideAnalysisDirectories() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarGroupedAnalysisLooseFile-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let groupedResultsURL = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
        let sampleAnalysisURL = groupedResultsURL.appendingPathComponent("DW472", isDirectory: true)
        let reportURL = groupedResultsURL.appendingPathComponent("ont-genotyping-report.csv")

        try FileManager.default.createDirectory(
            at: sampleAnalysisURL,
            withIntermediateDirectories: true
        )
        try ">fixture\nACGT\n".write(
            to: sampleAnalysisURL.appendingPathComponent("fixture.fa"),
            atomically: true,
            encoding: .utf8
        )
        try "sample,genotype,reads\nDW472,A1,20\n".write(
            to: reportURL,
            atomically: true,
            encoding: .utf8
        )
        try AnalysesFolder.writeAnalysisMetadata(
            .init(tool: "minimap2", isBatch: false, created: Date(timeIntervalSince1970: 1_776_000_000)),
            to: sampleAnalysisURL
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: reportURL))
        let item = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(item.type, .document)
        XCTAssertEqual(item.title, "ont-genotyping-report.csv")
    }

    func testGroupedReportDoesNotDemoteContentProbedMinimap2Result() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarGroupedMinimap2LooseFile-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let groupedResultsURL = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
        let sampleAnalysisURL = groupedResultsURL.appendingPathComponent("DW472", isDirectory: true)
        let reportURL = groupedResultsURL.appendingPathComponent("ont-genotyping-report.csv")
        let appleDoubleReportURL = groupedResultsURL.appendingPathComponent("._ont-genotyping-report.csv")

        try FileManager.default.createDirectory(
            at: sampleAnalysisURL,
            withIntermediateDirectories: true
        )
        try """
        {
          "mapper": "minimap2",
          "modeID": "short-read-default",
          "bamPath": "DW472.ont-genotyping.filtered.bam",
          "baiPath": "DW472.ont-genotyping.filtered.bam.bai",
          "mappedReads": 20,
          "totalReads": 100,
          "unmappedReads": 80,
          "contigs": []
        }
        """.write(
            to: sampleAnalysisURL.appendingPathComponent("mapping-result.json"),
            atomically: true,
            encoding: .utf8
        )
        try "sample,genotype,reads\nDW472,A1,20\n".write(
            to: reportURL,
            atomically: true,
            encoding: .utf8
        )
        try "appledouble".write(
            to: appleDoubleReportURL,
            atomically: true,
            encoding: .utf8
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: sampleAnalysisURL))
        let mappingItem = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(mappingItem.type, .analysisResult)
        XCTAssertEqual(mappingItem.icon, "m.circle")
        XCTAssertEqual(mappingItem.userInfo["analysisTool"], "minimap2")

        XCTAssertTrue(sidebar.selectItem(forURL: reportURL))
        let reportItem = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(reportItem.type, .document)
        XCTAssertEqual(reportItem.title, "ont-genotyping-report.csv")

        XCTAssertFalse(sidebar.selectItem(forURL: appleDoubleReportURL))
    }

    func testMultiFileFASTQBundleAppearsAsBundleNotChunkFile() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarMultiFileFASTQ-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("barcode08.lungfishfastq", isDirectory: true)
        let chunksURL = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        let chunkA = chunksURL.appendingPathComponent("chunk-a.fastq")
        let chunkB = chunksURL.appendingPathComponent("chunk-b.fastq")

        try FileManager.default.createDirectory(at: chunksURL, withIntermediateDirectories: true)
        try "@a\nACGT\n+\nIIII\n".write(to: chunkA, atomically: true, encoding: .utf8)
        try "@b\nTGCA\n+\nIIII\n".write(to: chunkB, atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/chunk-a.fastq", originalPath: "/source/chunk-a.fastq", sizeBytes: 16, isSymlink: false),
            .init(filename: "chunks/chunk-b.fastq", originalPath: "/source/chunk-b.fastq", sizeBytes: 16, isSymlink: false),
        ]).save(to: bundleURL)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        let item = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(item.type, .fastqBundle)
        XCTAssertEqual(item.title, "barcode08")
        XCTAssertEqual(item.url?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertFalse(item.children.contains { $0.url?.lastPathComponent == "chunk-a.fastq" })
    }

    func testVirtualFASTQBundleUnderAnalysesAppearsAsBundleNotLooseFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarAnalysisVirtualFASTQ-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let demuxURL = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("demultiplex", isDirectory: true)
        let bundleURL = demuxURL.appendingPathComponent("DW472.lungfishfastq", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "@read-1\nACGT\n+\nIIII\n".write(
            to: bundleURL.appendingPathComponent("preview.fastq"),
            atomically: true,
            encoding: .utf8
        )
        try "read-1\n".write(
            to: bundleURL.appendingPathComponent("read-ids.txt"),
            atomically: true,
            encoding: .utf8
        )
        let demuxOperation = FASTQDerivativeOperation(
            kind: .demultiplex,
            toolUsed: "lungfish-cli",
            toolVersion: "test"
        )
        let manifest = FASTQDerivedBundleManifest(
            name: "DW472",
            parentBundleRelativePath: "../../barcode08.lungfishfastq",
            rootBundleRelativePath: "../../barcode08.lungfishfastq",
            rootFASTQFilename: "chunks/chunk-1.fastq",
            payload: .demuxedVirtual(
                barcodeID: "DW472",
                readIDListFilename: "read-ids.txt",
                previewFilename: "preview.fastq",
                trimPositionsFilename: nil,
                orientMapFilename: nil
            ),
            lineage: [demuxOperation],
            operation: demuxOperation,
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        let item = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(item.type, .fastqBundle)
        XCTAssertEqual(item.title, "DW472")
        XCTAssertEqual(item.url?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertFalse(item.children.contains { $0.url?.lastPathComponent == "preview.fastq" })
        XCTAssertFalse(item.children.contains { $0.url?.lastPathComponent == "read-ids.txt" })
    }

    func testArbitraryUserFilesAreVisibleInProjectAndAnalyses() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarArbitraryFiles-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let analysesURL = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
        let rootExtensionlessURL = projectURL.appendingPathComponent("README", isDirectory: false)
        let rootJSONURL = projectURL.appendingPathComponent("config.json", isDirectory: false)
        let analysisUnknownURL = analysesURL.appendingPathComponent("summary.customtable", isDirectory: false)
        let analysisExtensionlessURL = analysesURL.appendingPathComponent("NOTES", isDirectory: false)

        try FileManager.default.createDirectory(at: analysesURL, withIntermediateDirectories: true)
        try "project notes\n".write(to: rootExtensionlessURL, atomically: true, encoding: .utf8)
        try "{\"user\":true}\n".write(to: rootJSONURL, atomically: true, encoding: .utf8)
        try "sample\tvalue\nDW472\t1\n".write(to: analysisUnknownURL, atomically: true, encoding: .utf8)
        try "analysis notes\n".write(to: analysisExtensionlessURL, atomically: true, encoding: .utf8)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        for fileURL in [rootExtensionlessURL, rootJSONURL, analysisUnknownURL, analysisExtensionlessURL] {
            XCTAssertTrue(sidebar.selectItem(forURL: fileURL), "\(fileURL.lastPathComponent) should be visible")
            let item = try XCTUnwrap(sidebar.selectedItems().first)
            XCTAssertEqual(item.url?.standardizedFileURL, fileURL.standardizedFileURL)
            XCTAssertFalse(item.type.isBundle)
        }
    }

    func testProjectRootProvenanceFolderIsHiddenFromSidebar() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarRootProvenance-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let provenanceURL = projectURL.appendingPathComponent("provenance", isDirectory: true)

        try FileManager.default.createDirectory(at: provenanceURL, withIntermediateDirectories: true)
        try "{\"workflow\":\"fixture\"}\n".write(
            to: provenanceURL.appendingPathComponent("run.json"),
            atomically: true,
            encoding: .utf8
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertFalse(sidebar.selectItem(forURL: provenanceURL))
    }

    func testPackageBundlesUnderAnalysesAreRecognizedBeforeFolderRecursion() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarAnalysisBundles-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let analysesURL = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("Bundles", isDirectory: true)

        let cases: [(name: String, type: SidebarItemType, title: String)] = [
            ("Reference.lungfishref", .referenceBundle, "Reference"),
            ("Reads.lungfishfastq", .fastqBundle, "Reads"),
            ("Alignment.lungfishmsa", .multipleSequenceAlignmentBundle, "Alignment"),
            ("Tree.lungfishtree", .phylogeneticTreeBundle, "Tree"),
            ("Primers.lungfishprimers", .primerSchemeBundle, "Primers"),
        ]

        for bundleCase in cases {
            let bundleURL = analysesURL.appendingPathComponent(bundleCase.name, isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try "internal\n".write(
                to: bundleURL.appendingPathComponent("manifest.json", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        for bundleCase in cases {
            let bundleURL = analysesURL.appendingPathComponent(bundleCase.name, isDirectory: true)
            XCTAssertTrue(sidebar.selectItem(forURL: bundleURL), "\(bundleCase.name) should be visible")
            let item = try XCTUnwrap(sidebar.selectedItems().first)
            XCTAssertEqual(item.type, bundleCase.type)
            XCTAssertEqual(item.title, bundleCase.title)
            XCTAssertEqual(item.url?.standardizedFileURL, bundleURL.standardizedFileURL)
            XCTAssertTrue(item.children.isEmpty, "\(bundleCase.name) should not expose internal bundle files")
        }
    }

    func testSelectItemRoutesMAFFTAnalysisBundleAsMultipleSequenceAlignment() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scratch = repositoryRoot
            .appendingPathComponent(".build/test-scratch/SidebarMAFFTAnalysis-\(UUID().uuidString)", isDirectory: true)
        let projectURL = scratch.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let analysisURL = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("Multiple Sequence Alignments", isDirectory: true)
            .appendingPathComponent("sars-cov-2-genomes.lungfishmsa", isDirectory: true)

        try FileManager.default.createDirectory(at: analysisURL, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(
            .init(tool: "mafft", isBatch: false, created: Date(timeIntervalSince1970: 1_776_000_000)),
            to: analysisURL
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: scratch)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: analysisURL))
        let item = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(item.type, .multipleSequenceAlignmentBundle)
        XCTAssertEqual(item.title, "sars-cov-2-genomes")
        XCTAssertEqual(sidebar.selectedFileURL?.resolvingSymlinksInPath(), analysisURL.resolvingSymlinksInPath())
    }

    func testSelectItemRoutesProjectCzIdClassificationBundleAsTaxonomyResult() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarCzIdClassification-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundleURL = projectURL
            .appendingPathComponent("Classifications", isDirectory: true)
            .appendingPathComponent("Sample-CZ-001.lungfishtax", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = CzIdImportManifest(
            schemaVersion: CzIdDataConverter.schemaVersion,
            sampleName: "Sample-CZ-001",
            projectId: nil,
            pipelineVersion: "8.4",
            ntDatabaseVersion: "nt_2025_12_01",
            nrDatabaseVersion: "nr_2025_12_01",
            sourceFiles: [],
            rowCount: 3
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent("cz-id-manifest.json"))

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(SidebarItemType.czIdResult.isBundle)
        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        let item = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(item.type, .czIdResult)
        XCTAssertEqual(item.title, "Sample-CZ-001")
        XCTAssertEqual(item.subtitle, "CZ-ID · Sample-CZ-001")
    }
}
