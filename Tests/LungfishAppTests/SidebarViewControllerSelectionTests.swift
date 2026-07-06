import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishWorkflow

@MainActor
final class SidebarViewControllerSelectionTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeONTChunkedFASTQBundle(in directory: URL) throws -> URL {
        let bundleURL = directory.appendingPathComponent("barcode05.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let chunksURL = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksURL, withIntermediateDirectories: true)

        let firstChunk = chunksURL.appendingPathComponent("barcode05_0.fastq")
        let secondChunk = chunksURL.appendingPathComponent("barcode05_1.fastq")
        try "@read-1\nACGT\n+\nIIII\n".write(to: firstChunk, atomically: true, encoding: .utf8)
        try "@read-2\nTGCA\n+\nJJJJ\n".write(to: secondChunk, atomically: true, encoding: .utf8)

        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/barcode05_0.fastq", originalPath: "/run/barcode05_0.fastq", sizeBytes: 18, isSymlink: false),
            .init(filename: "chunks/barcode05_1.fastq", originalPath: "/run/barcode05_1.fastq", sizeBytes: 18, isSymlink: false),
        ]).save(to: bundleURL)

        return bundleURL
    }

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
        XCTAssertTrue(commands[0].contains("\(CLICommandIdentity.executableName) convert"))
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

    func testSidebarProvenanceRehydrationUsesFinalPathDurableReplayForCLICreatedBundles() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceBundle = tempDir.appendingPathComponent("staging/Source.lungfishfastq", isDirectory: true)
        let destinationBundle = tempDir.appendingPathComponent("Project/Source copy.lungfishfastq", isDirectory: true)
        let sourcePayload = sourceBundle.appendingPathComponent("reads/source.fastq")
        let destinationPayload = destinationBundle.appendingPathComponent("reads/source.fastq")
        try FileManager.default.createDirectory(at: sourcePayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("@r\nTGCA\n+\n!!!!\n".utf8).write(to: sourcePayload, options: .atomic)

        let cliEnvelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Bundle Import",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(["lungfish-cli", "import", "fastq", "--bundle", sourceBundle.path])
        .output(sourcePayload, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: ["lungfish-cli", "import", "fastq", "--bundle", sourceBundle.path],
                outputs: [try ProvenanceFileDescriptor.file(url: sourcePayload, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 2
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 22)
        )
        try ProvenanceWriter(signingProvider: nil).write(cliEnvelope, to: sourceBundle)
        try FileManager.default.createDirectory(at: destinationBundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceBundle, to: destinationBundle)
        try FileManager.default.removeItem(at: sourceBundle)

        SidebarViewController().rehydrateScientificProvenance(from: sourceBundle, to: destinationBundle)

        let stored = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: destinationBundle))
        XCTAssertEqual(stored.steps.map(\.toolName), ["lungfish-cli", "lungfish-app"])
        XCTAssertEqual(stored.output?.path, destinationPayload.path)
        XCTAssertEqual(stored.steps[0].outputs.map(\.path), [destinationPayload.path])
        XCTAssertEqual(stored.steps[0].argv.last, sourceBundle.path)
        XCTAssertEqual(stored.steps[0].durableReplayArgv?.last, destinationBundle.path)
        XCTAssertFalse(stored.outputs.contains { $0.path.hasPrefix(sourceBundle.path) })
    }

    func testFASTQExportSuggestedFilenameUsesBundleNameForONTChunkedBundles() throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let bundleURL = try makeONTChunkedFASTQBundle(in: temp)

        XCTAssertEqual(
            AppDelegate.fastqExportSuggestedFilename(bundleURL: bundleURL, isDerived: false),
            "barcode05.fastq"
        )
    }

    func testFASTQExportMaterializesAllONTSourceManifestChunks() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let bundleURL = try makeONTChunkedFASTQBundle(in: temp)
        let outputURL = temp.appendingPathComponent("barcode05-export.fastq")

        try await AppDelegate.exportFASTQBundleForSidebar(
            bundleURL: bundleURL,
            outputURL: outputURL,
            isDerived: false
        )

        var identifiers: [String] = []
        for try await record in FASTQReader().records(from: outputURL) {
            identifiers.append(record.identifier)
        }

        XCTAssertEqual(identifiers, ["read-1", "read-2"])

        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "FASTQ Export")
        XCTAssertEqual(envelope.outputs.map(\.path), [outputURL.path])
        XCTAssertTrue(envelope.files.contains { $0.path.hasSuffix("chunks/barcode05_0.fastq") })
        XCTAssertTrue(envelope.files.contains { $0.path.hasSuffix("chunks/barcode05_1.fastq") })
    }

    func testFASTQExportReplacesExistingPayloadAndSidecarAfterSuccessfulStagedExport() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let bundleURL = try makeONTChunkedFASTQBundle(in: temp)
        let outputURL = temp.appendingPathComponent("barcode05-export.fastq")
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        try "old payload\n".write(to: outputURL, atomically: true, encoding: .utf8)
        try "old provenance\n".write(to: sidecarURL, atomically: true, encoding: .utf8)

        try await AppDelegate.exportFASTQBundleForSidebar(
            bundleURL: bundleURL,
            outputURL: outputURL,
            isDerived: false
        )

        var identifiers: [String] = []
        for try await record in FASTQReader().records(from: outputURL) {
            identifiers.append(record.identifier)
        }
        XCTAssertEqual(identifiers, ["read-1", "read-2"])
        XCTAssertNotEqual(try String(contentsOf: sidecarURL, encoding: .utf8), "old provenance\n")

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.outputs.map(\.path), [outputURL.path])
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: outputURL))
        XCTAssertEqual(envelope.output?.fileSize, try ProvenanceFileHasher.fileSize(of: outputURL))
        let entries = try FileManager.default.contentsOfDirectory(atPath: temp.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".barcode05-export") })
    }

    func testFASTQExportStagedGzipOutputPreservesCompressionBehavior() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let bundleURL = try makeONTChunkedFASTQBundle(in: temp)
        let outputURL = temp.appendingPathComponent("barcode05-export.fastq.gz")

        try await AppDelegate.exportFASTQBundleForSidebar(
            bundleURL: bundleURL,
            outputURL: outputURL,
            isDerived: false
        )

        var identifiers: [String] = []
        for try await record in FASTQReader().records(from: outputURL) {
            identifiers.append(record.identifier)
        }

        XCTAssertEqual(identifiers, ["read-1", "read-2"])
        let headerBytes = try Data(contentsOf: outputURL).prefix(2)
        XCTAssertEqual(Array(headerBytes), [0x1f, 0x8b])

        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.outputs.map(\.path), [outputURL.path])
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: outputURL))
        XCTAssertEqual(envelope.output?.fileSize, try ProvenanceFileHasher.fileSize(of: outputURL))
        XCTAssertEqual(envelope.legacyRun?.parameters["outputGzipCompressed"], ParameterValue.boolean(true))

        let entries = try FileManager.default.contentsOfDirectory(atPath: temp.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".barcode05-export") && !$0.hasSuffix(".lungfish-provenance.json") })
    }

    func testFASTQExportRestoresExistingPayloadAndSidecarWhenChunkExportFails() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }

        let bundleURL = try makeONTChunkedFASTQBundle(in: temp)
        let missingChunkURL = bundleURL
            .appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent("barcode05_1.fastq")
        try FileManager.default.removeItem(at: missingChunkURL)

        let outputURL = temp.appendingPathComponent("barcode05-export.fastq")
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        try "old payload\n".write(to: outputURL, atomically: true, encoding: .utf8)
        try "old provenance\n".write(to: sidecarURL, atomically: true, encoding: .utf8)

        do {
            try await AppDelegate.exportFASTQBundleForSidebar(
                bundleURL: bundleURL,
                outputURL: outputURL,
                isDerived: false
            )
            XCTFail("Expected export to fail when a manifest chunk is missing")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "old payload\n")
        XCTAssertEqual(try String(contentsOf: sidecarURL, encoding: .utf8), "old provenance\n")
        let entries = try FileManager.default.contentsOfDirectory(atPath: temp.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".barcode05-export") })
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

    func testMergeDialogInformativeTextClarifiesReferenceMergeLimit() {
        XCTAssertEqual(
            SidebarViewController.mergeDialogInformativeText(for: .fastq),
            "Enter a name for the merged FASTQ bundle:"
        )
        XCTAssertTrue(
            SidebarViewController.mergeDialogInformativeText(for: .reference)
                .contains("sequence-only reference bundle")
        )
        XCTAssertTrue(
            SidebarViewController.mergeDialogInformativeText(for: .reference)
                .contains("rejected rather than partially merged")
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

    func testMoveMenuDestinationsComeFromSidebarFoldersAndExcludeMovingSubtree() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let readsURL = projectURL.appendingPathComponent("Reads", isDirectory: true)
        let nestedURL = readsURL.appendingPathComponent("Nested", isDirectory: true)
        let resultsURL = projectURL.appendingPathComponent("Results", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)

        let rootItems = [
            SidebarItem(
                title: "Reads",
                type: .folder,
                children: [
                    SidebarItem(title: "Nested", type: .folder, url: nestedURL),
                ],
                url: readsURL
            ),
            SidebarItem(title: "Results", type: .folder, url: resultsURL),
            SidebarItem(title: "Sample", type: .fastqBundle, url: bundleURL),
        ]

        let destinations = SidebarViewController.moveMenuFolderDestinations(
            from: rootItems,
            excludingURLs: [readsURL.standardizedFileURL]
        )

        XCTAssertEqual(destinations, [resultsURL.standardizedFileURL])
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

    func testFilesystemReloadPreservesCollapsedTopLevelFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarCollapsedFolder-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let importsURL = projectURL.appendingPathComponent("Imports", isDirectory: true)
        let readsURL = importsURL.appendingPathComponent("reads.fastq")

        try FileManager.default.createDirectory(at: importsURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        let importsItem = try XCTUnwrap(sidebar.rootItems.first {
            $0.url?.standardizedFileURL == importsURL.standardizedFileURL
        })
        XCTAssertTrue(
            sidebar.outlineView.isItemExpanded(importsItem),
            "Top-level project folders should still default to expanded on first open."
        )

        sidebar.outlineView.collapseItem(importsItem)
        XCTAssertFalse(sidebar.outlineView.isItemExpanded(importsItem))

        sidebar.reloadFromFilesystem()

        let reloadedImportsItem = try XCTUnwrap(sidebar.rootItems.first {
            $0.url?.standardizedFileURL == importsURL.standardizedFileURL
        })
        XCTAssertFalse(
            sidebar.outlineView.isItemExpanded(reloadedImportsItem),
            "Filesystem reload must preserve the user's collapsed state."
        )
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

    func testWorkflowInputSelectionExpandsDirectFolderFASTQBundlesOnly() {
        let folderURL = URL(fileURLWithPath: "/tmp/project/Runs", isDirectory: true)
        let first = folderURL.appendingPathComponent("A.lungfishfastq", isDirectory: true)
        let second = folderURL.appendingPathComponent("B.lungfishfastq", isDirectory: true)
        let ignoredNonBundleRow = folderURL.appendingPathComponent("Ignored.lungfishfastq", isDirectory: true)
        let nested = folderURL
            .appendingPathComponent("Nested", isDirectory: true)
            .appendingPathComponent("C.lungfishfastq", isDirectory: true)
        let folder = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(title: "A", type: .fastqBundle, url: first),
                SidebarItem(title: "B", type: .fastqBundle, url: second),
                SidebarItem(title: "Ignored", type: .document, url: ignoredNonBundleRow),
                SidebarItem(
                    title: "Nested",
                    type: .folder,
                    children: [
                        SidebarItem(title: "C", type: .fastqBundle, url: nested),
                    ],
                    url: folderURL.appendingPathComponent("Nested", isDirectory: true)
                ),
            ],
            url: folderURL
        )

        let selection = WorkflowSidebarInputSelection.resolve(
            items: [folder],
            projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )

        XCTAssertEqual(selection.directReadURLs, [first.standardizedFileURL, second.standardizedFileURL])
        XCTAssertEqual(selection.recursiveReadURLs, [first.standardizedFileURL, second.standardizedFileURL, nested.standardizedFileURL])
        XCTAssertEqual(selection.selectedReadURLs(includeSubfolders: false), [first.standardizedFileURL, second.standardizedFileURL])
        XCTAssertEqual(selection.selectedReadURLs(includeSubfolders: true), [first.standardizedFileURL, second.standardizedFileURL, nested.standardizedFileURL])
        XCTAssertEqual(selection.folderSelectionCount, 1)
        XCTAssertEqual(selection.additionalDescendantBundleCount, 1)
        XCTAssertTrue(selection.hasAdditionalDescendantBundles)
        XCTAssertEqual(selection.summaryText(includeSubfolders: false), "Folder \"Runs\" expands to 2 eligible FASTQ bundles.")
    }

    func testWorkflowInputSelectionCombinesMultipleFoldersAsOneDeduplicatedBatch() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let shared = projectURL.appendingPathComponent("A.lungfishfastq", isDirectory: true)
        let unique = projectURL.appendingPathComponent("B.lungfishfastq", isDirectory: true)
        let runs = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(title: "A", type: .fastqBundle, url: shared),
                SidebarItem(title: "B", type: .fastqBundle, url: unique),
            ],
            url: projectURL.appendingPathComponent("Runs", isDirectory: true)
        )
        let selectedAgain = SidebarItem(title: "A", type: .fastqBundle, url: shared)

        let selection = WorkflowSidebarInputSelection.resolve(items: [runs, selectedAgain], projectURL: projectURL)

        XCTAssertEqual(selection.directReadURLs, [shared.standardizedFileURL, unique.standardizedFileURL])
        XCTAssertEqual(selection.explicitBundleCount, 1)
        XCTAssertEqual(selection.folderSelectionCount, 1)
        XCTAssertEqual(selection.selectedFolderNames, ["Runs"])
        XCTAssertEqual(selection.duplicateBundleCount, 1)
        XCTAssertEqual(selection.duplicateSummaryText, "Skipped 1 duplicate bundle already included by another selected item.")
        XCTAssertEqual(selection.summaryText(includeSubfolders: false), "2 FASTQ bundles selected from 1 folder and 1 explicit bundle.")
    }

    func testWorkflowInputSelectionDoesNotRecurseIntoFASTQBundleChildren() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let top = projectURL.appendingPathComponent("Top.lungfishfastq", isDirectory: true)
        let demuxChild = top
            .appendingPathComponent("demux", isDirectory: true)
            .appendingPathComponent("Barcode01.lungfishfastq", isDirectory: true)
        let folder = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(
                    title: "Top",
                    type: .fastqBundle,
                    children: [
                        SidebarItem(title: "Barcode01", type: .fastqBundle, url: demuxChild),
                    ],
                    url: top
                ),
            ],
            url: projectURL.appendingPathComponent("Runs", isDirectory: true)
        )

        let selection = WorkflowSidebarInputSelection.resolve(items: [folder], projectURL: projectURL)

        XCTAssertEqual(selection.directReadURLs, [top.standardizedFileURL])
        XCTAssertEqual(selection.recursiveReadURLs, [top.standardizedFileURL])
        XCTAssertEqual(selection.additionalDescendantBundleCount, 0)
    }

    func testWorkflowInputSelectionReportsEmptyFolderWithSubfolderBundles() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let nestedBundle = projectURL
            .appendingPathComponent("Runs/Nested/C.lungfishfastq", isDirectory: true)
        let folder = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(
                    title: "Nested",
                    type: .folder,
                    children: [
                        SidebarItem(title: "C", type: .fastqBundle, url: nestedBundle),
                    ],
                    url: projectURL.appendingPathComponent("Runs/Nested", isDirectory: true)
                ),
            ],
            url: projectURL.appendingPathComponent("Runs", isDirectory: true)
        )

        let selection = WorkflowSidebarInputSelection.resolve(items: [folder], projectURL: projectURL)

        XCTAssertTrue(selection.directReadURLs.isEmpty)
        XCTAssertEqual(selection.recursiveReadURLs, [nestedBundle.standardizedFileURL])
        XCTAssertEqual(selection.emptyFolderSummaryText, "No eligible FASTQ bundles were found directly in \"Runs\".")
        XCTAssertEqual(selection.subfolderSummaryText, "Subfolders contain 1 additional eligible FASTQ bundle.")
    }

    func testWorkflowInputSelectionCountsRecursiveDuplicatesSeparatelyFromDirectMode() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let nestedBundle = projectURL
            .appendingPathComponent("Runs/Nested/C.lungfishfastq", isDirectory: true)
        let folder = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(
                    title: "Nested",
                    type: .folder,
                    children: [
                        SidebarItem(title: "C", type: .fastqBundle, url: nestedBundle),
                    ],
                    url: projectURL.appendingPathComponent("Runs/Nested", isDirectory: true)
                ),
            ],
            url: projectURL.appendingPathComponent("Runs", isDirectory: true)
        )
        let explicitNested = SidebarItem(title: "C", type: .fastqBundle, url: nestedBundle)

        let selection = WorkflowSidebarInputSelection.resolve(items: [folder, explicitNested], projectURL: projectURL)

        XCTAssertEqual(selection.directReadURLs, [nestedBundle.standardizedFileURL])
        XCTAssertEqual(selection.recursiveReadURLs, [nestedBundle.standardizedFileURL])
        XCTAssertEqual(selection.additionalDescendantBundleCount, 0)
        XCTAssertNil(selection.duplicateSummaryText(includeSubfolders: false))
        XCTAssertEqual(
            selection.duplicateSummaryText(includeSubfolders: true),
            "Skipped 1 duplicate bundle already included by another selected item."
        )
    }

    func testWorkflowInputSelectionDetailRowsFollowSelectedMode() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let directBundle = projectURL.appendingPathComponent("Runs/A.lungfishfastq", isDirectory: true)
        let nestedBundle = projectURL
            .appendingPathComponent("Runs/Nested/C.lungfishfastq", isDirectory: true)
        let folder = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(title: "A", type: .fastqBundle, url: directBundle),
                SidebarItem(
                    title: "Nested",
                    type: .folder,
                    children: [
                        SidebarItem(title: "C", type: .fastqBundle, url: nestedBundle),
                    ],
                    url: projectURL.appendingPathComponent("Runs/Nested", isDirectory: true)
                ),
            ],
            url: projectURL.appendingPathComponent("Runs", isDirectory: true)
        )

        let selection = WorkflowSidebarInputSelection.resolve(items: [folder], projectURL: projectURL)

        XCTAssertEqual(selection.detailRows(includeSubfolders: false).map(\.url), selection.directReadURLs)
        XCTAssertEqual(selection.detailRows(includeSubfolders: true).map(\.url), selection.recursiveReadURLs)
    }
}
