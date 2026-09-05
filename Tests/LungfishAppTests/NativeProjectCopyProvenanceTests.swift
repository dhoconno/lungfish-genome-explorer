import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class NativeProjectCopyProvenanceTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeCopyTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testNativeDirectoryCopyRejectsSigningDirectoryAndPreservesPreviousBundle() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.lungfishref")
        let final = root.appendingPathComponent("stored.lungfishref")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        let oldPayload = final.appendingPathComponent("previous.txt")
        try Data("previous bundle".utf8).write(to: oldPayload)
        try Data("source payload".utf8).write(to: source.appendingPathComponent("fixture.txt"))
        let artifact = ProvenanceSigningConfiguration.publicKeyURL(for: source.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        let marker = artifact.appendingPathComponent("retained.txt")
        try Data("retained source directory".utf8).write(to: marker)
        XCTAssertThrowsError(try NativeProjectCopyImportService.copy(from: source, to: final, replaceExisting: true))
        XCTAssertEqual(try? Data(contentsOf: oldPayload), Data("previous bundle".utf8))
        XCTAssertEqual(try Data(contentsOf: marker), Data("retained source directory".utf8))
    }

    func testLegacyNativeDirectoryReceivesFinalPayloadReceipt() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.lungfishref")
        let final = root.appendingPathComponent("stored.lungfishref")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = source.appendingPathComponent("fixture.txt")
        try Data("synthetic native payload".utf8).write(to: payload)
        _ = try MainSplitViewController().copyProjectItemForImport(from: source, to: final)
        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: final.appendingPathComponent(ProvenanceRecorder.provenanceFilename)))
        let output = try XCTUnwrap(receipt.files.first { $0.role == .output && $0.path == final.appendingPathComponent("fixture.txt").path })
        XCTAssertEqual(output.checksumSHA256, try ProvenanceFileHasher.sha256(of: payload))
        XCTAssertNotNil(output.fileSize)
        XCTAssertEqual(receipt.exitStatus, 0)
        XCTAssertFalse(receipt.steps.isEmpty)
    }

    func testCopiedCLINativeBundleRehydratesFinalOutputAndRetainsHistoricalArgv() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.lungfishref")
        let final = root.appendingPathComponent("stored.lungfishref")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let payload = source.appendingPathComponent("fixture.txt")
        try Data("synthetic CLI payload".utf8).write(to: payload)
        let argv = ["lungfish-cli", "fixture-audit-only", "--output", payload.path]
        let envelope = try ProvenanceRunBuilder(workflowName: "Fixture", workflowVersion: "1", toolName: "lungfish-cli", toolVersion: "1")
            .argv(argv).output(payload, format: .text, role: .output)
            .runtime(ProvenanceRuntimeIdentity.fixture())
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: source)
        _ = try MainSplitViewController().copyProjectItemForImport(from: source, to: final)
        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: final.appendingPathComponent(ProvenanceRecorder.provenanceFilename)))
        XCTAssertEqual(receipt.output?.path, final.appendingPathComponent("fixture.txt").path)
        XCTAssertEqual(receipt.argv, argv)
        XCTAssertTrue(receipt.steps.contains { $0.toolName == "lungfish-app" })
    }

    func testOpaqueNativeArchiveReceivesSidecarWithoutChangingArchiveBytes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.lungfish12sref")
        let final = root.appendingPathComponent("stored.lungfish12sref")
        let archive = Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18))
        try archive.write(to: source)
        _ = try MainSplitViewController().copyProjectItemForImport(from: source, to: final)
        XCTAssertEqual(try Data(contentsOf: final), archive)
        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: final)))
        XCTAssertEqual(receipt.output?.path, final.path)
        XCTAssertEqual(receipt.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: final))
    }

    func testExistingArchiveReceiptRehydratesReplayOutputToFileRatherThanParentDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.lungfish12sref")
        let final = root.appendingPathComponent("stored.lungfish12sref")
        try Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18)).write(to: source)
        let argv = ["lungfish-cli", "fixture-audit-only", "--output", source.path]
        let envelope = try ProvenanceRunBuilder(workflowName: "Archive fixture", workflowVersion: "1", toolName: "lungfish-cli", toolVersion: "1")
            .argv(argv).output(source, format: .unknown, role: .output).runtime(ProvenanceRuntimeIdentity.fixture())
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: source))
        _ = try MainSplitViewController().copyProjectItemForImport(from: source, to: final)
        let receipt = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: final)))
        XCTAssertEqual(receipt.argv, argv)
        XCTAssertEqual(receipt.output?.path, final.path)
        XCTAssertEqual(receipt.durableReplayArgv?.last, final.path)
        XCTAssertEqual(receipt.steps.last?.durableReplayArgv?.last, final.path)
    }

    func testArchiveReplacementSidecarFailurePreservesOldArchive() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.lungfish12sref")
        let final = root.appendingPathComponent("stored.lungfish12sref")
        try Data("new opaque archive".utf8).write(to: source)
        try Data("old opaque archive".utf8).write(to: final)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: final)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let marker = sidecar.appendingPathComponent("retained")
        try Data("old sidecar artifact".utf8).write(to: marker)
        XCTAssertThrowsError(try MainSplitViewController().copyProjectItemForImport(from: source, to: final, replaceExisting: true))
        XCTAssertEqual(try Data(contentsOf: final), Data("old opaque archive".utf8))
        XCTAssertEqual(try Data(contentsOf: marker), Data("old sidecar artifact".utf8))
    }
}
