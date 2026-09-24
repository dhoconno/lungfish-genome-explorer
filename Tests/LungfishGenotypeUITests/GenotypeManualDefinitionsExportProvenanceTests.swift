import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// REC-03: the manual-haplotype-definitions export used to write its JSON
/// payload with `Data.write(options: .atomic)` and only then write a
/// provenance sidecar in a separate step, so a crash in between left an
/// orphaned payload with no sidecar. It also recorded
/// `lungfish-cli export-manual-haplotype-definitions`, which is not a real
/// CLI subcommand.
@MainActor
final class GenotypeManualDefinitionsExportProvenanceTests: XCTestCase {
    func testExportWritesPayloadAndSidecarAtomicallyWithHonestCommand() throws {
        let bundleDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleDir) }

        let store = try GenotypeAnnotationStore(bundleURL: bundleDir, author: "test")
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.testingInstallEffectiveHaplotypeAnnotationStore(store)

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-haplotype-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let outputURL = outputDirectory.appendingPathComponent("manual-haplotype-definitions.json")

        let payload = Data("{}".utf8)
        try controller.testingWriteManualDefinitionsExport(
            data: payload,
            outputURL: outputURL,
            assignmentCount: 0
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "lungfish app manual haplotype definition export")

        // The recorded replay command must not claim to be a runnable
        // `lungfish-cli` invocation, since no such subcommand exists.
        let recordedArgv = envelope.steps.first?.argv ?? []
        XCTAssertFalse(recordedArgv.first == "lungfish-cli")
        XCTAssertEqual(recordedArgv.first, "Lungfish Genome Explorer")
    }
}
