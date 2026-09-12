import Darwin
import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimalScheme3PublicationTests: XCTestCase {
  func testCombinedSameBasenamesPreserveDistinctInputsAndRelocate() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = CommandRecorder()
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      await recorder.append(command.arguments)
      return try Self.nativeFixture(command)
    }, writer: PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)))
    let output = try await pipeline.run(request: request(fixture, grouping: .combined))
    let commands = await recorder.commands
    XCTAssertEqual(commands.count, 1)
    let argv = try XCTUnwrap(commands.first)
    XCTAssertEqual(argv.first, "panel-create")
    let mode = try XCTUnwrap(argv.firstIndex(of: "--mode"))
    XCTAssertEqual(argv[mode + 1], "equal")
    let msaPaths = argv.enumerated().compactMap { index, value in value == "--msa" ? argv[index + 1] : nil }
    XCTAssertEqual(Set(msaPaths.map { URL(fileURLWithPath: $0).lastPathComponent }).count, 2)
    let loaded = try PrimerAnalysisBundle.load(from: output)
    XCTAssertEqual(loaded.manifest.inputs.count, 2)
    XCTAssertEqual(loaded.manifest.results.count, 1)
    XCTAssertEqual(Set(loaded.manifest.results[0].inputIDs), Set(loaded.manifest.inputs.map(\.id)))
    for input in loaded.manifest.inputs {
      let mapPath = try XCTUnwrap(input.artifactPaths.first { $0.hasSuffix("-row-map.json") })
      let mapping = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: loaded.artifactURL(forRelativePath: mapPath))) as? [String: Any])
      XCTAssertEqual(mapping["inputID"] as? String, input.id.uuidString)
      let rows = try XCTUnwrap(mapping["rows"] as? [[String: Any]])
      XCTAssertEqual(rows.first?["originalHeader"] as? String, "Mafa-A*test:01 original header")
      let expectedName = "input_\(input.id.uuidString.replacingOccurrences(of: "-", with: ""))_row_0"
      XCTAssertEqual(rows.first?["normalizedHeader"] as? String, expectedName)
      let consumed = try XCTUnwrap(input.artifactPaths.first { $0 == "inputs/\(input.id.uuidString).fasta" })
      let consumedRows = try Primer3InputLoader.readAlignedRows(at: loaded.artifactURL(forRelativePath: consumed))
      XCTAssertEqual(consumedRows.first?.title, expectedName)
      XCTAssertEqual(consumedRows.first?.sequence, "aCGT-ACGT")
    }
    let extra = try XCTUnwrap(loaded.manifest.artifacts.first { $0.relativePath.hasSuffix("nested/extra.dat") })
    XCTAssertEqual(try Data(contentsOf: loaded.artifactURL(forRelativePath: extra.relativePath)), Data([0, 1, 255]))
    let provenanceFile = try XCTUnwrap(loaded.manifest.artifacts.first { $0.role == "toolProvenance" })
    let envelope = try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: loaded.artifactURL(forRelativePath: provenanceFile.relativePath)))
    XCTAssertTrue(envelope.outputs.allSatisfy { $0.path.hasPrefix(output.path + "/") })
    XCTAssertEqual(envelope.argv.first, "/fixture/primalscheme3")
    XCTAssertEqual(envelope.toolName, "PrimalScheme3-LGE (custom fork)")
    XCTAssertEqual(envelope.toolVersion, "3.3.0+lge.2")
    let policyFlag = try XCTUnwrap(envelope.argv.firstIndex(of: "--terminal-gap-policy"))
    XCTAssertEqual(envelope.argv[policyFlag + 1], "observed-only")
    let orderArtifact = try XCTUnwrap(loaded.manifest.artifacts.first { $0.role == "derived-order-sheet" })
    let orderProvenance = try XCTUnwrap(loaded.manifest.artifacts.first { $0.role == "derivedProvenance" })
    let derived = try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: loaded.artifactURL(forRelativePath: orderProvenance.relativePath)))
    XCTAssertEqual(derived.toolName, "Lungfish Primer Order Sheet")
    XCTAssertEqual(derived.outputs.first?.path, output.appendingPathComponent(orderArtifact.relativePath).path)
    XCTAssertTrue(derived.files.allSatisfy { $0.path.hasPrefix(output.path + "/") })
    XCTAssertFalse(envelope.outputs.contains { $0.path.hasSuffix(PrimalSchemeOrderSheet.filename) })
    let moved = fixture.root.appendingPathComponent("moved.lungfishprimeranalysis")
    try FileManager.default.moveItem(at: output, to: moved)
    for input in fixture.inputs { try FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
    XCTAssertNoThrow(try PrimerAnalysisBundle.load(from: moved))
  }

  func testIndependentRunsHaveSingleInputMemberships() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = CommandRecorder()
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      await recorder.append(command.arguments)
      return try Self.nativeFixture(command)
    }, writer: PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)))
    let output = try await pipeline.run(request: request(fixture, grouping: .independent))
    let commands = await recorder.commands
    XCTAssertEqual(commands.count, 2)
    XCTAssertTrue(commands.allSatisfy { $0.first == "scheme-create" })
    let bundle = try PrimerAnalysisBundle.load(from: output)
    XCTAssertEqual(bundle.manifest.results.count, 2)
    XCTAssertTrue(bundle.manifest.results.allSatisfy { $0.inputIDs.count == 1 })
  }

  func testChangedInputAndFailedExecutionCannotPublish() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalRequest = try request(fixture, grouping: .combined)
    try Data(">changed\nTGCA\n".utf8).write(to: fixture.inputs[0])
    let recorder = CommandRecorder()
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      await recorder.append(command.arguments)
      return try Self.nativeFixture(command, exitStatus: 1)
    })
    do {
      _ = try await pipeline.run(request: originalRequest)
      XCTFail("Expected changed input rejection")
    } catch { XCTAssertTrue(error.localizedDescription.contains("changed"), error.localizedDescription) }
    let beforeFailure = await recorder.commands
    XCTAssertTrue(beforeFailure.isEmpty)
    do {
      _ = try await pipeline.run(request: request(fixture, grouping: .combined))
      XCTFail("Expected failed execution")
    } catch { XCTAssertTrue(error.localizedDescription.contains("status 1"), error.localizedDescription) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  func testWrongNativePolicyCannotPublishAsMissingAware() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      try Self.nativeFixture(command, policy: "legacy")
    })
    do {
      _ = try await pipeline.run(request: request(fixture, grouping: .combined))
      XCTFail("A mismatched native policy must not be published")
    } catch { XCTAssertTrue(error.localizedDescription.contains("policy"), error.localizedDescription) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  func testInvalidEffectiveWorkerCountCannotPublish() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      try Self.nativeFixture(command, workers: 0)
    })
    do {
      _ = try await pipeline.run(request: request(fixture, grouping: .combined))
      XCTFail("An invalid effective worker count must not be published")
    } catch { XCTAssertTrue(error.localizedDescription.contains("worker"), error.localizedDescription) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  func testNativeSizeSettingsMustMatchRequestedBoundsBeforePublication() async throws {
    for changedKey in ["amplicon_size", "amplicon_size_min", "amplicon_size_max", "amplicon_size_metric"] {
      let fixture = try fixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let pipeline = PrimalScheme3DesignPipeline(runner: { command in
        let execution = try Self.nativeFixture(command)
        let index = try XCTUnwrap(command.arguments.firstIndex(of: "--output"))
        let configURL = URL(fileURLWithPath: command.arguments[index + 1]).appendingPathComponent("config.json")
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        config[changedKey] = changedKey == "amplicon_size_metric" ? "reference-span" : 199
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        return execution
      })
      do {
        _ = try await pipeline.run(request: request(fixture, grouping: .combined))
        XCTFail("Mismatched native \(changedKey) must not publish")
      } catch { XCTAssertTrue(error.localizedDescription.contains("amplicon"), error.localizedDescription) }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
  }

  private struct Fixture {
    let root: URL
    let inputs: [URL]
    let destination: URL
  }

  private func fixture() throws -> Fixture {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    var inputs: [URL] = []
    for index in 0..<2 {
      let parent = root.appendingPathComponent("source-\(index)")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let file = parent.appendingPathComponent("same-name.fasta")
      try Data(">Mafa-A*test:01 original header\naCGT-ACGT\n>row-\(index)\nACGTAACGT\n".utf8).write(to: file)
      inputs.append(file)
    }
    return Fixture(root: root, inputs: inputs, destination: root.appendingPathComponent("result.lungfishprimeranalysis"))
  }

  private func request(_ fixture: Fixture, grouping: PrimerAnalysisGrouping) throws -> PrimalScheme3DesignRequest {
    .init(inputURLs: fixture.inputs, destinationURL: fixture.destination,
      options: .init(ampliconSize: 400, poolCount: 2), grouping: grouping,
      invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()),
      expectedInputChecksums: Dictionary(uniqueKeysWithValues: try fixture.inputs.map { ($0, try Primer3InputLoader.fingerprint($0)) }))
  }

  private static func nativeFixture(_ command: PrimalScheme3Command, exitStatus: Int32 = 0, policy: String = "observed-only", workers: Int = 1) throws -> PrimalScheme3Execution {
    guard let outputIndex = command.arguments.firstIndex(of: "--output") else { throw CocoaError(.fileReadUnknown) }
    let output = URL(fileURLWithPath: command.arguments[outputIndex + 1])
    try FileManager.default.createDirectory(at: output.appendingPathComponent("nested"), withIntermediateDirectories: true)
    let config: [String: Any] = ["mode": "equal", "amplicon_size": 400, "n_pools": 2,
      "amplicon_size_min": 360, "amplicon_size_max": 440, "amplicon_size_metric": "legacy-pairing",
      "terminal_gap_policy": policy, "discovery_core_count": workers, "discovery_backend": policy == "legacy" ? "rust-legacy" : "python-observed-only"]
    try JSONSerialization.data(withJSONObject: config).write(to: output.appendingPathComponent("config.json"))
    try Data("fixture\t0\t4\tprimer\t1\t+\tACGT\n".utf8).write(to: output.appendingPathComponent("primer.bed"))
    try Data(">fixture\nACGT\n".utf8).write(to: output.appendingPathComponent("reference.fasta"))
    try Data([0, 1, 255]).write(to: output.appendingPathComponent("nested/extra.dat"))
    return .init(argv: ["/fixture/primalscheme3"] + command.arguments, stdout: "fixture output",
      stderr: exitStatus == 0 ? "" : "fixture failure", exitStatus: exitStatus, version: PrimalScheme3DesignPipeline.toolVersion,
      runtime: .init(executablePath: "/fixture/primalscheme3"), startedAt: Date(), endedAt: Date())
  }

  private actor CommandRecorder {
    var commands: [[String]] = []
    func append(_ argv: [String]) { commands.append(argv) }
  }
}
