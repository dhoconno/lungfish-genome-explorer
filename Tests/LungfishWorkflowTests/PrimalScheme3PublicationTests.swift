import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class PrimalScheme3PublicationTests: XCTestCase {
  func testSingleSequenceReferenceBundleIsConsumedAsOneRowAndPreservedWithProvenance() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let input = root.appendingPathComponent("synthetic.lungfishref", isDirectory: true)
    let fasta = input.appendingPathComponent("genome/sequence.fa")
    try FileManager.default.createDirectory(at: fasta.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(">synthetic_reference\nACGTACGTACGT\n".utf8).write(to: fasta)
    try BundleManifest(name: "Synthetic reference", identifier: "org.lungfish.tests.synthetic",
      source: SourceInfo(organism: "Synthetic construct", assembly: "test-v1"),
      genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 12,
        chromosomes: [ChromosomeInfo(name: "synthetic_reference", length: 12, offset: 21,
          lineBases: 12, lineWidth: 13)])).save(to: input)
    let destination = root.appendingPathComponent("result.lungfishprimeranalysis")
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      let msaIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--msa"))
      let consumed = try String(contentsOfFile: command.arguments[msaIndex + 1], encoding: .utf8)
      XCTAssertEqual(consumed.split(whereSeparator: \.isNewline).last, "ACGTACGTACGT")
      return try Self.nativeFixture(command)
    }, writer: PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)))
    let request = PrimalScheme3DesignRequest(inputURLs: [input], destinationURL: destination,
      options: .init(ampliconSize: 400, poolCount: 2), grouping: .independent,
      invocation: .init(argv: ["lungfish", "primer", "design", input.path], callerVersion: "test",
        explicitOptions: [:], runtimeIdentity: .init()),
      expectedInputChecksums: [input: try Primer3InputLoader.fingerprint(input)])

    let output = try await pipeline.run(request: request)
    let bundle = try PrimerAnalysisBundle.load(from: output)
    XCTAssertTrue(bundle.manifest.artifacts.contains { $0.relativePath.hasSuffix("source.lungfishref/manifest.json") })
    XCTAssertTrue(bundle.manifest.artifacts.contains { $0.relativePath.hasSuffix("source.lungfishref/genome/sequence.fa") })
    let provenanceArtifact = try XCTUnwrap(bundle.manifest.artifacts.first { $0.role == "toolProvenance" })
    let provenance = try ProvenanceEnvelopeReader.decodeCanonical(
      Data(contentsOf: bundle.artifactURL(forRelativePath: provenanceArtifact.relativePath)))
    XCTAssertEqual(provenance.exitStatus, 0)
    XCTAssertNotNil(provenance.wallTimeSeconds)
    XCTAssertTrue(provenance.argv.contains("--msa"))
    let inputFiles = provenance.files.filter { $0.role == .input }
    XCTAssertFalse(inputFiles.isEmpty)
    XCTAssertTrue(inputFiles.allSatisfy {
      !$0.path.isEmpty && ($0.checksumSHA256?.isEmpty == false) && ($0.fileSize ?? 0) > 0
    })
  }

  func testCompressedSingleSequenceReferenceIsMaterializedAsUTF8AndPreservedWithProvenance() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let input = root.appendingPathComponent("compressed.lungfishref", isDirectory: true)
    let fasta = input.appendingPathComponent("genome/sequence.fa.gz")
    try FileManager.default.createDirectory(at: fasta.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.writeGzip(">synthetic_reference Original Case\nacguNACGT\n", to: fasta)
    try BundleManifest(name: "Compressed synthetic reference", identifier: "org.lungfish.tests.compressed",
      source: SourceInfo(organism: "Synthetic construct", assembly: "test-v1"),
      genome: GenomeInfo(path: "genome/sequence.fa.gz", indexPath: "genome/sequence.fa.gz.fai", totalLength: 9,
        chromosomes: [ChromosomeInfo(name: "synthetic_reference", length: 9, offset: 35,
          lineBases: 9, lineWidth: 10)])).save(to: input)
    let destination = root.appendingPathComponent("result.lungfishprimeranalysis")
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      let msaIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--msa"))
      let consumedURL = URL(fileURLWithPath: command.arguments[msaIndex + 1])
      XCTAssertEqual(try String(contentsOf: consumedURL, encoding: .utf8)
        .split(whereSeparator: \.isNewline).last, "acgT-ACGT")
      return try Self.nativeFixture(command)
    }, writer: PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)))
    let request = PrimalScheme3DesignRequest(inputURLs: [input], destinationURL: destination,
      options: .init(ampliconSize: 400, poolCount: 2), grouping: .independent,
      invocation: .init(argv: ["lungfish", "primer", "design", input.path], callerVersion: "test",
        explicitOptions: [:], runtimeIdentity: .init()),
      expectedInputChecksums: [input: try Primer3InputLoader.fingerprint(input)])

    let output = try await pipeline.run(request: request)
    let bundle = try PrimerAnalysisBundle.load(from: output)
    let sourceArtifact = try XCTUnwrap(bundle.manifest.artifacts.first {
      $0.relativePath.hasSuffix("source.lungfishref/genome/sequence.fa.gz")
    })
    XCTAssertEqual(try Data(contentsOf: bundle.artifactURL(forRelativePath: sourceArtifact.relativePath)),
      try Data(contentsOf: fasta))
    let inputManifest = try XCTUnwrap(bundle.manifest.inputs.first)
    let consumedPath = try XCTUnwrap(inputManifest.artifactPaths.first { $0.hasSuffix(".fasta") })
    let consumedURL = try bundle.artifactURL(forRelativePath: consumedPath)
    XCTAssertEqual(try String(contentsOf: consumedURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline).last, "acgT-ACGT")
    let mapPath = try XCTUnwrap(inputManifest.artifactPaths.first { $0.hasSuffix("-row-map.json") })
    let mapping = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: bundle.artifactURL(forRelativePath: mapPath))) as? [String: Any])
    XCTAssertEqual((mapping["rows"] as? [[String: Any]])?.first?["originalHeader"] as? String,
      "synthetic_reference Original Case")
    XCTAssertTrue((mapping["transformation"] as? String)?.contains("gzip decompressed") == true)
    let provenanceArtifact = try XCTUnwrap(bundle.manifest.artifacts.first { $0.role == "toolProvenance" })
    let provenance = try ProvenanceEnvelopeReader.decodeCanonical(
      Data(contentsOf: bundle.artifactURL(forRelativePath: provenanceArtifact.relativePath)))
    let sourceInputs = try XCTUnwrap(provenance.options.resolvedDefaults["sourceInputs"])
    XCTAssertTrue(String(describing: sourceInputs).contains("gzip-decompression-to-UTF8-FASTA"))
    XCTAssertTrue(provenance.files.contains { $0.path == consumedURL.path })
  }

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

  func testRecoveryWithoutExecutableUsesManagedRuntimePreparation() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    struct ManagedRuntimeUnavailable: LocalizedError {
      var errorDescription: String? { "managed runtime fixture" }
    }
    let original = try request(fixture, grouping: .combined)
    let options = PrimalScheme3DesignOptions(
      ampliconSize: 400, poolCount: 2, terminalGapPolicy: .legacy,
      legacySalvageOptions: .init(mode: .bounded))
    let pipeline = PrimalScheme3DesignPipeline(
      runner: { _ in
        XCTFail("Recovery must prepare the managed runtime before execution")
        throw ManagedRuntimeUnavailable()
      },
      runtimePreparer: { _ in throw ManagedRuntimeUnavailable() })
    let managedRequest = PrimalScheme3DesignRequest(
      inputURLs: original.inputURLs, destinationURL: original.destinationURL,
      options: options, grouping: original.grouping, invocation: original.invocation,
      executableURL: nil, expectedInputChecksums: original.expectedInputChecksums)
    do {
      _ = try await pipeline.run(request: managedRequest)
      XCTFail("Expected the managed runtime fixture to fail")
    } catch {
      XCTAssertEqual(error.localizedDescription, "managed runtime fixture")
    }
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

  func testCoverageNativeContractPreservesFreshUncertaintyOnJointRow() async throws {
    let fixture = try coverageFixture(nativeDirectory: "PrimalScheme3CoverageNativeUncertain",
      storedInputs: ["work/0000-fixture-uncertain.fasta"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pipeline = PrimalScheme3DesignPipeline(runner: { command in
      try Self.coverageNativeFixture(command, fixtureName: "PrimalScheme3CoverageNativeUncertain")
    }, writer: PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)))
    let request = try coverageRequest(fixture, executableURL: URL(fileURLWithPath: "/fixture/lge3"),
      misprimingProductSize: 199)
    let output = try await pipeline.run(request: request)
    let bundle = try PrimerAnalysisBundle.load(from: output)
    let artifact = try XCTUnwrap(bundle.manifest.artifacts.first {
      $0.relativePath.hasSuffix("panel-validation.json")
    })
    let validation = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: bundle.artifactURL(forRelativePath: artifact.relativePath))) as? [String: Any])
    let support = try XCTUnwrap(validation["support_diagnostics"] as? [String: [String: Any]])
    let diagnostic = try XCTUnwrap(support.values.first)
    let joint = Set(try XCTUnwrap(diagnostic["joint_rows"] as? [String]))
    let unknown = Set(try XCTUnwrap(diagnostic["unknown_rows"] as? [String]))
    XCTAssertFalse(joint.intersection(unknown).isEmpty)
  }

  func testCoverageFreshSupportMutationsFailAtomically() async throws {
    for mutation in ["support-unknown-row", "support-duplicate-unknown", "support-malformed-span",
                     "support-mismatched-joint", "support-mismatched-product"] {
      let fixture = try coverageFixture(nativeDirectory: "PrimalScheme3CoverageNativeUncertain",
        storedInputs: ["work/0000-fixture-uncertain.fasta"])
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let pipeline = PrimalScheme3DesignPipeline(runner: { command in
        try Self.coverageNativeFixture(command, mutation: mutation,
          fixtureName: "PrimalScheme3CoverageNativeUncertain")
      })
      do {
        _ = try await pipeline.run(request: coverageRequest(fixture,
          executableURL: URL(fileURLWithPath: "/fixture/lge3"), misprimingProductSize: 199))
        XCTFail("Coverage mutation \(mutation) must not publish")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("PrimalScheme:"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.lowercased().contains("support"), error.localizedDescription)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
  }

  func testCoverageNativeContractMutationsFailAtomically() async throws {
    let mutations = ["config-version", "config-seed", "config-coverage", "config-budget",
      "config-profile", "optimizer-algorithm", "validation-invalid", "validation-missing",
      "catalog-hash", "bed-pool", "provenance-source", "provenance-output",
      "provenance-input-swap", "catalog-duplicate-source-index", "catalog-fractional-source-index",
      "reference-duplicate-id", "primer-duplicate-member", "primer-shifted-footprint",
      "primer-flipped-strand", "nested-options-type", "nested-profile-type",
      "validation-missing-target", "validation-reference-length", "validation-metric",
      "validation-support-missing", "optimizer-target-summary"]
    for mutation in mutations {
      let usesEmpty = mutation == "provenance-input-swap" || mutation == "reference-duplicate-id" ||
        mutation == "validation-missing-target" || mutation == "validation-reference-length" ||
        mutation.hasPrefix("catalog-") && mutation.hasSuffix("source-index")
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
        XCTAssertTrue(error.localizedDescription.contains("PrimalScheme:"), error.localizedDescription)
        if mutation.hasPrefix("catalog-") && mutation.hasSuffix("source-index") {
          XCTAssertTrue(error.localizedDescription.contains("source mapping"), error.localizedDescription)
        } else if mutation == "reference-duplicate-id" {
          XCTAssertTrue(error.localizedDescription.lowercased().contains("duplicate"), error.localizedDescription)
        } else if mutation.hasPrefix("primer-") {
          XCTAssertTrue(error.localizedDescription.contains("Published primer"), error.localizedDescription)
        } else if mutation.hasPrefix("nested-") {
          XCTAssertTrue(error.localizedDescription.contains("profile") ||
            error.localizedDescription.contains("options"), error.localizedDescription)
        } else if ["validation-missing-target", "validation-reference-length", "validation-metric",
                   "validation-support-missing", "optimizer-target-summary"].contains(mutation) {
          XCTAssertTrue(error.localizedDescription.lowercased().contains("target") ||
            error.localizedDescription.lowercased().contains("support"), error.localizedDescription)
        }
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
  }

  func testCoverageJSONEqualityPreservesNumericTypesAndIntegerPrecision() {
    XCTAssertTrue(PrimalScheme3CoverageContract.equalJSON(51, 51.0))
    XCTAssertFalse(PrimalScheme3CoverageContract.equalJSON(true, 1))
    XCTAssertFalse(PrimalScheme3CoverageContract.equalJSON(
      NSNumber(value: Int64(9_007_199_254_740_992)),
      NSNumber(value: Int64(9_007_199_254_740_993))))
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
    let failures = try FileManager.default.contentsOfDirectory(at: fixture.destination.deletingLastPathComponent(),
      includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(fixture.destination.lastPathComponent + ".failure") }
    XCTAssertEqual(failures.count, 2)
    for failure in failures {
      let receipt = failure.appendingPathComponent("failure-provenance.json")
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
      XCTAssertTrue(["failed", "cancelled"].contains(object["status"] as? String))
      XCTAssertFalse(try XCTUnwrap(object["argv"] as? [String]).isEmpty)
      XCTAssertNotNil(object["wallTimeSeconds"] as? Double)
      XCTAssertNotNil(object["retainedFiles"] as? [[String: Any]])
    }
  }

  func testExecutorThrowRetainsStartedCommandEvidence() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pipeline = PrimalScheme3DesignPipeline(runner: { _ in throw CancellationError() })
    do {
      _ = try await pipeline.run(request: request(fixture, grouping: .combined))
      XCTFail("Expected executor failure")
    } catch {}
    let failure = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
      at: fixture.destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.hasPrefix(fixture.destination.lastPathComponent + ".failure") })
    let attempts = failure.appendingPathComponent("execution-attempts")
    let evidence = try FileManager.default.contentsOfDirectory(at: attempts, includingPropertiesForKeys: nil)
    XCTAssertTrue(evidence.contains { $0.lastPathComponent.hasSuffix("-design-request.json") })
    let receipt = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: failure.appendingPathComponent("failure-provenance.json"))) as? [String: Any])
    XCTAssertEqual(receipt["status"] as? String, "cancelled")
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
                               maxAmplicons: Int? = nil, maxAmpliconsPerMSA: Int? = nil,
                               misprimingProductSize: Int? = nil) throws -> PrimalScheme3DesignRequest {
    .init(inputURLs: fixture.inputs, destinationURL: fixture.destination,
      options: .init(ampliconSize: 200, poolCount: 2, coreCount: 1,
        maxAmplicons: maxAmplicons, maxAmpliconsPerMSA: maxAmpliconsPerMSA,
        ampliconSizeMinimum: 150, ampliconSizeMaximum: 280, selectionAlgorithm: .coverage,
        optimizerStarts: 1, optimizerRepairRounds: 0, optimizerTimeLimit: 5,
        misprimingProductSize: misprimingProductSize), grouping: .combined,
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

  private static func writeGzip(_ text: String, to output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-n", "-c"]
    let input = Pipe(), result = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = result
    process.standardError = errors
    try process.run()
    input.fileHandleForWriting.write(Data(text.utf8))
    try input.fileHandleForWriting.close()
    let compressed = result.fileHandleForReading.readDataToEndOfFile()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
        String(data: stderr, encoding: .utf8) ?? "gzip failed"])
    }
    try compressed.write(to: output)
  }

  private static func nativeCoverageFixtureURL(named name: String = "PrimalScheme3CoverageNative") -> URL {
    let root = Bundle.module.resourceURL!
    let copiedResources = root.appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    if FileManager.default.fileExists(atPath: copiedResources.path) { return copiedResources }
    return root.appendingPathComponent(name, isDirectory: true)
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
      try refreshProvenanceDescriptors(output, paths: ["amplicon.bed"])
    } else if mutation == "reference-duplicate-id" {
      try mutateDuplicateReferenceID(output)
    } else if mutation?.hasPrefix("primer-") == true {
      try mutatePrimerBED(output, mutation: try XCTUnwrap(mutation))
    } else if mutation?.hasPrefix("nested-") == true {
      try mutateNestedTypes(output, profile: mutation == "nested-profile-type")
    } else if mutation?.hasPrefix("validation-") == true || mutation == "optimizer-target-summary" {
      try mutateTargetMetadata(output, mutation: try XCTUnwrap(mutation))
    } else if mutation?.hasPrefix("support-") == true {
      try mutateSupportDiagnostics(output, mutation: try XCTUnwrap(mutation))
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

  private static func mutateDuplicateReferenceID(_ output: URL) throws {
    let url = output.appendingPathComponent("reference.fasta")
    var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    let headers = lines.indices.filter { lines[$0].hasPrefix(">") }
    guard headers.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
    lines[headers[1]] = lines[headers[0]]
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    try refreshProvenanceDescriptors(output, paths: ["reference.fasta"])
  }

  private static func mutatePrimerBED(_ output: URL, mutation: String) throws {
    let url = output.appendingPathComponent("primer.bed")
    var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    let records = lines.indices.filter { !lines[$0].hasPrefix("#") }
    guard records.count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
    var first = lines[records[0]].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    var second = lines[records[1]].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    if mutation == "primer-duplicate-member" {
      second[6] = first[6]
      second[1] = String(try XCTUnwrap(Int(second[2])) - first[6].count)
      lines[records[1]] = second.joined(separator: "\t")
    } else if mutation == "primer-shifted-footprint" {
      first[1] = String(try XCTUnwrap(Int(first[1])) + 1)
      first[2] = String(try XCTUnwrap(Int(first[2])) + 1)
      lines[records[0]] = first.joined(separator: "\t")
    } else if mutation == "primer-flipped-strand" {
      first[5] = "-"
      lines[records[0]] = first.joined(separator: "\t")
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    try refreshProvenanceDescriptors(output, paths: ["primer.bed"])
  }

  private static func mutateNestedTypes(_ output: URL, profile: Bool) throws {
    let field = profile ? "profile" : "options"
    try mutateJSON(output.appendingPathComponent("config.json")) {
      var integration = try XCTUnwrap($0["panel_optimizer"] as? [String: Any])
      var nested = try XCTUnwrap(integration[field] as? [String: Any])
      if profile { nested["mismatch_fuzzy"] = 1 } else { nested["seed"] = false }
      integration[field] = nested; $0["panel_optimizer"] = integration
    }
    try mutateJSON(output.appendingPathComponent("panel-optimizer.json")) {
      var nested = try XCTUnwrap($0[field] as? [String: Any])
      if profile { nested["mismatch_fuzzy"] = 1 } else { nested["seed"] = false }
      $0[field] = nested
      if profile {
        var validation = try XCTUnwrap($0["validation"] as? [String: Any])
        validation["profile"] = nested; $0["validation"] = validation
      }
    }
    if profile {
      try mutateJSON(output.appendingPathComponent("panel-validation.json")) {
        var nested = try XCTUnwrap($0["profile"] as? [String: Any])
        nested["mismatch_fuzzy"] = 1; $0["profile"] = nested
      }
    }
    try refreshProvenanceDescriptors(output,
      paths: profile ? ["config.json", "panel-optimizer.json", "panel-validation.json"] : ["config.json", "panel-optimizer.json"],
      synchronizeConfiguration: true, synchronizeScientificProfile: profile)
  }

  private static func mutateTargetMetadata(_ output: URL, mutation: String) throws {
    let validationURL = output.appendingPathComponent("panel-validation.json")
    var validation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: validationURL)) as? [String: Any])
    var perTarget = try XCTUnwrap(validation["per_target"] as? [String: [String: Any]])
    if mutation == "validation-missing-target" {
      perTarget.removeValue(forKey: try XCTUnwrap(perTarget.keys.sorted().first))
      validation["per_target"] = perTarget
    } else if mutation == "validation-reference-length" {
      let key = try XCTUnwrap(perTarget.keys.sorted().first)
      var summary = try XCTUnwrap(perTarget[key])
      summary["reference_length"] = (try XCTUnwrap(summary["reference_length"] as? Int)) + 1
      perTarget[key] = summary
      validation["per_target"] = perTarget
    } else if mutation == "validation-metric" {
      let key = try XCTUnwrap(perTarget.keys.sorted().first)
      perTarget[key]?["coverage_fraction"] = 0.5
      validation["per_target"] = perTarget
    } else if mutation == "validation-support-missing" {
      var support = try XCTUnwrap(validation["support_diagnostics"] as? [String: Any])
      support.removeValue(forKey: try XCTUnwrap(support.keys.sorted().first))
      validation["support_diagnostics"] = support
    }
    try writeJSON(validation, to: validationURL)
    try mutateJSON(output.appendingPathComponent("panel-optimizer.json")) {
      if mutation == "optimizer-target-summary" {
        var summaries = try XCTUnwrap($0["per_target"] as? [String: [String: Any]])
        let key = try XCTUnwrap(summaries.keys.sorted().first)
        var summary = try XCTUnwrap(summaries[key])
        summary["covered_bases"] = (try XCTUnwrap(summary["covered_bases"] as? Int)) + 1
        summaries[key] = summary
        $0["per_target"] = summaries
      } else {
        $0["validation"] = validation
      }
    }
    try refreshProvenanceDescriptors(output, paths: ["panel-validation.json", "panel-optimizer.json"])
  }

  private static func mutateSupportDiagnostics(_ output: URL, mutation: String) throws {
    let validationURL = output.appendingPathComponent("panel-validation.json")
    var validation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: validationURL)) as? [String: Any])
    var support = try XCTUnwrap(validation["support_diagnostics"] as? [String: [String: Any]])
    let candidateID = try XCTUnwrap(support.keys.first)
    var diagnostic = try XCTUnwrap(support[candidateID])
    if mutation == "support-unknown-row" {
      var unknown = try XCTUnwrap(diagnostic["unknown_rows"] as? [String])
      unknown.append("row-not-in-target"); diagnostic["unknown_rows"] = unknown
    } else if mutation == "support-duplicate-unknown" {
      var unknown = try XCTUnwrap(diagnostic["unknown_rows"] as? [String])
      unknown.append(try XCTUnwrap(unknown.first)); diagnostic["unknown_rows"] = unknown
    } else if mutation == "support-malformed-span" {
      var spans = try XCTUnwrap(diagnostic["row_product_spans"] as? [[Any]])
      spans[0][1] = false; diagnostic["row_product_spans"] = spans
    } else if mutation == "support-mismatched-joint" {
      var joint = try XCTUnwrap(diagnostic["joint_rows"] as? [String])
      joint.removeLast(); diagnostic["joint_rows"] = joint
    } else if mutation == "support-mismatched-product" {
      var spans = try XCTUnwrap(diagnostic["row_product_spans"] as? [[Any]])
      spans[0][1] = (try XCTUnwrap(spans[0][1] as? Int)) + 1
      diagnostic["row_product_spans"] = spans
    }
    support[candidateID] = diagnostic
    validation["support_diagnostics"] = support
    try writeJSON(validation, to: validationURL)
    try mutateJSON(output.appendingPathComponent("panel-optimizer.json")) { $0["validation"] = validation }
    try refreshProvenanceDescriptors(output, paths: ["panel-validation.json", "panel-optimizer.json"])
  }

  private static func refreshProvenanceDescriptors(_ output: URL, paths: Set<String>,
                                                   synchronizeConfiguration: Bool = false,
                                                   synchronizeScientificProfile: Bool = false) throws {
    try mutateJSON(output.appendingPathComponent("panel-provenance.json")) {
      if synchronizeConfiguration {
        let config = try XCTUnwrap(JSONSerialization.jsonObject(
          with: Data(contentsOf: output.appendingPathComponent("config.json"))) as? [String: Any])
        $0["resolvedOptions"] = config
        if synchronizeScientificProfile {
          let integration = try XCTUnwrap(config["panel_optimizer"] as? [String: Any])
          var scientific = try XCTUnwrap($0["scientific"] as? [String: Any])
          scientific["profile"] = integration["profile"]
          $0["scientific"] = scientific
        }
      }
      var descriptors = try XCTUnwrap($0["outputs"] as? [[String: Any]])
      for index in descriptors.indices {
        let path = try XCTUnwrap(descriptors[index]["path"] as? String)
        guard paths.contains(path) else { continue }
        let file = output.appendingPathComponent(path)
        descriptors[index]["sha256"] = try ProvenanceFileHasher.sha256(of: file)
        descriptors[index]["size"] = Int(try ProvenanceFileHasher.fileSize(of: file))
      }
      $0["outputs"] = descriptors
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
