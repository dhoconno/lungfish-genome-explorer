import XCTest
@testable import LungfishIO

final class ReferenceSequenceScannerTests: XCTestCase {

    private func makeTempProject() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefScanTests-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return projectURL
    }

    // MARK: - scanAll

    func testScanAllReturnsEmptyForEmptyProject() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllFindsProjectReferences() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a reference
        let fastaURL = projectURL.deletingLastPathComponent().appendingPathComponent("ref.fasta")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try ReferenceSequenceFolder.importReference(from: fastaURL, into: projectURL, displayName: "Test Ref")

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.displayName, "Test Ref")
        XCTAssertEqual(results.first?.sourceCategory, .projectReferences)
    }

    func testScanAllFindsStandaloneFASTAFiles() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a standalone FASTA directly in the project
        let fastaURL = projectURL.appendingPathComponent("standalone.fasta")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        let standalone = results.filter { $0.sourceCategory == .standaloneFASTAFiles }
        XCTAssertEqual(standalone.count, 1)
        XCTAssertEqual(standalone.first?.displayName, "standalone")
    }

    func testScanAllFindsFaGzFiles() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a .fa.gz file (just the extension matters for discovery)
        let fastaURL = projectURL.appendingPathComponent("genome.fa.gz")
        try Data().write(to: fastaURL)

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        let standalone = results.filter { $0.sourceCategory == .standaloneFASTAFiles }
        XCTAssertEqual(standalone.count, 1)
        XCTAssertEqual(standalone.first?.displayName, "genome.fa")
    }

    func testScanAllSortsByCategory() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create standalone FASTA
        try ">s\nA\n".write(
            to: projectURL.appendingPathComponent("standalone.fasta"),
            atomically: true, encoding: .utf8
        )

        // Create project reference
        let tmpFasta = projectURL.deletingLastPathComponent().appendingPathComponent("ref.fasta")
        try ">s\nA\n".write(to: tmpFasta, atomically: true, encoding: .utf8)
        try ReferenceSequenceFolder.importReference(from: tmpFasta, into: projectURL, displayName: "Project Ref")

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertEqual(results.count, 2)
        // Project references should come first
        XCTAssertEqual(results.first?.sourceCategory, .projectReferences)
        XCTAssertEqual(results.last?.sourceCategory, .standaloneFASTAFiles)
    }

    func testScanAllSkipsLungfishfastqBundles() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a .lungfishfastq directory with a FASTA inside (shouldn't be scanned)
        let bundleDir = projectURL.appendingPathComponent("data.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try ">s\nA\n".write(
            to: bundleDir.appendingPathComponent("ref.fasta"),
            atomically: true, encoding: .utf8
        )

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllLimitsRecursionDepth() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create deeply nested FASTA (depth 6 — beyond limit)
        var deepDir = projectURL
        for i in 0..<6 {
            deepDir = deepDir.appendingPathComponent("level\(i)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        try ">s\nA\n".write(
            to: deepDir.appendingPathComponent("deep.fasta"),
            atomically: true, encoding: .utf8
        )

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertTrue(results.isEmpty, "Should not find FASTA beyond depth limit")
    }

    // MARK: - inferRole

    func testInferRolePrimer() {
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/primers.fasta")), "primer")
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/oligo-set.fa")), "primer")
    }

    func testInferRoleContaminant() {
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/contaminants.fasta")), "contaminant")
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/host-genome.fa")), "contaminant")
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/phix174.fasta")), "contaminant")
    }

    func testInferRoleReference() {
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/genome.fasta")), "reference")
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/my-reference.fa")), "reference")
    }

    func testInferRoleUnknown() {
        XCTAssertNil(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/sample-data.fasta")))
    }

    // MARK: - AsyncStream scan

    func testAsyncStreamScanFindsReferences() async throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        try ">s\nA\n".write(
            to: projectURL.appendingPathComponent("ref.fasta"),
            atomically: true, encoding: .utf8
        )

        var found: [ReferenceCandidate] = []
        for await candidate in ReferenceSequenceScanner.scan(in: projectURL) {
            found.append(candidate)
        }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.displayName, "ref")
    }
}
