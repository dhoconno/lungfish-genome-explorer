import Darwin
import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimalScheme3PublicationTests: XCTestCase {
  func testCoverageRequiresExplicitExecutableBeforeRuntimePreparation() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = CommandRecorder()
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      await recorder.append(command.arguments)
      return try Self.nativeFixture(command)
    }, runtimePreparer: { _ in
      XCTFail("Coverage must not prepare the managed lge.2 runtime")
      throw CocoaError(.fileReadUnknown)
    })
    do {
      _ = try await pipeline.run(request: coverageRequest(fixture, executableURL: nil))
      XCTFail("Coverage without an explicit executable must fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("--primalscheme3-path /path/to/primalscheme3"), error.localizedDescription)
    }
    let recordedCommands = await recorder.commands
    XCTAssertTrue(recordedCommands.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  func testCoverageRequiresValidCapabilityEvidenceFromInjectedRunner() async throws {
    for evidence in [nil, Data("{}".utf8)] {
      let fixture = try fixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let pipeline = PrimalScheme3DesignPipeline(runner: { command in
        var execution = try Self.nativeFixture(command, version: PrimalScheme3DesignPipeline.coverageToolVersion)
        execution.capabilitiesJSON = evidence
        return execution
      })
      do {
        _ = try await pipeline.run(request: coverageRequest(fixture, executableURL: URL(fileURLWithPath: "/fixture/lge3")))
        XCTFail("Coverage without valid capability evidence must fail")
      } catch {
        XCTAssertTrue(error.localizedDescription.lowercased().contains("capabilit") ||
                      error.localizedDescription.lowercased().contains("schema"), error.localizedDescription)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
  }

  func testExplicitVerifiedLGE3CanRunLegacyWithoutCoverageFlags() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      XCTAssertFalse(command.arguments.contains("--selection-algorithm"))
      XCTAssertFalse(command.arguments.contains("--coverage-metric"))
      return try Self.nativeFixture(command, version: PrimalScheme3DesignPipeline.coverageToolVersion)
    })
    let original = try request(fixture, grouping: .combined)
    let request = PrimalScheme3DesignRequest(inputURLs: original.inputURLs,
      destinationURL: original.destinationURL, options: original.options, grouping: original.grouping,
      invocation: original.invocation, executableURL: URL(fileURLWithPath: "/fixture/lge3"),
      expectedInputChecksums: original.expectedInputChecksums)
    _ = try await pipeline.run(request: request)
  }

  func testCoverageNativeContractPublishesAndRetainsLGE3Evidence() async throws {
    let fixture = try coverageFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      try Self.coverageNativeFixture(command)
    }, writer: PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)))
    let output = try await pipeline.run(request: coverageRequest(fixture,
      executableURL: URL(fileURLWithPath: "/fixture/lge3")))
    let bundle = try PrimerAnalysisBundle.load(from: output)
    let result = try XCTUnwrap(bundle.manifest.results.first)
    XCTAssertTrue(result.artifactPaths.contains { $0.hasSuffix("candidate-catalog.json.gz") })
    let execution = try XCTUnwrap(bundle.manifest.artifacts.first { $0.role == "toolProvenance" })
    let envelope = try ProvenanceEnvelopeReader.decodeCanonical(
      Data(contentsOf: bundle.artifactURL(forRelativePath: execution.relativePath)))
    XCTAssertEqual(envelope.toolVersion, PrimalScheme3DesignPipeline.coverageToolVersion)
    XCTAssertTrue(bundle.manifest.artifacts.contains { $0.relativePath.hasSuffix("capabilities.json") })
  }

  func testCoverageNativeContractAcceptsIndependentlyValidatedEmptyPanel() async throws {
    let fixture = try coverageFixture(nativeDirectory: "PrimalScheme3CoverageNativeEmpty",
      storedInputs: ["work/0000-fixture-empty-a.fasta", "work/0001-fixture-empty-b.fasta"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      try Self.coverageNativeFixture(command, fixtureName: "PrimalScheme3CoverageNativeEmpty")
    }, writer: PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)))
    let request = try coverageRequest(fixture, executableURL: URL(fileURLWithPath: "/fixture/lge3"),
      maxAmplicons: 0, maxAmpliconsPerMSA: 0)
    let output = try await pipeline.run(request: request)
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
  }

  func testCoverageNativeContractMutationsFailAtomically() async throws {
    let mutations = ["config-version", "config-seed", "config-coverage", "config-budget",
      "config-profile", "optimizer-algorithm", "validation-invalid", "validation-missing",
      "catalog-hash", "bed-pool", "provenance-source", "provenance-output",
      "provenance-input-swap", "catalog-duplicate-source-index", "catalog-fractional-source-index"]
    for mutation in mutations {
      let usesEmpty = mutation == "provenance-input-swap" || mutation.hasPrefix("catalog-") && mutation.hasSuffix("source-index")
      let fixture = usesEmpty
        ? try coverageFixture(nativeDirectory: "PrimalScheme3CoverageNativeEmpty",
            storedInputs: ["work/0000-fixture-empty-a.fasta", "work/0001-fixture-empty-b.fasta"])
        : try coverageFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let pipeline = PrimalScheme3DesignPipeline(runner: { command in
        try Self.coverageNativeFixture(command, mutation: mutation,
          fixtureName: usesEmpty ? "PrimalScheme3CoverageNativeEmpty" : "PrimalScheme3CoverageNative")
      })
      do {
        _ = try await pipeline.run(request: coverageRequest(fixture,
          executableURL: URL(fileURLWithPath: "/fixture/lge3"),
          maxAmplicons: usesEmpty ? 0 : nil, maxAmpliconsPerMSA: usesEmpty ? 0 : nil))
        XCTFail("Coverage mutation \(mutation) must not publish")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("PrimalScheme3-LGE"), error.localizedDescription)
        if mutation.hasPrefix("catalog-") && mutation.hasSuffix("source-index") {
          XCTAssertTrue(error.localizedDescription.contains("source mapping"), error.localizedDescription)
        }
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
  }

  func testRuntimeIsPreparedBeforeSnapshotsAndLeasedEnvironmentReachesRunner() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let runtimeRoot = fixture.root.appendingPathComponent("managed")
    let environment = runtimeRoot.appendingPathComponent("envs/primalscheme3")
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      XCTAssertEqual(command.managedEnvironmentURL, environment)
      XCTAssertNil(command.executableOverride)
      return try Self.nativeFixture(command)
    }, runtimePreparer: { progress in
      let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
      XCTAssertFalse(children.contains { $0.hasPrefix(".primalscheme3-") })
      progress?(0.04, "Runtime ready")
      return .init(environmentURL: environment, lock: try await CondaEnvironmentMutationLock.acquireCancellable(root: runtimeRoot, environment: "primalscheme3"))
    })
    _ = try await pipeline.run(request: request(fixture, grouping: .combined))
    let released = try await CondaEnvironmentMutationLock.acquireCancellable(root: runtimeRoot, environment: "primalscheme3")
    released.release()
  }

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

  private func coverageFixture(nativeDirectory: String = "PrimalScheme3CoverageNative",
                               storedInputs: [String] = ["work/0000-fixture-source.fasta"]) throws -> Fixture {
    let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(physical) }
    let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
    let inputs = try storedInputs.enumerated().map { index, storedInput in
      let parent = root.appendingPathComponent("coverage-source-\(index)")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let file = parent.appendingPathComponent("target.fasta")
      let storedFixture = Self.nativeCoverageFixtureURL(named: nativeDirectory).appendingPathComponent(storedInput)
      try FileManager.default.copyItem(at: storedFixture, to: file)
      return file
    }
    return Fixture(root: root, inputs: inputs, destination: root.appendingPathComponent("coverage.lungfishprimeranalysis"))
  }

  private func request(_ fixture: Fixture, grouping: PrimerAnalysisGrouping) throws -> PrimalScheme3DesignRequest {
    .init(inputURLs: fixture.inputs, destinationURL: fixture.destination,
      options: .init(ampliconSize: 400, poolCount: 2), grouping: grouping,
      invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()),
      expectedInputChecksums: Dictionary(uniqueKeysWithValues: try fixture.inputs.map { ($0, try Primer3InputLoader.fingerprint($0)) }))
  }

  private func coverageRequest(_ fixture: Fixture, executableURL: URL?,
                               maxAmplicons: Int? = nil, maxAmpliconsPerMSA: Int? = nil) throws -> PrimalScheme3DesignRequest {
    .init(inputURLs: fixture.inputs, destinationURL: fixture.destination,
      options: .init(ampliconSize: 200, poolCount: 2, coreCount: 1,
        maxAmplicons: maxAmplicons, maxAmpliconsPerMSA: maxAmpliconsPerMSA,
        ampliconSizeMinimum: 150, ampliconSizeMaximum: 280, selectionAlgorithm: .coverage,
        optimizerStarts: 1, optimizerRepairRounds: 0, optimizerTimeLimit: 5), grouping: .combined,
      invocation: .init(argv: CommandLine.arguments, callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()),
      executableURL: executableURL,
      expectedInputChecksums: Dictionary(uniqueKeysWithValues: try fixture.inputs.map { ($0, try Primer3InputLoader.fingerprint($0)) }))
  }

  private static func nativeFixture(_ command: PrimalScheme3Command, exitStatus: Int32 = 0, policy: String = "observed-only", workers: Int = 1, version: String = PrimalScheme3DesignPipeline.toolVersion) throws -> PrimalScheme3Execution {
    guard let outputIndex = command.arguments.firstIndex(of: "--output") else { throw CocoaError(.fileReadUnknown) }
    let output = URL(fileURLWithPath: command.arguments[outputIndex + 1])
    try FileManager.default.createDirectory(at: output.appendingPathComponent("nested"), withIntermediateDirectories: true)
    let config: [String: Any] = ["version": version, "mode": "equal", "amplicon_size": 400, "n_pools": 2,
      "amplicon_size_min": 360, "amplicon_size_max": 440, "amplicon_size_metric": "legacy-pairing",
      "terminal_gap_policy": policy, "discovery_core_count": workers, "discovery_backend": policy == "legacy" ? "rust-legacy" : "python-observed-only"]
    try JSONSerialization.data(withJSONObject: config).write(to: output.appendingPathComponent("config.json"))
    try Data("fixture\t0\t4\tprimer\t1\t+\tACGT\n".utf8).write(to: output.appendingPathComponent("primer.bed"))
    try Data(">fixture\nACGT\n".utf8).write(to: output.appendingPathComponent("reference.fasta"))
    try Data([0, 1, 255]).write(to: output.appendingPathComponent("nested/extra.dat"))
    return .init(argv: ["/fixture/primalscheme3"] + command.arguments, stdout: "fixture output",
      stderr: exitStatus == 0 ? "" : "fixture failure", exitStatus: exitStatus, version: version,
      runtime: .init(executablePath: "/fixture/primalscheme3"), startedAt: Date(), endedAt: Date())
  }

  private static func nativeCoverageFixtureURL(named name: String = "PrimalScheme3CoverageNative") -> URL {
    Bundle.module.resourceURL!.appendingPathComponent(name, isDirectory: true)
  }

  private static func coverageNativeFixture(_ command: PrimalScheme3Command,
                                            mutation: String? = nil,
                                            fixtureName: String = "PrimalScheme3CoverageNative") throws -> PrimalScheme3Execution {
    guard let outputIndex = command.arguments.firstIndex(of: "--output") else { throw CocoaError(.fileReadUnknown) }
    let output = URL(fileURLWithPath: command.arguments[outputIndex + 1])
    let nativeCoverageFixtureURL = nativeCoverageFixtureURL(named: fixtureName)
    try FileManager.default.copyItem(at: nativeCoverageFixtureURL, to: output)
    let fixtureInputs = try FileManager.default.contentsOfDirectory(
      at: nativeCoverageFixtureURL.appendingPathComponent("work"), includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("000") && $0.pathExtension == "fasta" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let msaArguments = command.arguments.enumerated().compactMap {
      $0.element == "--msa" && $0.offset + 1 < command.arguments.count ? command.arguments[$0.offset + 1] : nil
    }
    guard fixtureInputs.count == msaArguments.count else { throw CocoaError(.fileReadCorruptFile) }
    for (source, destination) in zip(fixtureInputs, msaArguments.map(URL.init(fileURLWithPath:))) {
      try Data(contentsOf: source).write(to: destination)
    }
    let provenanceURL = output.appendingPathComponent("panel-provenance.json")
    var provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)) as? [String: Any])
    provenance["command"] = ["argv": ["/fixture/lge3"] + command.arguments,
      "shell": (["/fixture/lge3"] + command.arguments).joined(separator: " "),
      "workingDirectory": command.workingDirectory.path]
    var inputs = try XCTUnwrap(provenance["inputs"] as? [[String: Any]])
    for index in inputs.indices where index < msaArguments.count { inputs[index]["sourcePath"] = msaArguments[index] }
    provenance["inputs"] = inputs
    if mutation == "provenance-source" {
      var source = try XCTUnwrap(provenance["source"] as? [String: Any]); source["gitCommit"] = "different"
      provenance["source"] = source
    } else if mutation == "provenance-output" {
      var outputs = try XCTUnwrap(provenance["outputs"] as? [[String: Any]])
      outputs[0]["sha256"] = String(repeating: "0", count: 64); provenance["outputs"] = outputs
    } else if mutation == "provenance-input-swap" {
      guard inputs.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
      let keys = ["storedPath", "sha256", "size", "sourceAtStartSha256", "sourceAtStartSize",
                  "sourceAtEndSha256", "sourceAtEndSize"]
      for key in keys { (inputs[0][key], inputs[1][key]) = (inputs[1][key], inputs[0][key]) }
      provenance["inputs"] = inputs
    }
    try writeJSON(provenance, to: provenanceURL)
    if mutation?.hasPrefix("config-") == true {
      try mutateJSON(output.appendingPathComponent("config.json")) {
        switch mutation {
        case "config-version": $0["version"] = "3.3.0+lge.2"
        case "config-seed": $0["optimizer_seed"] = 99
        case "config-coverage": $0["coverage_target"] = 0.8
        case "config-budget": $0["optimizer_time_limit"] = 99.0
        case "config-profile":
          var integration = try XCTUnwrap($0["panel_optimizer"] as? [String: Any])
          var profile = try XCTUnwrap(integration["profile"] as? [String: Any])
          profile["name"] = "wrong"; integration["profile"] = profile; $0["panel_optimizer"] = integration
        default: break
        }
      }
    } else if mutation == "optimizer-algorithm" {
      try mutateJSON(output.appendingPathComponent("panel-optimizer.json")) { $0["algorithm"] = "wrong" }
    } else if mutation == "validation-invalid" {
      try mutateJSON(output.appendingPathComponent("panel-validation.json")) {
        $0["valid"] = false; $0["violations"] = ["fixture failure"]
      }
    } else if mutation == "catalog-hash" {
      try Data("changed".utf8).write(to: output.appendingPathComponent("candidate-catalog.json.gz"))
    } else if mutation == "catalog-duplicate-source-index" {
      try mutateCatalogSourceIndex(output, value: 0)
    } else if mutation == "catalog-fractional-source-index" {
      try mutateCatalogSourceIndex(output, value: 0.5)
    } else if mutation == "validation-missing" {
      try FileManager.default.removeItem(at: output.appendingPathComponent("panel-validation.json"))
    } else if mutation == "bed-pool" {
      let bed = output.appendingPathComponent("amplicon.bed")
      let changed = try String(contentsOf: bed, encoding: .utf8).replacingOccurrences(of: "\t1\n", with: "\t9\n")
      try Data(changed.utf8).write(to: bed)
    }
    let capabilities = try Data(contentsOf: nativeCoverageFixtureURL.deletingLastPathComponent()
      .appendingPathComponent("PrimalScheme3CoverageCapabilities.json"))
    return .init(argv: ["/fixture/lge3"] + command.arguments, stdout: "reviewed native fixture", stderr: "",
      exitStatus: 0, version: PrimalScheme3DesignPipeline.coverageToolVersion,
      runtime: .init(executablePath: "/fixture/lge3"), startedAt: Date(), endedAt: Date(),
      runtimeEvidence: ["capabilities.json": capabilities], capabilitiesJSON: capabilities)
  }

  private static func mutateJSON(_ url: URL, _ body: (inout [String: Any]) throws -> Void) throws {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    try body(&object)
    try writeJSON(object, to: url)
  }

  private static func mutateCatalogSourceIndex(_ output: URL, value: Any) throws {
    let catalogURL = output.appendingPathComponent("candidate-catalog.json.gz")
    let text = try GzipInputStream(url: catalogURL).readAllSync()
    var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    var targets = try XCTUnwrap(catalog["targets"] as? [[String: Any]])
    var metadata = try XCTUnwrap(catalog["metadata"] as? [String: Any])
    var mapping = try XCTUnwrap(metadata["source_mapping"] as? [[Any]])
    guard targets.count == 2, mapping.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
    targets[1]["source_msa_index"] = value
    mapping[1][0] = value
    catalog["targets"] = targets
    metadata["source_mapping"] = mapping
    catalog["metadata"] = metadata
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-n", "-c"]
    let input = Pipe(), result = Pipe()
    process.standardInput = input; process.standardOutput = result
    try process.run()
    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]))
    try input.fileHandleForWriting.close()
    let compressed = result.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    try compressed.write(to: catalogURL)
    let hash = try ProvenanceFileHasher.sha256(of: catalogURL)
    let size = Int(try ProvenanceFileHasher.fileSize(of: catalogURL))
    var descriptor: [String: Any] = [:]
    try mutateJSON(output.appendingPathComponent("config.json")) {
      var integration = try XCTUnwrap($0["panel_optimizer"] as? [String: Any])
      descriptor = try XCTUnwrap(integration["catalog"] as? [String: Any])
      descriptor["fileSha256"] = hash; descriptor["fileSize"] = size
      integration["catalog"] = descriptor; $0["panel_optimizer"] = integration
    }
    try mutateJSON(output.appendingPathComponent("panel-optimizer.json")) {
      $0["catalog"] = descriptor
    }
    let config = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: output.appendingPathComponent("config.json"))) as? [String: Any])
    try mutateJSON(output.appendingPathComponent("panel-provenance.json")) {
      $0["resolvedOptions"] = config
      var scientific = try XCTUnwrap($0["scientific"] as? [String: Any])
      scientific["catalogFileSha256"] = hash; $0["scientific"] = scientific
      var outputs = try XCTUnwrap($0["outputs"] as? [[String: Any]])
      for index in outputs.indices {
        let path = try XCTUnwrap(outputs[index]["path"] as? String)
        if ["candidate-catalog.json.gz", "config.json", "panel-optimizer.json"].contains(path) {
          let file = output.appendingPathComponent(path)
          outputs[index]["sha256"] = try ProvenanceFileHasher.sha256(of: file)
          outputs[index]["size"] = Int(try ProvenanceFileHasher.fileSize(of: file))
        }
      }
      $0["outputs"] = outputs
    }
  }

  private static func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
  }

  private actor CommandRecorder {
    var commands: [[String]] = []
    func append(_ argv: [String]) { commands.append(argv) }
  }
}
