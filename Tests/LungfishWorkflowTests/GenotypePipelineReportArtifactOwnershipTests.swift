import CryptoKit
import Darwin
import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class GenotypePipelineReportArtifactOwnershipTests: XCTestCase {
    func testMissingMemberAtHandoffRetainsCompleteSurvivorInventory() async throws {
        let fixture = try await exportedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.moveItem(at: fixture.export.snapshotURL,
            to: fixture.root.appendingPathComponent("removed-snapshot.json"))
        var ownership = GenotypePipelineReportArtifactOwnership()
        XCTAssertThrowsError(try ownership.captureExport(fixture.export))
        _ = ownership.rollback { try FileManager.default.removeItem(at: $0) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.export.artifactDirectoryURL.path))
        try assertSurvivors(ownership.failureInventory(), fixture: fixture, unavailable: "snapshot.json")
    }

    func testRegularReplacementBeforeExportCaptureIsNotRemoved() async throws {
        try await assertExportReplacementIsNotAdopted(failRemoval: false)
    }

    func testRegularReplacementBeforeExportCaptureIsNotAttestedAfterCleanupFailure() async throws {
        try await assertExportReplacementIsNotAdopted(failRemoval: true)
    }

    func testRegularReplacementBeforeDefinitionCaptureIsNotRemovedOrAttested() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-definition-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try NoFollowFileSystem.openDirectoryHierarchy(root)
        defer { Darwin.close(directory) }
        let created = try DurableAtomicFileStore().createWitnessed(Data("created definition".utf8),
            named: "haplotype-definition.json", inOpenDirectory: directory, displayedAt: root)
        defer { created.close() }
        try FileManager.default.moveItem(at: created.url, to: root.appendingPathComponent("original-definition.json"))
        let replacement = Data("replacement belongs to somebody else".utf8)
        try replacement.write(to: created.url)
        let replacementIdentity = try FileSystemObjectIdentity.noFollow(created.url)
        var ownership = GenotypePipelineReportArtifactOwnership()
        XCTAssertThrowsError(try ownership.captureDefinition(created))
        _ = ownership.rollback { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(try? Data(contentsOf: created.url), replacement)
        XCTAssertEqual(try? FileSystemObjectIdentity.noFollow(created.url), replacementIdentity)
        let inventory = ownership.failureInventory()
        XCTAssertTrue(inventory.outputs.isEmpty)
        XCTAssertTrue(inventory.diagnostics.contains { $0["path"] == created.url.standardizedFileURL.path })
    }

    private func assertExportReplacementIsNotAdopted(failRemoval: Bool) async throws {
        let fixture = try await exportedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.moveItem(at: fixture.export.snapshotURL,
            to: fixture.root.appendingPathComponent("original-snapshot.json"))
        let replacement = Data("unowned regular replacement, not a snapshot".utf8)
        try replacement.write(to: fixture.export.snapshotURL)
        let replacementIdentity = try FileSystemObjectIdentity.noFollow(fixture.export.snapshotURL)
        var ownership = GenotypePipelineReportArtifactOwnership()
        XCTAssertThrowsError(try ownership.captureExport(fixture.export))
        _ = ownership.rollback {
            if failRemoval { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: $0)
        }
        XCTAssertEqual(try? Data(contentsOf: fixture.export.snapshotURL), replacement)
        XCTAssertEqual(try? FileSystemObjectIdentity.noFollow(fixture.export.snapshotURL), replacementIdentity)
        try assertSurvivors(ownership.failureInventory(), fixture: fixture, unavailable: "snapshot.json")
    }

    private struct Fixture {
        let root: URL
        let export: GenotypeExcelExportService.ExportResult
        let bytes: [String: Data]
    }

    private func exportedFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lge-report-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let snapshot = try GenotypeExcelSnapshotBuilder.capture(result: GenotypeTestFixtures.makeResult(calls: []),
            sidecar: .empty(generatedAt: "2026-09-12T12:00:00Z"), allProjection: nil, filteredProjection: nil,
            generatedAt: "2026-09-12T12:00:00Z")
        let export = try await GenotypeExcelExportService(pythonExecutableURL: python).export(snapshot: snapshot,
            outputURL: root.appendingPathComponent("report.xlsx"), provenance: .init(toolVersion: "test",
                argv: ["lungfish-cli", "genotype", "export-xlsx"],
                inputs: [.init(path: root.appendingPathComponent("in-memory-input").path,
                    data: Data("scientific input witness".utf8), verifyCurrentFile: false)]))
        let bytes = try Dictionary(uniqueKeysWithValues: export.artifactURLs.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        return .init(root: root, export: export, bytes: bytes)
    }

    private func assertSurvivors(
        _ inventory: (outputs: [[String: Any]], diagnostics: [[String: String]]),
        fixture: Fixture, unavailable: String
    ) throws {
        let expectedNames: Set<String> = ["renderer.py", "request.json", "replay.sh", "stdout.json", "stderr.txt", "input-0.bin"]
        let names = Set(inventory.outputs.compactMap { ($0["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } })
        XCTAssertEqual(names, expectedNames)
        let missingPath = fixture.export.artifactDirectoryURL.appendingPathComponent(unavailable).standardizedFileURL.path
        XCTAssertTrue(inventory.diagnostics.contains { $0["path"] == missingPath && $0["error"]?.isEmpty == false })
        for descriptor in inventory.outputs {
            let path = try XCTUnwrap(descriptor["path"] as? String)
            let bytes = try XCTUnwrap(fixture.bytes[URL(fileURLWithPath: path).lastPathComponent])
            XCTAssertEqual(descriptor["sha256"] as? String, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual((descriptor["fileSize"] as? NSNumber)?.uint64Value, UInt64(bytes.count))
        }
    }
}
