import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class FASTQProjectSimulationTests: XCTestCase {
    private func makeProject() throws -> URL {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQProjectSimulation-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        return projectDir
    }

    private func writeFASTA(records: [(id: String, description: String?, sequence: String)], to url: URL) throws {
        let content = records.map { record in
            let header = record.description.map { ">\(record.id) \($0)" } ?? ">\(record.id)"
            return "\(header)\n\(record.sequence)"
        }.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testSimulatedProjectImportsReferenceBundle() throws {
        let projectURL = try makeProject()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let sourceFASTA = projectURL.appendingPathComponent("mhc-reference.fsa")
        try writeFASTA(
            records: [
                (id: "ref1", description: "synthetic", sequence: "AACCGGTTAACCGGTTAACCGGTT"),
            ],
            to: sourceFASTA
        )

        let bundleURL = try ReferenceSequenceFolder.importReference(from: sourceFASTA, into: projectURL, displayName: "Synthetic Reference")
        XCTAssertEqual(bundleURL.pathExtension, "lungfishref")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))

        let listed = ReferenceSequenceFolder.listReferences(in: projectURL)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.manifest.name, "Synthetic Reference")

        let fastaURL = try XCTUnwrap(ReferenceSequenceFolder.fastaURL(in: bundleURL))
        XCTAssertEqual(fastaURL.lastPathComponent, "sequence.fasta")
        XCTAssertEqual(try String(contentsOf: fastaURL, encoding: .utf8), try String(contentsOf: sourceFASTA, encoding: .utf8))
    }
}
