import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

/// Opt-in verification against retained human and macaque design outputs.
/// Runs no primer design and downloads no scientific inputs.
final class PrimerAnalysisNativeMHCExportTests: XCTestCase {
  func testSavedMHCSelectionsPublishReadableReferencesWithDurableEvidence() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let fixturePath = environment["LUNGFISH_MHC_PRIMER_VALIDATION_DIR"],
      let outputPath = environment["LUNGFISH_PRIMER_EXPORT_VALIDATION_DIR"] else {
      throw XCTSkip("Set the MHC fixture and export validation directories for manual verification")
    }
    let fixtures = URL(fileURLWithPath: fixturePath, isDirectory: true)
    let outputRoot = URL(fileURLWithPath: outputPath, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    let names = ["primalscheme3/human-A-independent", "primalscheme3/human-DP-combined",
      "primalscheme3/macaque-DQA1-independent", "primer3/mhc-all"]
    for (index, name) in names.enumerated() {
      let analysis = fixtures.appendingPathComponent(name + ".lungfishprimeranalysis")
      let originalManifest = try Data(contentsOf: analysis.appendingPathComponent("manifest.json"))
      let snapshot = try PrimerAnalysisViewerSnapshot.load(from: analysis)
      let target = try XCTUnwrap(snapshot.designReview.first { !$0.intervals.isEmpty && !$0.primers.isEmpty }, name)
      let amplicon = try XCTUnwrap(target.intervals.first, name)
      let ampliconSelection = PrimerAnalysisExportSelection.amplicon(targetID: target.id, ampliconID: amplicon.id)
      let oligoSelection: PrimerAnalysisExportSelection = amplicon.pool.map {
        .pool(sourceResultID: target.sourceResultID, pool: $0)
      } ?? ampliconSelection
      let oligos = amplicon.pool.map { pool in
        snapshot.designReview.filter { $0.sourceResultID == target.sourceResultID }
          .flatMap(\.primers).filter { $0.pool == pool }
      } ?? target.primers.filter { amplicon.primerIDs.contains($0.id) }
      for kind in [PrimerAnalysisExportKind.primerFASTA, .referenceAmplicon] {
        let output = try await PrimerAnalysisSelectionExportService().export(analysisURL: analysis,
          selection: kind == .primerFASTA ? oligoSelection : ampliconSelection, kind: kind,
          destinationURL: outputRoot.appendingPathComponent("\(index)-\(kind.rawValue).lungfishref"),
          invocationArgv: CommandLine.arguments)
        let manifest = try BundleManifest.load(from: output)
        let chromosomes = try XCTUnwrap(manifest.genome).chromosomes
        if kind == .primerFASTA {
          XCTAssertEqual(chromosomes.count, oligos.count, name)
          let fasta = try String(contentsOf: output.appendingPathComponent("primers.fasta"), encoding: .utf8)
          let sequences = fasta.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix(">") }.map(String.init)
          XCTAssertEqual(sequences, oligos.map(\.sequence), name)
        } else {
          XCTAssertEqual(chromosomes.count, 1, name)
          XCTAssertEqual(chromosomes.first?.length, Int64(amplicon.length), name)
          let track = try XCTUnwrap(manifest.annotations.first, name)
          let database = try AnnotationDatabase(url: output.appendingPathComponent(try XCTUnwrap(track.databasePath)))
          XCTAssertEqual(database.query().count, amplicon.primerIDs.count, name)
        }
        let evidence = output.appendingPathComponent("source-analysis/manifest.json")
        XCTAssertEqual(try Data(contentsOf: evidence), originalManifest, name)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: output))
        XCTAssertEqual(envelope.exitStatus, 0, name)
        XCTAssertFalse(envelope.outputs.isEmpty, name)
        for descriptor in envelope.files + envelope.outputs {
          XCTAssertTrue(descriptor.path.hasPrefix(output.path + "/"), descriptor.path)
          let url = URL(fileURLWithPath: descriptor.path)
          XCTAssertEqual(try ProvenanceFileHasher.sha256(of: url), descriptor.checksumSHA256)
          XCTAssertEqual(try ProvenanceFileHasher.fileSize(of: url), descriptor.fileSize)
        }
        for step in envelope.steps {
          XCTAssertFalse((step.durableReplayArgv ?? step.argv).contains { $0.contains(".primer-selection-") }, name)
        }
      }
      XCTAssertEqual(try Data(contentsOf: analysis.appendingPathComponent("manifest.json")), originalManifest, name)
    }
  }
}
