import XCTest
@testable import LungfishApp
@testable import LungfishKit

final class ClassifierAlignmentEvidenceValidatorTests: XCTestCase {
    func testValidatesExplicitIndexContigAndExactReferenceRecord() async throws {
        let files = try FixtureFiles()
        let request = try files.request(reference: true)
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\tM5:86bfb9f78dd8b6cd35962bb7324fdbf8\n" },
            indexQuery: { _, _, _ in },
            fileManager: files.fileManager
        )

        let result = try await validator.validate(request)

        XCTAssertEqual(result.contig.name, "chr1")
        XCTAssertEqual(result.reference.sequence, "ACTG")
        XCTAssertEqual(result.reference.status, .validatedMD5)
        XCTAssertEqual(result.provider.alignmentPath, files.bam.path)
        XCTAssertEqual(result.provider.indexPath, files.index.path)
    }

    func testCRAMRequiresValidatedDecodeReferenceAndInstallsItOnProvider() async throws {
        let files = try FixtureFiles()
        let cram = files.directory.appendingPathComponent("evidence.cram")
        let crai = files.directory.appendingPathComponent("evidence.cram.crai")
        try Data([0x43, 0x52, 0x41, 0x4d]).write(to: cram)
        try Data([0x43, 0x52, 0x41, 0x49]).write(to: crai)
        let request = try files.request(
            reference: true,
            indexURL: crai,
            indexKind: .crai,
            bamURL: cram
        )
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" },
            indexQuery: { actualCRAM, actualCRAI, contig in
                XCTAssertEqual(actualCRAM, cram)
                XCTAssertEqual(actualCRAI, crai)
                XCTAssertEqual(contig, "chr1")
            },
            fileManager: files.fileManager
        )

        let result = try await validator.validate(request)
        XCTAssertEqual(result.provider.format, .cram)
        XCTAssertEqual(result.provider.referenceFastaPath, files.fasta.path)
        XCTAssertNotNil(result.referenceSnapshot)

        let missingReference = try files.request(
            reference: false,
            indexURL: crai,
            indexKind: .crai,
            bamURL: cram
        )
        await XCTAssertThrowsErrorAsync(try await validator.validate(missingReference)) { error in
            XCTAssertEqual(error as? ClassifierAlignmentEvidenceValidator.Error, .decodingReferenceRequired(cram))
        }
    }

    func testAcceptsValidDescendantEvidenceForEveryClassifierLeaf() async throws {
        let files = try FixtureFiles()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
        )
        for workflow in [ClassifierAlignmentWorkflowKind.esViritu, .taxTriage, .nvd] {
            _ = try await validator.validate(try files.request(reference: true, workflow: workflow))
        }
    }

    func testValidatesExplicitCSIIndex() async throws {
        let files = try FixtureFiles()
        let csi = files.directory.appendingPathComponent("evidence.bam.csi")
        let bam = files.bam
        try Data([0x43, 0x53, 0x49]).write(to: csi)
        let request = try files.request(reference: false, indexURL: csi, indexKind: .csi)
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" }, indexQuery: { actualBAM, index, contig in
                guard actualBAM == bam, index == csi, contig == "chr1" else { throw FixtureError.badIndex }
            }, fileManager: files.fileManager
        )
        let result = try await validator.validate(request)
        XCTAssertEqual(result.provider.indexPath, csi.path)
    }

    func testMissingOrUnreadableIndexFailsClosed() async throws {
        let files = try FixtureFiles()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" },
            indexQuery: { _, _, _ in },
            fileManager: files.fileManager
        )
        try files.fileManager.removeItem(at: files.index)

        await XCTAssertThrowsErrorAsync(try await validator.validate(try files.request(reference: false))) { error in
            XCTAssertEqual(error as? ClassifierAlignmentEvidenceValidator.Error, .indexUnavailable(files.index))
            XCTAssertEqual(error.localizedDescription, "The explicit BAM index is unavailable: evidence.bam.bai.")
        }
    }

    func testIndexMismatchUnknownContigAndLengthMismatchFailClosed() async throws {
        let files = try FixtureFiles()
        let mismatch = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" },
            indexQuery: { _, _, _ in throw FixtureError.badIndex },
            fileManager: files.fileManager
        )
        await XCTAssertThrowsErrorAsync(try await mismatch.validate(try files.request(reference: false)))

        let unknown = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:other\tLN:4\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
        )
        await XCTAssertThrowsErrorAsync(try await unknown.validate(try files.request(reference: false)))

        let length = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:5\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
        )
        await XCTAssertThrowsErrorAsync(try await length.validate(try files.request(reference: false)))
    }

    func testInvalidReferenceFallsBackWithoutInferringBases() async throws {
        let files = try FixtureFiles(fasta: ">chr1\nAAAAA\n")
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
        )

        let result = try await validator.validate(try files.request(reference: true))

        XCTAssertEqual(result.reference.status, .unavailable)
        XCTAssertNil(result.reference.sequence)
        XCTAssertNotNil(result.reference.reason)
    }

    func testReferenceMD5MismatchFallsBackButDoesNotInvalidateEvidence() async throws {
        let files = try FixtureFiles()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\tM5:bad\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
        )

        let result = try await validator.validate(try files.request(reference: true))
        XCTAssertEqual(result.reference.status, .unavailable)
        XCTAssertNil(result.reference.sequence)
    }

    func testDuplicateMatchingFASTARecordIsRejected() async throws {
        let files = try FixtureFiles(fasta: ">chr1\nACTG\n>chr1 duplicate\nACTG\n")
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
        )

        let result = try await validator.validate(try files.request(reference: true))

        XCTAssertEqual(result.reference.status, .unavailable)
        XCTAssertNil(result.reference.sequence)
    }

    func testFASTAReplacementDuringReferenceReadIsRejectedByStableSnapshotCheck() async throws {
        let files = try FixtureFiles()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" },
            indexQuery: { _, _, _ in },
            referenceReader: { url, _ in
                try ">chr1\nTGCA\n".write(to: url, atomically: true, encoding: .utf8)
                return "ACTG"
            },
            fileManager: files.fileManager
        )

        let result = try await validator.validate(try files.request(reference: true))

        XCTAssertEqual(result.reference.status, .unavailable)
        XCTAssertNil(result.reference.sequence)
        XCTAssertEqual(result.reference.reason, "The requested FASTA record is unavailable.")
    }

    func testTargetFASTARecordMayAppearFirstMiddleOrLast() async throws {
        for fasta in [
            ">chr1\nACTG\n>other\nTT\n",
            ">other\nTT\n>chr1\nACTG\n>last\nGG\n",
            ">other\nTT\n>last\nGG\n>chr1\nACTG\n",
        ] {
            let files = try FixtureFiles(fasta: fasta)
            let validator = ClassifierAlignmentEvidenceValidator(
                headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
            )
            let result = try await validator.validate(try files.request(reference: true))
            XCTAssertEqual(result.reference.sequence, "ACTG")
        }
    }

    func testFinalEvidenceSnapshotsRejectChangedBAMAndExposeAcceptedIdentities() async throws {
        let files = try FixtureFiles()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
        )
        let first = try await validator.validate(try files.request(reference: true))
        XCTAssertEqual(first.bamSnapshot.size, 3)
        XCTAssertEqual(first.indexSnapshot.size, 3)
        XCTAssertNotNil(first.referenceSnapshot)

        let request = try files.request(reference: false, bamSnapshot: first.bamSnapshot)
        try Data([0x00, 0x01]).write(to: files.bam)
        await XCTAssertThrowsErrorAsync(try await validator.validate(request)) { error in
            XCTAssertEqual(error as? ClassifierAlignmentEvidenceValidator.Error, .snapshotMismatch(files.bam))
        }
    }

    func testRejectsEvidenceOutsideFinalResultByPathComponentForEveryClassifierLeaf() async throws {
        let files = try FixtureFiles()
        let outside = files.directory.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).bam")
        try Data([0]).write(to: outside)
        defer { try? files.fileManager.removeItem(at: outside) }
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
        )
        for workflow in [ClassifierAlignmentWorkflowKind.esViritu, .taxTriage, .nvd] {
            let request = try files.request(reference: false, workflow: workflow, bamURL: outside)
            await XCTAssertThrowsErrorAsync(try await validator.validate(request)) { error in
                XCTAssertEqual(error as? ClassifierAlignmentEvidenceValidator.Error, .evidenceOutsideFinalResult(outside))
            }
        }
    }

    func testRejectsSiblingPrefixTraversalAndSymlinkEscapesForBAMIndexAndReference() async throws {
        let files = try FixtureFiles()
        let parent = files.directory.deletingLastPathComponent()
        let siblingPrefix = parent.appendingPathComponent(files.directory.lastPathComponent + "-sibling")
        try files.fileManager.createDirectory(at: siblingPrefix, withIntermediateDirectories: true)
        defer { try? files.fileManager.removeItem(at: siblingPrefix) }
        let external = siblingPrefix.appendingPathComponent("external")
        try Data([1]).write(to: external)
        let escaped = files.directory.appendingPathComponent("escape")
        try files.fileManager.createSymbolicLink(at: escaped, withDestinationURL: external)
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:chr1\tLN:4\n" }, indexQuery: { _, _, _ in }, fileManager: files.fileManager
        )
        let requests = [
            try files.request(reference: false, bamURL: siblingPrefix.appendingPathComponent("evidence.bam")),
            try files.request(reference: false, indexURL: parent.appendingPathComponent("../\(siblingPrefix.lastPathComponent)/evidence.bam.bai")),
            try files.request(reference: true, referenceURL: escaped),
        ]
        for request in requests {
            await XCTAssertThrowsErrorAsync(try await validator.validate(request)) { error in
                XCTAssertTrue(error is ClassifierAlignmentEvidenceValidator.Error)
            }
        }
    }
}

