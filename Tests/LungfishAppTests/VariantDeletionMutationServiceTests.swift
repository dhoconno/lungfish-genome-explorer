import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class VariantDeletionMutationServiceTests: XCTestCase {
    func testSelectedVariantDeletionWritesProvenanceForMutatedDatabase() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ids = try variantIDs(in: fixture.databaseURL)
        XCTAssertEqual(ids.count, 2)

        let result = try VariantDeletionMutationService().deleteVariants(
            idsByTrack: ["trackA": [ids[0]]],
            bundleURL: fixture.bundleURL,
            targets: [
                VariantDeletionMutationTarget(
                    trackId: "trackA",
                    databaseURL: fixture.databaseURL,
                    trackName: "Variants"
                )
            ]
        )

        XCTAssertEqual(result.totalDeleted, 1)
        XCTAssertEqual(try VariantDatabase(url: fixture.databaseURL).totalCount(), 1)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.bundleURL))
        XCTAssertEqual(envelope.workflowName, "Variant deletion")
        XCTAssertEqual(envelope.options.explicit["scope"]?.stringValue, "selected")
        XCTAssertTrue(envelope.files.contains { $0.originPath == fixture.databaseURL.path && $0.role == .input })
        XCTAssertTrue(envelope.outputs.contains { $0.path == fixture.databaseURL.path && $0.role == .output })
        let inputDB = try XCTUnwrap(envelope.files.first {
            $0.originPath == fixture.databaseURL.path && $0.role == .input
        })
        let outputDB = try XCTUnwrap(envelope.outputs.first {
            $0.path == fixture.databaseURL.path && $0.role == .output
        })
        XCTAssertNotEqual(inputDB.checksumSHA256, outputDB.checksumSHA256)
    }

    func testDeleteAllVariantsWritesProvenance() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try VariantDeletionMutationService().deleteAllVariants(
            bundleURL: fixture.bundleURL,
            targets: [
                VariantDeletionMutationTarget(
                    trackId: "trackA",
                    databaseURL: fixture.databaseURL,
                    trackName: "Variants"
                )
            ]
        )

        XCTAssertEqual(result.totalDeleted, 2)
        XCTAssertEqual(try VariantDatabase(url: fixture.databaseURL).totalCount(), 0)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.bundleURL))
        XCTAssertEqual(envelope.workflowName, "Variant deletion")
        XCTAssertEqual(envelope.options.explicit["scope"]?.stringValue, "all")
        XCTAssertEqual(envelope.options.resolvedDefaults["totalDeleted"]?.integerValue, 2)
    }

    func testDeletionRestoresDatabaseWhenProvenanceWriteFails() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ids = try variantIDs(in: fixture.databaseURL)
        XCTAssertEqual(ids.count, 2)
        let service = VariantDeletionMutationService { _, _ in
            throw IntentionalVariantDeletionProvenanceFailure.write
        }

        XCTAssertThrowsError(
            try service.deleteVariants(
                idsByTrack: ["trackA": [ids[0]]],
                bundleURL: fixture.bundleURL,
                targets: [
                    VariantDeletionMutationTarget(
                        trackId: "trackA",
                        databaseURL: fixture.databaseURL,
                        trackName: "Variants"
                    )
                ]
            )
        )

        XCTAssertEqual(try VariantDatabase(url: fixture.databaseURL).totalCount(), 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
        ))
    }

    func testProvenanceFailureRestoresLiveReaderAndPreviousProvenance() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = try VariantDatabase(url: fixture.databaseURL)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try ProvenanceWriter(signingProvider: nil).write(ProvenanceEnvelope(workflowName: "Previous fixture",
            toolName: "fixture", toolVersion: "1", argv: ["/bin/true"], exitStatus: 0), to: fixture.bundleURL)
        let original = try Data(contentsOf: provenanceURL)
        let service = VariantDeletionMutationService(provenanceWriter: ProvenanceWriter(publicationMutationDidOccur: { mutation in
            if mutation.affectedURLs.contains(provenanceURL) { throw IntentionalVariantDeletionProvenanceFailure.write }
        }, signingProvider: nil))
        XCTAssertThrowsError(try service.deleteAllVariants(bundleURL: fixture.bundleURL, targets: [
            VariantDeletionMutationTarget(trackId: "trackA", databaseURL: fixture.databaseURL)
        ]))
        XCTAssertEqual(reader.totalCount(), 2, "An existing reader must observe the rolled-back database")
        XCTAssertEqual(try VariantDatabase(url: fixture.databaseURL).totalCount(), 2)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), original)
    }

    func testUnsignedMutationRejectsSigningDirectoryAndRestoresLiveDatabase() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = try VariantDatabase(url: fixture.databaseURL)
        let receipt = fixture.bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let obstruction = ProvenanceSigningConfiguration.signatureURL(for: receipt)
        try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: true)
        let marker = obstruction.appendingPathComponent("retained.txt")
        try Data("retained directory".utf8).write(to: marker)
        XCTAssertThrowsError(try VariantDeletionMutationService().deleteAllVariants(bundleURL: fixture.bundleURL,
            targets: [VariantDeletionMutationTarget(trackId: "trackA", databaseURL: fixture.databaseURL)]))
        XCTAssertEqual(reader.totalCount(), 2)
        XCTAssertEqual(try? Data(contentsOf: marker), Data("retained directory".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }

    private func makeVariantBundle() throws -> (root: URL, bundleURL: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantDeletionMutation-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "{}".write(
            to: bundleURL.appendingPathComponent(BundleManifest.filename),
            atomically: true,
            encoding: .utf8
        )
        let vcfURL = root.appendingPathComponent("variants.vcf")
        try """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE_A
        chr1\t100\t.\tA\tG\t50\tPASS\tDP=10\tGT\t0/1
        chr1\t200\t.\tC\tT\t50\tPASS\tDP=12\tGT\t0/1
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        let databaseURL = bundleURL.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: databaseURL,
            parseGenotypes: true,
            sourceFile: "variants.vcf",
            progressHandler: nil
        )
        return (root, bundleURL, databaseURL)
    }

    private func variantIDs(in databaseURL: URL) throws -> [Int64] {
        try VariantDatabase(url: databaseURL).queryForTable().compactMap(\.id)
    }
}

private enum IntentionalVariantDeletionProvenanceFailure: Error {
    case write
}
