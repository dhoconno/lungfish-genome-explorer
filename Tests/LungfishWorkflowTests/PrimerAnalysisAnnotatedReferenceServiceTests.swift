import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class PrimerAnalysisAnnotatedReferenceServiceTests: XCTestCase {
  func testMismatchedAnnotationLinkIsRejectedBeforeReferenceCreation() async throws {
    let fixture = try Self.makeFixture(wrongLink: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    do {
      _ = try await PrimerAnalysisAnnotatedReferenceService().createReference(
        analysisURL: fixture.bundle.url, resultID: fixture.resultID,
        outputDirectory: fixture.output, invocationArgv: CommandLine.arguments)
      XCTFail("Expected mismatched link to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("do not match"), error.localizedDescription)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path), [])
  }

  func testCreatedReferenceRetainsLinkedFeaturesAndFinalProvenance() async throws {
    if let missing = await NativeBundleBuilder().checkRequiredTools() {
      throw XCTSkip("Native reference tools unavailable: \(missing.description)")
    }
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let argv = CommandLine.arguments
    let reference = try await PrimerAnalysisAnnotatedReferenceService().createReference(
      analysisURL: fixture.bundle.url, resultID: fixture.resultID,
      outputDirectory: fixture.output, invocationArgv: argv)
    let manifest = try BundleManifest.load(from: reference)
    let track = try XCTUnwrap(manifest.annotations.first)
    let databasePath = try XCTUnwrap(track.databasePath)
    let database = try AnnotationDatabase(url: reference.appendingPathComponent(databasePath))
    let feature = try XCTUnwrap(database.query().first).toAnnotation()
    XCTAssertEqual(try PrimerAnalysisAnnotationLink.read(from: feature), .init(
      analysisID: fixture.bundle.manifest.analysisID, resultID: fixture.resultID, inputID: fixture.inputID))
    let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: reference))
    XCTAssertTrue(provenance.steps.contains { $0.argv == argv })
    let annotationStep = try XCTUnwrap(provenance.steps.last { $0.toolName == "lungfish annotation track import" })
    let outputs = annotationStep.outputs.filter { $0.role == .output }
    XCTAssertFalse(outputs.isEmpty)
    let referencePath = reference.resolvingSymlinksInPath().path + "/"
    for output in outputs {
      let url = URL(fileURLWithPath: output.path).resolvingSymlinksInPath()
      XCTAssertTrue(url.path.hasPrefix(referencePath), output.path)
      XCTAssertEqual(try ProvenanceFileHasher.sha256(of: url), output.checksumSHA256)
      XCTAssertEqual(try ProvenanceFileHasher.fileSize(of: url), output.fileSize)
    }
    _ = try PrimerAnalysisBundle.load(from: fixture.bundle.url)
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(
        at: fixture.root, includingPropertiesForKeys: nil))
    let temporaryDirectories = enumerator.compactMap { ($0 as? URL)?.lastPathComponent }
      .filter { $0.contains(".provenance-directory-") }
    XCTAssertEqual(temporaryDirectories, [])
  }

  private static func makeFixture(wrongLink: Bool = false) throws -> (
    root: URL, output: URL, bundle: PrimerAnalysisBundle, resultID: UUID, inputID: UUID
  ) {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    let output = root.appendingPathComponent("references")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let analysisID = UUID(), inputID = UUID(), resultID = UUID()
    let fasta = root.appendingPathComponent("template.fasta")
    try Data(">\(inputID.uuidString)\nACGTACGT\n".utf8).write(to: fasta)
    let bed = root.appendingPathComponent("features.bed")
    let attributes = "lungfish_primer_link_version=1;lungfish_primer_analysis_id=\(analysisID.uuidString);lungfish_primer_result_id=\((wrongLink ? UUID() : resultID).uuidString);lungfish_primer_input_id=\(inputID.uuidString)"
    let columns = [inputID.uuidString, "0", "4", "display fixture", "0", "+", "0", "4", "0,0,255", "1", "4", "0", "primer_bind", attributes]
    try Data((columns.joined(separator: "\t") + "\n").utf8).write(to: bed)
    let fastaPath = "inputs/\(inputID.uuidString).fasta"
    let bedPath = "annotations/\(inputID.uuidString).bed"
    let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
      analysisID: analysisID, runID: UUID(), grouping: .independent,
      inputs: [.init(id: inputID, artifactPaths: [fastaPath])],
      results: [.init(id: resultID, label: "Synthetic display fixture", inputIDs: [inputID], artifactPaths: [bedPath])],
      artifacts: [
        .init(sourceURL: fasta, relativePath: fastaPath, role: "input", format: "fasta"),
        .init(sourceURL: bed, relativePath: bedPath, role: "nativeOutput", format: "bed"),
      ], destinationURL: root.appendingPathComponent("fixture.lungfishprimeranalysis"),
      invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
    return (root, output, bundle, resultID, inputID)
  }
}
