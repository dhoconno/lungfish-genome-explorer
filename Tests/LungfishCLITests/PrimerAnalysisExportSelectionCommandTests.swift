import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Phase 2.12 lane 12.15 (A67-M3). The `primers analysis export-selection` leaf names one selection of a saved
/// primer analysis and writes the folder the app writes for it. The app-side parity is
/// `PrimerSelectionExportParityTests` in the App tests.
final class PrimerAnalysisExportSelectionCommandTests: XCTestCase {
  private func parse(_ arguments: [String]) throws -> PrimerAnalysisExportSelectionCommand {
    // The parse stays outside XCTUnwrap, which would record a refusal as a failure of its own.
    let parsed = try LungfishCLI.parseAsRoot(
      ["primers", "analysis", "export-selection", "input.lungfishprimeranalysis"] + arguments
        + ["--output", "/tmp/selection.lungfishref"])
    return try XCTUnwrap(parsed as? PrimerAnalysisExportSelectionCommand)
  }

  func testRegisteredCommandParsesEachSelectionForm() throws {
    let primer = try parse(["--kind", "primer-fasta", "--target-id", "t-1", "--primer-id", "p-3"])
    XCTAssertEqual(primer.kind, .primerFASTA)
    XCTAssertEqual(primer.kind.exportKind, .primerFASTA)
    XCTAssertEqual(try primer.selection(), .primer(targetID: "t-1", primerID: "p-3"))
    XCTAssertEqual(primer.outputPath, "/tmp/selection.lungfishref")

    let amplicon = try parse(["--kind", "reference-amplicon", "--target-id", "t-1", "--amplicon-id", "a-2"])
    XCTAssertEqual(amplicon.kind.exportKind, .referenceAmplicon)
    XCTAssertEqual(try amplicon.selection(), .amplicon(targetID: "t-1", ampliconID: "a-2"))
    XCTAssertEqual(try parse(["--kind", "primer-fasta", "--target-id", "t-1", "--amplicon-id", "a-2"]).selection(),
      .amplicon(targetID: "t-1", ampliconID: "a-2"), "an amplicon's primers are a primer FASTA selection")

    let pool = try parse(["--kind", "primer-fasta", "--source-result-id", "r-1", "--pool", "2"])
    XCTAssertEqual(try pool.selection(), .pool(sourceResultID: "r-1", pool: 2))
    let native = try parse(["--kind", "primer-fasta", "--source-result-id", "r-1", "--native-pool", "native-A"])
    XCTAssertEqual(try native.selection(), .nativePool(sourceResultID: "r-1", pool: "native-A"))

    let policy = try XCTUnwrap(ScientificProvenancePolicy.cliCommand(path: ["primers", "analysis", "export-selection"]))
    XCTAssertTrue(policy.requiresProvenance)
  }

  func testRefusesASelectionThatIsMissingMixedOrAmbiguous() throws {
    let refused: [[String]] = [
      ["--kind", "primer-fasta"],
      ["--kind", "primer-fasta", "--target-id", "t-1"],
      ["--kind", "primer-fasta", "--primer-id", "p-3"],
      ["--kind", "primer-fasta", "--target-id", "t-1", "--primer-id", "p-3", "--amplicon-id", "a-2"],
      ["--kind", "primer-fasta", "--source-result-id", "r-1"],
      ["--kind", "primer-fasta", "--source-result-id", "r-1", "--pool", "1", "--native-pool", "A"],
      ["--kind", "primer-fasta", "--target-id", "t-1", "--primer-id", "p-3", "--source-result-id", "r-1", "--pool", "1"],
      ["--kind", "primer-fasta", "--source-result-id", "r-1", "--pool", "0"],
      ["--kind", "primer-fasta", "--source-result-id", "r-1", "--native-pool", "  "],
      ["--kind", "reference-amplicon", "--target-id", "t-1", "--primer-id", "p-3"],
      ["--kind", "reference-amplicon", "--source-result-id", "r-1", "--pool", "1"],
      ["--kind", "everything", "--target-id", "t-1", "--primer-id", "p-3"],
    ]
    for arguments in refused {
      XCTAssertThrowsError(try parse(arguments), "\(arguments)")
    }
    XCTAssertThrowsError(try PrimerAnalysisExportSelectionCommand.parse(
      ["a", "--target-id", "t-1", "--primer-id", "p-3", "--output", "/tmp/o.lungfishref"]), "--kind is required")
    XCTAssertThrowsError(try PrimerAnalysisExportSelectionCommand.parse(
      ["a", "--kind", "primer-fasta", "--target-id", "t-1", "--primer-id", "p-3"]), "--output is required")
    XCTAssertThrowsError(try PrimerAnalysisExportSelectionCommand.parse(
      ["a", "--kind", "primer-fasta", "--target-id", "t-1", "--primer-id", "p-3", "--output", "/tmp/out"]),
      "--output must end in .lungfishref")
  }

