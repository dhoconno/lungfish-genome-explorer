import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

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
            let text = try readRepositorySource(provenanceJSON)
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
        XCTAssertEqual(try readRepositorySource(destinationFASTQURL), "@r1\nACGT\n+\n!!!!\n")

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
        XCTAssertEqual(try readRepositorySource(fixture.output.appendingPathComponent("old.txt")), "previous")
        XCTAssertEqual(try readRepositorySource(fixture.output.appendingPathComponent(ProvenanceWriter.provenanceFilename)), "previous provenance")
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
        XCTAssertEqual(try readRepositorySource(fixture.source.appendingPathComponent("reads.fastq")), "@fixture\nACGT\n+\n!!!!\n")
    }

    // MARK: - Payloads that differ from the source record (CHTC program lane L2-COPYCHECK)

    func testCopyImportRefusesPayloadThatDiffersFromItsRecord() throws {
        let fixture = try recordedBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // A transfer cut short leaves the reads shorter than the record says.
        let complete = try Data(contentsOf: fixture.reads)
        try complete.prefix(complete.count / 2).write(to: fixture.reads)

        XCTAssertThrowsError(try copy(fixture)) { error in
            XCTAssertEqual(
                error as? FASTQBundleCopyImportError,
                .payloadDoesNotMatchRecord(fixture.reads.standardizedFileURL.path)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "reads.fastq does not match its provenance record and may be incomplete. Copy it again and retry."
            )
        }
        assertNothingPublished(fixture)
    }

    func testCopyImportRefusesPayloadWithTheRecordedSizeButOtherBytes() throws {
        let fixture = try recordedBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var bytes = try Data(contentsOf: fixture.reads)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: fixture.reads)

        XCTAssertThrowsError(try copy(fixture)) { error in
            XCTAssertEqual(
                error as? FASTQBundleCopyImportError,
                .payloadDoesNotMatchRecord(fixture.reads.standardizedFileURL.path)
            )
        }
        assertNothingPublished(fixture)
    }

    func testCopyImportKeepsFilesTheRecordDoesNotHash() throws {
        let fixture = try recordedBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // The record names the reads but states no digest and no size, so there is nothing to compare.
        let unhashed = ProvenanceFileDescriptor(path: fixture.reads.path, format: .fastq, role: .output)
        try writeRecord(in: fixture.source, outputs: [unhashed])
        let complete = try Data(contentsOf: fixture.reads)
        try complete.prefix(complete.count / 2).write(to: fixture.reads)

        let result = try copy(fixture)

        XCTAssertEqual(result.bundleURL, fixture.destination.standardizedFileURL)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("reads.fastq")),
            try Data(contentsOf: fixture.reads)
        )
    }

    func testCopyImportKeepsBundleWhoseRecordListsNoOutputs() throws {
        let fixture = try recordedBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Only the step names the reads, so the record holds no output list to compare against.
        let hashed = try ProvenanceFileDescriptor.file(url: fixture.reads, format: .fastq, role: .output)
        try writeRecord(in: fixture.source, outputs: [], stepOutputs: [hashed])
        let complete = try Data(contentsOf: fixture.reads)
        try complete.prefix(complete.count / 2).write(to: fixture.reads)

        let result = try copy(fixture)

        XCTAssertEqual(result.bundleURL, fixture.destination.standardizedFileURL)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("reads.fastq")),
            try Data(contentsOf: fixture.reads)
        )
    }

    /// `lungfish fastq platform` and the metadata editors rewrite `<reads>.lungfish-meta.json` after the import,
    /// and leave the import's record alone, so the check covers the reads and not the metadata beside them.
    func testCopyImportKeepsMetadataThatChangedAfterTheRecord() throws {
        let fixture = try recordedBundleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sidecar = fixture.source.appendingPathComponent("reads.fastq.lungfish-meta.json")
        try #"{"platform":"illumina"}"#.write(to: sidecar, atomically: true, encoding: .utf8)
        let reads = try ProvenanceFileDescriptor.file(url: fixture.reads, format: .fastq, role: .output)
        let metadata = try ProvenanceFileDescriptor.file(url: sidecar, format: .json, role: .output)
        try writeRecord(in: fixture.source, outputs: [reads, metadata])
        try #"{"platform":"ont"}"#.write(to: sidecar, atomically: true, encoding: .utf8)

        _ = try copy(fixture)

        XCTAssertEqual(
            try readRepositorySource(fixture.destination.appendingPathComponent("reads.fastq.lungfish-meta.json")),
            #"{"platform":"ont"}"#
        )
    }

    private typealias RecordedBundleFixture = (root: URL, source: URL, reads: URL, destination: URL)

    /// A source bundle whose record states the digest and size of `reads.fastq` as it was written.
    private func recordedBundleFixture() throws -> RecordedBundleFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleCopyRecordCheck-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let reads = source.appendingPathComponent("reads.fastq")
        let text = (1...50).map { "@r\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try text.write(to: reads, atomically: true, encoding: .utf8)
        try writeSourceFASTQBundleProvenance(bundleURL: source, fastqURL: reads)
        return (root, source, reads, root.appendingPathComponent("copied.lungfishfastq", isDirectory: true))
    }

    private func copy(_ fixture: RecordedBundleFixture) throws -> FASTQBundleCopyImportResult {
        try FASTQBundleCopyImportWorkflow().importBundle(
            sourceBundleURL: fixture.source,
            outputURL: fixture.destination,
            context: replacementContext()
        )
    }

    private func assertNothingPublished(_ fixture: RecordedBundleFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path), file: file, line: line)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: fixture.root.path)) ?? []
        XCTAssertFalse(
            entries.contains { $0.hasPrefix(".copied.") },
            "A refused copy must discard its staged bundle: \(entries)",
            file: file,
            line: line
        )
    }

    /// A record whose top-level output list is `outputs` and whose one step lists `stepOutputs`, which are
    /// `outputs` unless given.
    private func writeRecord(
        in bundleURL: URL,
        outputs: [ProvenanceFileDescriptor],
        stepOutputs: [ProvenanceFileDescriptor]? = nil
    ) throws {
        let step = ProvenanceStep(
            toolName: "source-fastq-tool",
            toolVersion: "1.0",
            argv: ["source-fastq-tool"],
            outputs: stepOutputs ?? outputs,
            exitStatus: 0,
            wallTimeSeconds: 0.1
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "source FASTQ bundle",
            workflowVersion: "1.0",
            toolName: "source-fastq-tool",
            toolVersion: "1.0",
            argv: ["source-fastq-tool"],
            files: outputs,
            output: outputs.first,
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: 0.1,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
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
