import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class FASTQBundleMergeServiceTests: XCTestCase {
    private enum FixtureError: Error {
        case provenanceWriteFailed
    }

    private func requireManagedTool(_ tool: NativeTool) async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: tool)) != nil else {
            throw XCTSkip("Managed \(tool.rawValue) is not available")
        }
    }

    func testMergeCreatesVirtualBundleForSingleEndPhysicalInputs() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try makeBundle(
            root: root,
            name: "A",
            fastqName: "reads.fastq",
            contents: "@r1\nACGT\n+\nIIII\n",
            pairing: .singleEnd
        )
        let second = try makeBundle(
            root: root,
            name: "B",
            fastqName: "reads.fastq",
            contents: "@r2\nTTTT\n+\nIIII\n",
            pairing: .singleEnd
        )

        let mergedURL = try await FASTQBundleMergeService.merge(
            sourceBundleURLs: [first, second],
            outputDirectory: root,
            bundleName: "Merged Reads"
        )

        XCTAssertTrue(FASTQSourceFileManifest.exists(in: mergedURL))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: mergedURL.appendingPathComponent("preview.fastq").path
            )
        )

        let manifest = try XCTUnwrap(try? FASTQSourceFileManifest.load(from: mergedURL))
        XCTAssertEqual(manifest.files.count, 2)

        let resolvedFASTQs = try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: mergedURL))
        XCTAssertEqual(resolvedFASTQs.count, 2)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: mergedURL))
        assertMergeProvenance(
            provenance,
            expectedWorkflowName: "lungfish fastq merge",
            expectedBundleName: "Merged Reads",
            expectedOutputBundle: mergedURL,
            expectedOutputFilenames: [
                FASTQSourceFileManifest.filename,
                "preview.fastq",
                FASTQBundleCSVMetadata.filename,
            ],
            disallowedPathFragments: ["fastq-merge-"]
        )
    }

    func testMergeCreatesMaterializedBundleForInterleavedInputs() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstContents = "@r1/1\nACGT\n+\nIIII\n@r1/2\nTGCA\n+\nIIII\n"
        let secondContents = "@r2/1\nCCCC\n+\nIIII\n@r2/2\nGGGG\n+\nIIII\n"

        let first = try makeBundle(
            root: root,
            name: "A",
            fastqName: "reads.fastq",
            contents: firstContents,
            pairing: .interleaved
        )
        let second = try makeBundle(
            root: root,
            name: "B",
            fastqName: "reads.fastq",
            contents: secondContents,
            pairing: .interleaved
        )

        let mergedURL = try await FASTQBundleMergeService.merge(
            sourceBundleURLs: [first, second],
            outputDirectory: root,
            bundleName: "Merged Interleaved"
        )

        XCTAssertFalse(FASTQSourceFileManifest.exists(in: mergedURL))

        let mergedFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: mergedURL))
        XCTAssertEqual(mergedFASTQ.lastPathComponent, "reads.fastq")
        XCTAssertEqual(
            FASTQMetadataStore.load(for: mergedFASTQ)?.ingestion?.pairingMode,
            .interleaved
        )
        XCTAssertEqual(
            try String(contentsOf: mergedFASTQ, encoding: .utf8),
            firstContents + secondContents
        )

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: mergedURL))
        assertMergeProvenance(
            provenance,
            expectedWorkflowName: "lungfish fastq merge",
            expectedBundleName: "Merged Interleaved",
            expectedOutputBundle: mergedURL,
            expectedOutputFilenames: [
                "reads.fastq",
                FASTQMetadataStore.metadataURL(for: mergedFASTQ).lastPathComponent,
                FASTQBundleCSVMetadata.filename,
            ],
            disallowedPathFragments: ["fastq-merge-", "interleaved-"]
        )
    }

    func testMergeProvenanceRecordsBothPairedMatesAndReformatStep() async throws {
        try await requireManagedTool(.reformat)

        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try makePairedBundle(
            root: root,
            name: "A",
            r1Contents: "@a1/1\nACGT\n+\nIIII\n",
            r2Contents: "@a1/2\nTGCA\n+\nIIII\n"
        )
        let second = try makePairedBundle(
            root: root,
            name: "B",
            r1Contents: "@b1/1\nCCCC\n+\nIIII\n",
            r2Contents: "@b1/2\nGGGG\n+\nIIII\n"
        )

        let mergedURL = try await FASTQBundleMergeService.merge(
            sourceBundleURLs: [first.bundleURL, second.bundleURL],
            outputDirectory: root,
            bundleName: "Merged Paired"
        )

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: mergedURL))
        assertProvenanceInputs(
            provenance,
            include: [
                first.r1URL.path,
                first.r2URL.path,
                second.r1URL.path,
                second.r2URL.path,
            ]
        )
        let reformatSteps = provenance.steps.filter { step in
            step.toolName == "reformat.sh" || step.argv.contains { $0.contains("reformat.sh") }
        }
        XCTAssertEqual(reformatSteps.count, 2)
        for step in reformatSteps {
            XCTAssertTrue(step.argv.contains { $0.contains("in1=") })
            XCTAssertTrue(step.argv.contains { $0.contains("in2=") })
            XCTAssertTrue(step.argv.contains { $0.contains("out=") })
            XCTAssertNotNil(step.stderr)
        }
    }

    func testMergeProvenanceRecordsDerivedBundleManifestAndPayloadInputs() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let rootBundle = try makeBundle(
            root: root,
            name: "Root",
            fastqName: "reads.fastq",
            contents: "@r1\nACGT\n+\nIIII\n@r2\nTTTT\n+\nIIII\n",
            pairing: .singleEnd
        )
        let derived = try makeDerivedFullBundle(
            root: root,
            name: "Derived",
            rootBundleURL: rootBundle,
            fastqName: "derived.fastq",
            contents: "@r1\nACGT\n+\nIIII\n"
        )
        let physical = try makeBundle(
            root: root,
            name: "Physical",
            fastqName: "reads.fastq",
            contents: "@r3\nCCCC\n+\nIIII\n",
            pairing: .singleEnd
        )

        let mergedURL = try await FASTQBundleMergeService.merge(
            sourceBundleURLs: [derived.bundleURL, physical],
            outputDirectory: root,
            bundleName: "Merged Derived"
        )

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: mergedURL))
        assertProvenanceInputs(
            provenance,
            include: [
                derived.manifestURL.path,
                derived.fastqURL.path,
                physical.appendingPathComponent("reads.fastq").path,
            ]
        )
    }

    func testMergeRemovesPartialFASTQBundleWhenProvenanceWriteFails() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try makeBundle(
            root: root,
            name: "A",
            fastqName: "reads.fastq",
            contents: "@r1\nACGT\n+\nIIII\n",
            pairing: .singleEnd
        )
        let second = try makeBundle(
            root: root,
            name: "B",
            fastqName: "reads.fastq",
            contents: "@r2\nTTTT\n+\nIIII\n",
            pairing: .singleEnd
        )
        let expectedOutput = root.appendingPathComponent("Failed Merge.lungfishfastq", isDirectory: true)

        do {
            _ = try await FASTQBundleMergeService.merge(
                sourceBundleURLs: [first, second],
                outputDirectory: root,
                bundleName: "Failed Merge",
                provenanceWriter: BundleMergeProvenanceSidecarWriter { _, _ in
                    throw FixtureError.provenanceWriteFailed
                }
            )
            XCTFail("Expected merge to fail when provenance cannot be written")
        } catch FixtureError.provenanceWriteFailed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: expectedOutput.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertProvenanceInputs(
        _ provenance: ProvenanceEnvelope,
        include expectedPaths: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let inputPaths = Set(provenance.files.filter { $0.role == .input }.map(\.path))
        for expectedPath in expectedPaths {
            XCTAssertTrue(inputPaths.contains(expectedPath), "Missing input \(expectedPath)", file: file, line: line)
        }
    }

    private func assertMergeProvenance(
        _ provenance: ProvenanceEnvelope,
        expectedWorkflowName: String,
        expectedBundleName: String,
        expectedOutputBundle: URL,
        expectedOutputFilenames: Set<String>,
        disallowedPathFragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(provenance.workflowName, expectedWorkflowName, file: file, line: line)
        XCTAssertEqual(provenance.toolName, "lungfish-app", file: file, line: line)
        XCTAssertFalse(provenance.toolVersion.isEmpty, file: file, line: line)
        XCTAssertEqual(provenance.exitStatus, 0, file: file, line: line)
        XCTAssertNotNil(provenance.wallTimeSeconds, file: file, line: line)
        XCTAssertEqual(provenance.options.explicit["bundleName"]?.stringValue, expectedBundleName, file: file, line: line)
        XCTAssertEqual(
            provenance.options.explicit["outputBundle"]?.fileValue?.path,
            expectedOutputBundle.path,
            file: file,
            line: line
        )

        let outputPaths = provenance.outputs.map(\.path)
        for filename in expectedOutputFilenames {
            XCTAssertTrue(
                outputPaths.contains { $0.hasPrefix(expectedOutputBundle.path) && $0.hasSuffix("/\(filename)") },
                "Missing provenance output for \(filename)",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            provenance.outputs.allSatisfy { $0.path.hasPrefix(expectedOutputBundle.path) },
            "All output records must point inside the final bundle",
            file: file,
            line: line
        )
        for record in provenance.files {
            XCTAssertNotNil(record.checksumSHA256, "Missing checksum for \(record.path)", file: file, line: line)
            XCTAssertNotNil(record.fileSize, "Missing file size for \(record.path)", file: file, line: line)
        }

        let provenanceText = (
            provenance.argv
            + [provenance.reproducibleCommand]
            + provenance.files.map(\.path)
            + provenance.steps.flatMap { $0.argv + [$0.reproducibleCommand] + $0.inputs.map(\.path) + $0.outputs.map(\.path) }
        )
        .joined(separator: "\n")
        for fragment in disallowedPathFragments {
            XCTAssertFalse(provenanceText.contains(fragment), file: file, line: line)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBundleMergeServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBundle(
        root: URL,
        name: String,
        fastqName: String,
        contents: String,
        pairing: IngestionMetadata.PairingMode
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent(
            "\(name).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastqURL = bundleURL.appendingPathComponent(fastqName)
        try contents.write(to: fastqURL, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: pairing)),
            for: fastqURL
        )

        return bundleURL
    }

    private func makePairedBundle(
        root: URL,
        name: String,
        r1Contents: String,
        r2Contents: String
    ) throws -> (bundleURL: URL, r1URL: URL, r2URL: URL) {
        let bundleURL = root.appendingPathComponent(
            "\(name).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let r1URL = bundleURL.appendingPathComponent("reads_R1.fastq")
        let r2URL = bundleURL.appendingPathComponent("reads_R2.fastq")
        try r1Contents.write(to: r1URL, atomically: true, encoding: .utf8)
        try r2Contents.write(to: r2URL, atomically: true, encoding: .utf8)
        for url in [r1URL, r2URL] {
            FASTQMetadataStore.save(
                PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .pairedEnd)),
                for: url
            )
        }
        return (bundleURL, r1URL, r2URL)
    }

    private func makeDerivedFullBundle(
        root: URL,
        name: String,
        rootBundleURL: URL,
        fastqName: String,
        contents: String
    ) throws -> (bundleURL: URL, manifestURL: URL, fastqURL: URL) {
        let bundleURL = root.appendingPathComponent(
            "\(name).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastqURL = bundleURL.appendingPathComponent(fastqName)
        try contents.write(to: fastqURL, atomically: true, encoding: .utf8)

        let operation = FASTQDerivativeOperation(kind: .subsampleCount, count: 1)
        let manifest = FASTQDerivedBundleManifest(
            name: name,
            parentBundleRelativePath: "../\(rootBundleURL.lastPathComponent)",
            rootBundleRelativePath: "../\(rootBundleURL.lastPathComponent)",
            rootFASTQFilename: "reads.fastq",
            payload: .full(fastqFilename: fastqName),
            lineage: [operation],
            operation: operation,
            cachedStatistics: .empty,
            pairingMode: .singleEnd
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        return (
            bundleURL,
            bundleURL.appendingPathComponent(FASTQBundle.derivedManifestFilename),
            fastqURL
        )
    }
}