  func testHelpNamesTheKindsTheSelectionsAndTheReplaceRule() {
    let help = PrimerAnalysisExportSelectionCommand.helpMessage()
    for part in ["primer-fasta", "reference-amplicon", "--target-id", "--source-result-id", "--native-pool", "replaced"] {
      XCTAssertTrue(help.contains(part), "\(part) is missing from the help")
    }
  }

  func testWritesThePoolAndTheAmpliconFoldersThroughTheSharedService() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let amplicon = try XCTUnwrap(target.intervals.first)

    let pool = fixture.root.appendingPathComponent("pool-one.lungfishref")
    let expectedPool = pool.standardizedFileURL.path
    let poolCommand = try PrimerAnalysisExportSelectionCommand.parse([fixture.bundle.path, "--kind", "primer-fasta",
      "--source-result-id", target.sourceResultID, "--pool", "1", "--output", pool.path])
    try await poolCommand.run()
    let fasta = try String(contentsOf: pool.appendingPathComponent("primers.fasta"), encoding: .utf8)
    let prepared = try PrimerAnalysisSelectionExportService.prepare(snapshot: snapshot,
      selection: .pool(sourceResultID: target.sourceResultID, pool: 1), kind: .primerFASTA)
    XCTAssertEqual(fasta, prepared.fasta, "the command writes what the shared service prepares")
    XCTAssertEqual(prepared.records.count, 3)
    let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: pool))
    XCTAssertEqual(envelope.workflowName, "lungfish.primer-analysis.selection-export")
    XCTAssertEqual(envelope.argv, [
      CLICommandIdentity.executableName, "primers", "analysis", "export-selection", fixture.bundle.standardizedFileURL.path,
      "--kind", "primer-fasta", "--source-result-id=\(target.sourceResultID)", "--pool", "1",
      "--output", expectedPool,
    ], "the record names the command with absolute paths")
    XCTAssertEqual(envelope.exitStatus, 0)
    XCTAssertEqual(envelope.options.resolvedDefaults["pool"], .integer(1))

    let span = fixture.root.appendingPathComponent("amplicon.lungfishref")
    let spanCommand = try PrimerAnalysisExportSelectionCommand.parse([fixture.bundle.path, "--kind", "reference-amplicon",
      "--target-id", target.id, "--amplicon-id", amplicon.id, "--output", span.path])
    try await spanCommand.run()
    let reference = try String(contentsOf: span.appendingPathComponent("amplicon.fasta"), encoding: .utf8)
    XCTAssertTrue(reference.contains("CCGGTTAA"), reference)
    XCTAssertTrue(FileManager.default.fileExists(atPath: span.appendingPathComponent("binding-sites.bed").path))
  }

  func testRefusesAnExistingOutputAnAbsentParentAndAnUnknownPrimerWithoutWritingAnything() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let output = fixture.root.appendingPathComponent("taken.lungfishref")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let sentinel = output.appendingPathComponent("sentinel")
    try Data("preserve".utf8).write(to: sentinel)

    let taken = try PrimerAnalysisExportSelectionCommand.parse([fixture.bundle.path, "--kind", "primer-fasta",
      "--source-result-id", target.sourceResultID, "--pool", "1", "--output", output.path])
    do { _ = try await taken.export(); XCTFail("An existing output must be refused") } catch {
      XCTAssertTrue(String(describing: error).contains("already exists"), "\(error)")
    }
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))

    let orphan = try PrimerAnalysisExportSelectionCommand.parse([fixture.bundle.path, "--kind", "primer-fasta",
      "--source-result-id", target.sourceResultID, "--pool", "1",
      "--output", fixture.root.appendingPathComponent("absent/out.lungfishref").path])
    do { try await orphan.run(); XCTFail("A missing parent must be refused") } catch {}

    let missing = fixture.root.appendingPathComponent("unknown.lungfishref")
    let unknown = try PrimerAnalysisExportSelectionCommand.parse([fixture.bundle.path, "--kind", "primer-fasta",
      "--target-id", target.id, "--primer-id", "invented", "--output", missing.path])
    do { _ = try await unknown.export(); XCTFail("An unknown primer must be refused") } catch {
      XCTAssertTrue(error.localizedDescription.contains("no longer present"), error.localizedDescription)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".primer-selection-") })
  }

  func testRefusesAnOutputInsideTheSavedAnalysisAndLeavesItUnchanged() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundle)
    let target = try XCTUnwrap(snapshot.designReview.first)
    let before = try relativeEntries(of: fixture.bundle)
    XCTAssertFalse(before.isEmpty, "the saved analysis holds files to compare")

    let inside = fixture.bundle.appendingPathComponent("inside.lungfishref")
    let command = try PrimerAnalysisExportSelectionCommand.parse([fixture.bundle.path, "--kind", "primer-fasta",
      "--source-result-id", target.sourceResultID, "--pool", "1", "--output", inside.path])
    do { _ = try await command.export(); XCTFail("An output inside the saved analysis must be refused") } catch {
      XCTAssertTrue(String(describing: error).contains("inside the saved analysis"), "\(error)")
    }
    XCTAssertEqual(try relativeEntries(of: fixture.bundle), before,
      "the saved analysis is never changed, so no output folder and no .primer-selection- staging entry appear in it")
  }

  /// Every file and folder under `folder`, hidden entries included, as sorted paths relative to it.
  private func relativeEntries(of folder: URL) throws -> [String] {
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
    return enumerator.compactMap { ($0 as? URL).map { String($0.path.dropFirst(folder.path.count + 1)) } }.sorted()
  }

  /// A PrimalScheme-style analysis with one amplicon and three primers, the fixture the Workflow tests use.
  private func makeFixture() throws -> (root: URL, bundle: URL) {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    free(physical)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let inputID = UUID(), resultID = UUID()
    let payloads = [
      "inputs/source.fasta": ">reference\nAACCGGTTAACC\n",
      "native/reference.fasta": ">reference\nAACCGGTTAACC\n",
      "native/primer.bed": "reference\t2\t4\tfixture_1_LEFT_0\t1\t+\tCC\nreference\t2\t4\tfixture_1_LEFT_1\t1\t+\tCR\nreference\t8\t10\tfixture_1_RIGHT_0\t1\t-\tTT\n",
      "native/amplicon.bed": "reference\t2\t10\tfixture_1\t1\n",
    ]
    let artifacts = try payloads.sorted { $0.key < $1.key }.map { path, text in
      let source = root.appendingPathComponent(UUID().uuidString)
      try Data(text.utf8).write(to: source)
      return PrimerAnalysisSourceArtifact(sourceURL: source, relativePath: path,
        role: path.hasPrefix("inputs/") ? "input" : "nativeOutput", format: path.hasSuffix(".bed") ? "bed" : "fasta")
    }
    let bundle = try PrimerAnalysisBundleWriter(provenanceWriter: .init(signingProvider: nil)).write(.init(
      analysisID: UUID(), runID: UUID(), grouping: .independent,
      inputs: [.init(id: inputID, artifactPaths: ["inputs/source.fasta"])],
      results: [.init(id: resultID, label: "Stored synthetic MHC display example", inputIDs: [inputID],
        artifactPaths: payloads.keys.filter { $0.hasPrefix("native/") }.sorted())], artifacts: artifacts,
      destinationURL: root.appendingPathComponent("source.lungfishprimeranalysis"),
      invocation: .init(argv: ["export-selection-fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
    return (root, bundle.url)
  }
}
