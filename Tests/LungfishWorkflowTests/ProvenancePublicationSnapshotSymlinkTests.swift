import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

/// Publication receipts must identify an artifact by its physical path. A
/// snapshot captured through `/tmp` (or any symlinked folder) and a mutation
/// reported through `/private/tmp` describe the same file; before the shared
/// canonical-path helper the receipt check reported a transaction-generation
/// conflict for `lungfish-cli convert` and `import vcf` run from such paths.
final class ProvenancePublicationSnapshotSymlinkTests: XCTestCase {
    private var root: URL!
    private var real: URL!
    private var link: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotSymlinkTests-\(UUID().uuidString)", isDirectory: true)
        real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func physical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.canonicalFilePath)
    }

    func testPublishReplacementAcceptsDestinationReachedThroughAnotherPath() throws {
        let viaLink = link.appendingPathComponent("out.txt")
        let snapshot = try ProvenancePublicationSnapshot(urls: [viaLink])
        defer { snapshot.discard() }
        let witness = try snapshot.captureRollbackWitness()

        let staged = root.appendingPathComponent("staged.txt")
        try Data("payload".utf8).write(to: staged)
        let published = try snapshot.publishReplacement(
            from: staged, to: physical(viaLink), replacingExisting: false, witness: witness)
        XCTAssertNil(published.displacedURL)
        XCTAssertEqual(try Data(contentsOf: viaLink), Data("payload".utf8))
    }

    func testMutationReportedOnPhysicalPathMatchesSnapshotTakenThroughSymlink() throws {
        let viaLink = link.appendingPathComponent("provenance.json")
        let snapshot = try ProvenancePublicationSnapshot(urls: [viaLink])
        defer { snapshot.discard() }
        var witness = try snapshot.captureRollbackWitness()

        // The writer keys receipts by canonical path and reports the URL it
        // published to, which for a cwd-derived URL is the physical path.
        let physicalURL = physical(viaLink)
        try Data("{}".utf8).write(to: physicalURL)
        let written = try ProvenancePublicationSnapshot.artifactState(at: physicalURL, fileManager: .default)
        let mutation = ProvenanceWriterMutation(
            kind: .provenanceDocumentWritten,
            affectedURLs: [physicalURL],
            requiredPriorStates: [physicalURL.canonicalFilePath: .missing],
            resultingStates: [physicalURL.canonicalFilePath: written]
        )
        witness = try snapshot.refreshingRollbackWitness(witness, after: mutation)
        XCTAssertEqual(try snapshot.changedArtifacts(comparedTo: witness), [])

        // And the reverse: the snapshot on the physical path, the mutation via the link.
        let other = real.appendingPathComponent("other.json")
        let otherSnapshot = try ProvenancePublicationSnapshot(urls: [physical(other)])
        defer { otherSnapshot.discard() }
        var otherWitness = try otherSnapshot.captureRollbackWitness()
        let otherViaLink = link.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: otherViaLink)
        let otherWritten = try ProvenancePublicationSnapshot.artifactState(at: otherViaLink, fileManager: .default)
        otherWitness = try otherSnapshot.refreshingRollbackWitness(otherWitness, after: ProvenanceWriterMutation(
            kind: .provenanceDocumentWritten,
            affectedURLs: [otherViaLink],
            requiredPriorStates: [otherViaLink.canonicalFilePath: .missing],
            resultingStates: [otherViaLink.canonicalFilePath: otherWritten]
        ))
        XCTAssertEqual(try otherSnapshot.changedArtifacts(comparedTo: otherWitness), [])
    }

    func testMissingArtifactUnderPrivatePrefixKeepsItsIdentityOnceWritten() throws {
        // The exact shape of the convert failure: the receipt was taken while
        // the sidecar did not exist (Foundation kept /private) and checked once
        // it did (Foundation dropped /private).
        let physicalSidecar = physical(real.appendingPathComponent(".lungfish-provenance.json"))
        XCTAssertTrue(physicalSidecar.path.hasPrefix("/private/"), physicalSidecar.path)
        let snapshot = try ProvenancePublicationSnapshot(urls: [physicalSidecar])
        defer { snapshot.discard() }
        let witness = try snapshot.captureRollbackWitness()

        let staged = root.appendingPathComponent("staged.json")
        try Data("{}".utf8).write(to: staged)
        _ = try snapshot.publishReplacement(
            from: staged, to: physicalSidecar, replacingExisting: false, witness: witness)
        XCTAssertNoThrow(try snapshot.refreshingRollbackWitness(witness, after: ProvenanceWriterMutation(
            kind: .provenanceDocumentWritten,
            affectedURLs: [physicalSidecar.standardizedFileURL],
            requiredPriorStates: [physicalSidecar.canonicalFilePath: .missing],
            resultingStates: [physicalSidecar.canonicalFilePath:
                try ProvenancePublicationSnapshot.artifactState(at: physicalSidecar, fileManager: .default)]
        )))
    }
}
