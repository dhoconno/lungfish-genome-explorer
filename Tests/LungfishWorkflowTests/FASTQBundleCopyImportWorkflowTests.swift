import XCTest
@testable import LungfishWorkflow

final class FASTQBundleCopyImportWorkflowTests: XCTestCase {
    func testImportCopiesIntoHiddenStagingBundleBeforePublishing() throws {
        let source = try String(
            contentsOf: packageRoot()
                .appendingPathComponent("Sources/LungfishWorkflow/Ingestion/FASTQBundleCopyImportWorkflow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("copyItem(at: sourceBundleURL, to: stagingBundleURL)"))
        XCTAssertTrue(source.contains("publication.publish(stagedURL: stagingBundleURL, to: destinationBundleURL, replacingExisting: replaceExisting)"))
        XCTAssertFalse(
            source.contains("copyItem(at: sourceBundleURL, to: destinationBundleURL)"),
            "FASTQ bundle import must not publish a visible destination before provenance is written."
        )
    }

    func testFailedImportCleanupOnlyRemovesOwnedStagingBundle() throws {
        let source = try String(
            contentsOf: packageRoot()
                .appendingPathComponent("Sources/LungfishWorkflow/Ingestion/FASTQBundleCopyImportWorkflow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("removeItem(at: stagingBundleURL)"))
        XCTAssertTrue(
            source.contains("publication.rollback(after: error)"),
            "Destination restoration must use the transaction receipt and preserve recovery artifacts."
        )
    }

    func testImportProvenanceUsesFinalBundlePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleCopyImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceBundleURL = root.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        let sourceFASTQURL = sourceBundleURL.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\n!!!!\n".write(
            to: sourceFASTQURL,
            atomically: true,
            encoding: .utf8
        )
        try writeSourceFASTQBundleProvenance(bundleURL: sourceBundleURL, fastqURL: sourceFASTQURL)

        let destinationBundleURL = root
            .appendingPathComponent("imports", isDirectory: true)
            .appendingPathComponent("copied.lungfishfastq", isDirectory: true)
        let workflow = FASTQBundleCopyImportWorkflow()
        let result = try workflow.importBundle(
            sourceBundleURL: sourceBundleURL,
            outputURL: destinationBundleURL,
            context: FASTQBundleCopyImportWorkflow.CommandContext(
                workflowName: "test fastq bundle import",
                toolName: "lungfish-cli",
                argv: ["lungfish", "fastq", "import-bundle", sourceBundleURL.path]
            )
        )

        XCTAssertEqual(result.bundleURL, destinationBundleURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationBundleURL.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: destinationBundleURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.hasPrefix(".copied.") },
            "Hidden staging bundles must be removed after publication."
        )

        let provenanceURL = destinationBundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: try Data(contentsOf: provenanceURL)
        )
        let allPaths = envelope.files.map(\.path) + envelope.outputs.map(\.path)
        XCTAssertTrue(allPaths.contains(destinationBundleURL.path))
        XCTAssertTrue(allPaths.contains(destinationBundleURL.appendingPathComponent("reads.fastq").path))
        XCTAssertFalse(allPaths.contains { $0.contains("/.copied.") || $0.contains(".processing") })
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "source-fastq-tool" })
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "lungfish-cli" })
        XCTAssertFalse(envelope.steps.flatMap(\.outputs).contains { $0.path.hasPrefix(sourceBundleURL.path) })
    }

    func testImportRejectsFASTQBundleWithoutReadableSourceProvenance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleCopyImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceBundleURL = root.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\n!!!!\n".write(
            to: sourceBundleURL.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )
        let destinationBundleURL = root.appendingPathComponent("copied.lungfishfastq", isDirectory: true)

        XCTAssertThrowsError(
            try FASTQBundleCopyImportWorkflow().importBundle(
                sourceBundleURL: sourceBundleURL,
                outputURL: destinationBundleURL,
                context: FASTQBundleCopyImportWorkflow.CommandContext(
                    workflowName: "test fastq bundle import",
                    toolName: "lungfish-cli",
                    argv: ["lungfish", "fastq", "import-bundle", sourceBundleURL.path]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? FASTQBundleCopyImportError,
                .sourceProvenanceMissing(sourceBundleURL.standardizedFileURL.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationBundleURL.path))
    }

    func testImportScrubsCopiedProvenanceArtifactsBeforeWritingDestinationProvenance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleCopyImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceBundleURL = root.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        let sourceFASTQURL = sourceBundleURL.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\n!!!!\n".write(to: sourceFASTQURL, atomically: true, encoding: .utf8)
        try writeSourceFASTQBundleProvenance(bundleURL: sourceBundleURL, fastqURL: sourceFASTQURL)

        let sourceProvenanceDirectoryURL = sourceBundleURL.appendingPathComponent(
            ProvenanceWriter.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sourceProvenanceDirectoryURL, withIntermediateDirectories: true)
        try #"{"stale":"stale-source-marker"}"#.write(
            to: sourceProvenanceDirectoryURL.appendingPathComponent("stale.lungfish-provenance.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"stale":"stale-source-marker"}"#.write(
            to: sourceBundleURL.appendingPathComponent("reads.fastq.lungfish-provenance.json"),
            atomically: true,
            encoding: .utf8
        )

        let destinationBundleURL = root.appendingPathComponent("copied.lungfishfastq", isDirectory: true)
        _ = try FASTQBundleCopyImportWorkflow().importBundle(
            sourceBundleURL: sourceBundleURL,
            outputURL: destinationBundleURL,
            context: FASTQBundleCopyImportWorkflow.CommandContext(
                workflowName: "test fastq bundle import",
                toolName: "lungfish-cli",
                argv: ["lungfish", "fastq", "import-bundle", sourceBundleURL.path]
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationBundleURL.appendingPathComponent("reads.fastq.lungfish-provenance.json").path
            )
        )
        for provenanceJSON in try provenanceJSONFiles(in: destinationBundleURL) {
            let text = try String(contentsOf: provenanceJSON, encoding: .utf8)
            XCTAssertFalse(text.contains("stale-source-marker"))
            _ = try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: provenanceJSON)
        }
    }

    func testImportMaterializesSymlinkPayloadsInsideDestinationBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleCopyImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let externalFASTQURL = root.appendingPathComponent("external.fastq")
        try "@r1\nACGT\n+\n!!!!\n".write(to: externalFASTQURL, atomically: true, encoding: .utf8)

        let sourceBundleURL = root.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        let symlinkFASTQURL = sourceBundleURL.appendingPathComponent("reads.fastq")
        try FileManager.default.createSymbolicLink(at: symlinkFASTQURL, withDestinationURL: externalFASTQURL)
        try writeSourceFASTQBundleProvenance(bundleURL: sourceBundleURL, fastqURL: symlinkFASTQURL)

        let destinationBundleURL = root.appendingPathComponent("copied.lungfishfastq", isDirectory: true)
        _ = try FASTQBundleCopyImportWorkflow().importBundle(
            sourceBundleURL: sourceBundleURL,
            outputURL: destinationBundleURL,
            context: FASTQBundleCopyImportWorkflow.CommandContext(
                workflowName: "test fastq bundle import",
                toolName: "lungfish-cli",
                argv: ["lungfish", "fastq", "import-bundle", sourceBundleURL.path]
            )
        )

        let destinationFASTQURL = destinationBundleURL.appendingPathComponent("reads.fastq")
        let destinationValues = try destinationFASTQURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertFalse(destinationValues.isSymbolicLink == true)
        XCTAssertEqual(try String(contentsOf: destinationFASTQURL, encoding: .utf8), "@r1\nACGT\n+\n!!!!\n")

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: destinationBundleURL))
        let allPaths = envelope.files.map(\.path) + envelope.outputs.map(\.path)
        XCTAssertTrue(allPaths.contains(destinationFASTQURL.path))
        XCTAssertFalse(allPaths.contains(externalFASTQURL.path), allPaths.joined(separator: "\n"))
        XCTAssertFalse(allPaths.contains(destinationBundleURL.appendingPathComponent("external.fastq").path))
    }

    private func packageRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func testReplacingExistingBundlePublishesNewPayloadAndFinalProvenance() throws {
        let fixture = try replacementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try FASTQBundleCopyImportWorkflow().importBundle(sourceBundleURL: fixture.source,
            outputURL: fixture.output, context: replacementContext(), replaceExisting: true)
        XCTAssertEqual(try Data(contentsOf: result.bundleURL.appendingPathComponent("reads.fastq")),
            try Data(contentsOf: fixture.source.appendingPathComponent("reads.fastq")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("old.txt").path))
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.output))
        XCTAssertTrue(envelope.outputs.contains { $0.path == fixture.output.appendingPathComponent("reads.fastq").path })
    }

    func testReplacementProvenanceFailurePreservesOldBundle() throws {
        let fixture = try replacementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = ProvenanceWriter(publicationMutationDidOccur: { _ in
            throw NSError(domain: "replacement-writer-fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "replacement writer fixture"])
        }, signingProvider: nil)
        XCTAssertThrowsError(try FASTQBundleCopyImportWorkflow(provenanceWriter: writer).importBundle(
            sourceBundleURL: fixture.source, outputURL: fixture.output, context: replacementContext(), replaceExisting: true)) { error in
            XCTAssertTrue(String(reflecting: error).contains("replacement"), "Must reach injected writer failure: \(error)")
        }
        XCTAssertEqual(try String(contentsOf: fixture.output.appendingPathComponent("old.txt"), encoding: .utf8), "previous")
        XCTAssertEqual(try String(contentsOf: fixture.output.appendingPathComponent(ProvenanceWriter.provenanceFilename), encoding: .utf8), "previous provenance")
    }

    func testReplacementRejectsSourceDestinationAlias() throws {
        let fixture = try replacementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.root.appendingPathComponent("alias.lungfishfastq")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
        for output in [fixture.source, alias] {
            XCTAssertThrowsError(try FASTQBundleCopyImportWorkflow().importBundle(sourceBundleURL: fixture.source,
                outputURL: output, context: replacementContext(), replaceExisting: true))
        }
        XCTAssertEqual(try String(contentsOf: fixture.source.appendingPathComponent("reads.fastq"), encoding: .utf8), "@fixture\nACGT\n+\n!!!!\n")
    }

    private func replacementContext() -> FASTQBundleCopyImportWorkflow.CommandContext {
        .init(workflowName: "replacement fixture", toolName: "fixture", argv: ["fixture"])
    }

    private func replacementFixture() throws -> (root: URL, source: URL, output: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fastq-replace-\(UUID())")
        let source = root.appendingPathComponent("source.lungfishfastq")
        let output = root.appendingPathComponent("output.lungfishfastq")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reads = source.appendingPathComponent("reads.fastq")
        try "@fixture\nACGT\n+\n!!!!\n".write(to: reads, atomically: true, encoding: .utf8)
        try writeSourceFASTQBundleProvenance(bundleURL: source, fastqURL: reads)
        try "previous".write(to: output.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try "previous provenance".write(to: output.appendingPathComponent(ProvenanceWriter.provenanceFilename), atomically: true, encoding: .utf8)
        return (root, source, output)
    }

    private func writeSourceFASTQBundleProvenance(bundleURL: URL, fastqURL: URL) throws {
        let output = try ProvenanceFileDescriptor.file(url: fastqURL, format: .fastq, role: .output)
        let step = ProvenanceStep(
            toolName: "source-fastq-tool",
            toolVersion: "1.0",
            argv: ["source-fastq-tool", fastqURL.path],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 0.1
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "source FASTQ bundle",
            workflowVersion: "1.0",
            toolName: "source-fastq-tool",
            toolVersion: "1.0",
            argv: ["source-fastq-tool", fastqURL.path],
            files: [output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: 0.1,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private func provenanceJSONFiles(in bundleURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".json") {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }
}
