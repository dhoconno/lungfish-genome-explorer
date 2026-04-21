import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AssemblyInspectorSourceResolverTests: XCTestCase {
    func testResolverPrefersFASTQBundleLinkbackWhenInputLivesInsideBundle() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-source-resolver-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Imports/SampleA.lungfishfastq", isDirectory: true)
        let readsURL = bundleURL.appendingPathComponent("reads.fastq.gz")

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        FileManager.default.createFile(atPath: readsURL.path, contents: Data())

        let rows = AssemblyInspectorSourceResolver.resolve(
            provenanceInputs: [
                .init(filename: readsURL.lastPathComponent, originalPath: readsURL.path, sha256: nil, sizeBytes: 0)
            ],
            projectURL: projectURL
        )

        XCTAssertEqual(rows, [.projectLink(name: "reads.fastq.gz", targetURL: bundleURL)])
    }

    func testResolverPrefersProjectRelativeLinkbacks() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-source-resolver-\(UUID().uuidString)", isDirectory: true)
        let inputURL = projectURL.appendingPathComponent("Imports/reads.fastq.gz")

        try FileManager.default.createDirectory(at: inputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        FileManager.default.createFile(atPath: inputURL.path, contents: Data())

        let rows = AssemblyInspectorSourceResolver.resolve(
            provenanceInputs: [
                .init(filename: inputURL.lastPathComponent, originalPath: inputURL.path, sha256: nil, sizeBytes: 0)
            ],
            projectURL: projectURL
        )

        XCTAssertEqual(rows, [.projectLink(name: "reads.fastq.gz", targetURL: inputURL)])
    }

    func testResolverFallsBackToFilesystemForExternalExistingPaths() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-source-resolver-external-\(UUID().uuidString).fastq.gz")
        FileManager.default.createFile(atPath: externalURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: externalURL) }

        let rows = AssemblyInspectorSourceResolver.resolve(
            provenanceInputs: [
                .init(filename: externalURL.lastPathComponent, originalPath: externalURL.path, sha256: nil, sizeBytes: 0)
            ],
            projectURL: nil
        )

        XCTAssertEqual(rows, [.filesystemLink(name: externalURL.lastPathComponent, fileURL: externalURL)])
    }

    func testResolverMarksMissingPathWhenUnresolvable() {
        let rows = AssemblyInspectorSourceResolver.resolve(
            provenanceInputs: [
                .init(filename: "missing.fastq.gz", originalPath: "/tmp/does-not-exist.fastq.gz", sha256: nil, sizeBytes: 0)
            ],
            projectURL: nil
        )

        XCTAssertEqual(rows, [.missing(name: "missing.fastq.gz", originalPath: "/tmp/does-not-exist.fastq.gz")])
    }
}
