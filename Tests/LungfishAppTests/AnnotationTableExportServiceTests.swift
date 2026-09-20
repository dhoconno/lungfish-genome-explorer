import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AnnotationTableExportServiceTests: XCTestCase {
    func testExportPublishesPayloadAndProvenanceWithDurableByteReplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableExportServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("variants.db")
        let output = directory.appendingPathComponent("variants.csv")
        try Data("source database".utf8).write(to: source)
        let snapshot = AnnotationTableExportSnapshot(
            table: .init(
                name: "Variants",
                columns: [.init(id: "PositionColumn", title: "Position (1-based)")],
                rows: [[.integer(29_409)]]
            ),
            tab: "variants",
            scope: .selected,
            rowIdentities: ["track:7"],
            sourceURLs: [source],
            queryDescription: ["sort": "position:ascending", "filter": "PASS"],
            coordinateConventions: ["PositionColumn": "1-based genomic position"]
        )

        try AnnotationTableExportService.export(
            snapshot: snapshot,
            format: .csv,
            outputURL: output,
            startedAt: Date(),
            shouldCancel: { false }
        )

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "Position (1-based)\n29409\n")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        XCTAssertEqual(envelope.output?.path, output.path)
        XCTAssertEqual(envelope.options.resolvedDefaults["rowCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.resolvedDefaults["columnIDs"]?.arrayValue?.first?.stringValue, "PositionColumn")
        XCTAssertTrue(envelope.files.contains { $0.path == source.path && $0.role == .input })
        let replay = try XCTUnwrap(envelope.durableReplayArgv)
        XCTAssertEqual(replay.first, "/bin/cp")
        XCTAssertEqual(replay.last, output.path)

        let replayOutput = directory.appendingPathComponent("replayed.csv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: replay[0])
        process.arguments = [replay[1], replayOutput.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: replayOutput), try Data(contentsOf: output))
    }

    func testCancellationPreservesExistingPayloadAndSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotationTableExportServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("variants.db")
        let output = directory.appendingPathComponent("variants.csv")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        try Data("source".utf8).write(to: source)
        try Data("old".utf8).write(to: output)
        try Data("old provenance".utf8).write(to: sidecar)
        let snapshot = AnnotationTableExportSnapshot(
            table: .init(name: "Variants", columns: [.init(id: "id", title: "ID")], rows: [[.text("rs1")]]),
            tab: "variants", scope: .allMatching, rowIdentities: ["track:1"], sourceURLs: [source],
            queryDescription: [:], coordinateConventions: [:]
        )

        XCTAssertThrowsError(try AnnotationTableExportService.export(
            snapshot: snapshot, format: .csv, outputURL: output, shouldCancel: { true }
        ))
        XCTAssertEqual(try Data(contentsOf: output), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: sidecar), Data("old provenance".utf8))
    }
}
