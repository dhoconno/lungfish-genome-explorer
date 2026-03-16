import XCTest
@testable import LungfishApp
@testable import LungfishIO

final class ReferenceDiscoveryServiceTests: XCTestCase {

    private func makeTempProject() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefDiscTests-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return projectURL
    }

    @MainActor
    func testServiceStartsEmpty() {
        let service = ReferenceDiscoveryService()
        XCTAssertTrue(service.candidates.isEmpty)
        XCTAssertFalse(service.isScanning)
        XCTAssertNil(service.projectURL)
    }

    @MainActor
    func testScanPopulatesCandidates() async throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a reference
        let fastaURL = projectURL.deletingLastPathComponent().appendingPathComponent("ref.fasta")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try ReferenceSequenceFolder.importReference(from: fastaURL, into: projectURL, displayName: "Scan Test Ref")

        let service = ReferenceDiscoveryService()
        await service.scan(projectURL: projectURL)

        XCTAssertFalse(service.isScanning)
        XCTAssertEqual(service.projectURL, projectURL)
        XCTAssertFalse(service.candidates.isEmpty)
        XCTAssertEqual(service.candidates.first?.displayName, "Scan Test Ref")
    }

    @MainActor
    func testCandidatesFilteredByCategory() async throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a project reference
        let fastaURL = projectURL.deletingLastPathComponent().appendingPathComponent("ref.fasta")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try ReferenceSequenceFolder.importReference(from: fastaURL, into: projectURL, displayName: "Ref A")

        // Create a standalone FASTA
        try ">seq\nACGT\n".write(
            to: projectURL.appendingPathComponent("standalone.fasta"),
            atomically: true, encoding: .utf8
        )

        let service = ReferenceDiscoveryService()
        await service.scan(projectURL: projectURL)

        let projRefs = service.candidates(for: .projectReferences)
        XCTAssertEqual(projRefs.count, 1)
        XCTAssertEqual(projRefs.first?.displayName, "Ref A")

        let standalones = service.candidates(for: .standaloneFASTAFiles)
        XCTAssertEqual(standalones.count, 1)
    }

    @MainActor
    func testGroupedCandidatesOrdering() async throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let fastaURL = projectURL.deletingLastPathComponent().appendingPathComponent("ref.fasta")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try ReferenceSequenceFolder.importReference(from: fastaURL, into: projectURL, displayName: "Ref")

        try ">seq\nACGT\n".write(
            to: projectURL.appendingPathComponent("standalone.fasta"),
            atomically: true, encoding: .utf8
        )

        let service = ReferenceDiscoveryService()
        await service.scan(projectURL: projectURL)

        let groups = service.groupedCandidates
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.category, .projectReferences)
    }

    @MainActor
    func testLastUsedReference() async throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let fastaURL = projectURL.deletingLastPathComponent().appendingPathComponent("ref.fasta")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try ReferenceSequenceFolder.importReference(from: fastaURL, into: projectURL, displayName: "My Ref")

        let service = ReferenceDiscoveryService()
        await service.scan(projectURL: projectURL)

        guard let candidate = service.candidates.first else {
            XCTFail("No candidates found")
            return
        }

        // No last-used reference initially
        XCTAssertNil(service.lastUsedCandidate(for: "orient"))

        // Record and retrieve
        service.recordLastUsed(candidate, for: "orient")
        let retrieved = service.lastUsedCandidate(for: "orient")
        XCTAssertEqual(retrieved?.displayName, "My Ref")

        // Different operation kind returns nil
        XCTAssertNil(service.lastUsedCandidate(for: "contaminantFilter"))
    }
}