private enum FixtureError: Error { case badIndex }

private final class FixtureFiles {
    let fileManager = FileManager.default
    let directory: URL
    let bam: URL
    let index: URL
    let fasta: URL

    init(fasta fastaText: String = ">chr1\nACTG\n") throws {
        directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        bam = directory.appendingPathComponent("evidence.bam")
        index = directory.appendingPathComponent("evidence.bam.bai")
        fasta = directory.appendingPathComponent("reference.fa")
        try Data([0x42, 0x41, 0x4d]).write(to: bam)
        try Data([0x42, 0x41, 0x49]).write(to: index)
        try fastaText.write(to: fasta, atomically: true, encoding: .utf8)
    }

    deinit { try? fileManager.removeItem(at: directory) }

    func request(
        reference: Bool,
        indexURL: URL? = nil,
        indexKind: ClassifierAlignmentIndex.Kind = .bai,
        bamSnapshot: ClassifierAlignmentEvidenceFileSnapshot? = nil,
        workflow: ClassifierAlignmentWorkflowKind = .taxTriage,
        bamURL: URL? = nil,
        referenceURL: URL? = nil
    ) throws -> ClassifierAlignmentEvidenceRequest {
        try ClassifierAlignmentEvidenceRequest(
            workflow: workflow,
            resultIdentity: .init(stableID: "result", finalResultURL: directory, provenanceID: "prov"),
            bamURL: bamURL ?? bam,
            bamExpectedSnapshot: bamSnapshot,
            index: .init(url: indexURL ?? index, kind: indexKind),
            sample: .init(canonicalID: "sample"),
            contig: .init(name: "chr1", expectedLength: 4),
            referenceCandidate: reference ? .init(fastaURL: referenceURL ?? fasta, recordName: "chr1", expectedLength: 4) : nil,
            presentation: .init(workflowLabel: "TaxTriage", resultLabel: "result", sampleLabel: "sample", contigLabel: "chr1")
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do { _ = try await expression(); XCTFail("Expected error") }
    catch { handler(error) }
}
