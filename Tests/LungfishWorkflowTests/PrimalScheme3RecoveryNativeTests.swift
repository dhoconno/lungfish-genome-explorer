import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// Opt-in native-backed coverage of the GUI-facing gap-completion request.
///
/// The executable is supplied by the caller because the managed runtime predates
/// recovery flags. The test creates its own parent in a temporary directory and
/// never modifies the executable or any checked-in native output.
final class PrimalScheme3RecoveryNativeTests: XCTestCase {
    func testBoundedLegacySalvageNativeSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executablePath = environment["LUNGFISH_REAL_GAP_EXECUTABLE"] else {
            throw XCTSkip("Set LUNGFISH_REAL_GAP_EXECUTABLE to run the opt-in native recovery test.")
        }
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("LUNGFISH_REAL_GAP_EXECUTABLE is not executable: \(executable.path)")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimalScheme3SalvageNative-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Bundle.module.resourceURL!
            .appendingPathComponent("Resources/PrimalScheme3CoverageNative/work/0000-fixture-source.fasta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), fixture.path)
        let input = root.appendingPathComponent("salvage-input.fasta")
        try FileManager.default.copyItem(at: fixture, to: input)
        let destination = root.appendingPathComponent("salvage.lungfishprimeranalysis", isDirectory: true)
        let salvage = PrimalScheme3LegacySalvageOptions(mode: .bounded, maxCandidateEvaluations: 64)
        let options = PrimalScheme3DesignOptions(
            ampliconSize: 200, poolCount: 2, minOverlap: 10,
            minimumBaseFrequency: 0, highGC: false, coreCount: 1,
            terminalGapPolicy: .legacy, dimerScore: -26, useMatchDB: true,
            panelMode: .equal,
            ampliconSizeMinimum: 150, ampliconSizeMaximum: 280,
            legacySalvageOptions: salvage)
        let request = PrimalScheme3DesignRequest(
            inputURLs: [input], destinationURL: destination, options: options,
            grouping: .combined,
            invocation: .init(
                argv: ["lungfish-cli", "primers", "design", input.path, "--legacy-salvage", "bounded"],
                callerVersion: "native-recovery-test", explicitOptions: options.provenanceOptions,
                runtimeIdentity: .init(executablePath: executable.path)),
            executableURL: executable,
            expectedInputChecksums: [input: try Primer3InputLoader.fingerprint(input)])
        let output = try await PrimalScheme3DesignPipeline().run(request: request)
        let bundle = try PrimerAnalysisBundle.load(from: output)
        let nativeArtifacts = bundle.manifest.artifacts.filter { $0.role == "nativeOutput" }
        XCTAssertTrue(nativeArtifacts.contains { $0.relativePath.hasSuffix("/legacy-salvage.json") })
        XCTAssertTrue(nativeArtifacts.contains { $0.relativePath.hasSuffix("/legacy-salvage-validation.json") })
        XCTAssertEqual(bundle.manifest.provenance.relativePath, "provenance/wrapper.json")
        let tool = try XCTUnwrap(bundle.manifest.artifacts.first { $0.role == "toolProvenance" })
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(
            Data(contentsOf: bundle.artifactURL(forRelativePath: tool.relativePath)))
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertTrue(envelope.argv.contains("--legacy-salvage"))
    }

    func testGapCompletionPublishesRenamedInputParentEvidenceAndFollowupPools() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executablePath = environment["LUNGFISH_REAL_GAP_EXECUTABLE"] else {
            throw XCTSkip("Set LUNGFISH_REAL_GAP_EXECUTABLE to run the opt-in native recovery test.")
        }
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("LUNGFISH_REAL_GAP_EXECUTABLE is not executable: \(executable.path)")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimalScheme3RecoveryNative-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = Bundle.module.resourceURL!
            .appendingPathComponent("Resources/PrimalScheme3CoverageNative/work/0000-fixture-source.fasta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), fixture.path)
        let originalInput = root.appendingPathComponent("original-user-input.fasta")
        let renamedInput = root.appendingPathComponent("renamed-user-input.fasta")
        try FileManager.default.copyItem(at: fixture, to: originalInput)
        try FileManager.default.copyItem(at: originalInput, to: renamedInput)

        // Build the parent through the same LGE pipeline used by the GUI. This
        // deliberately gives the native parent UUID-normalized consumed rows;
        // the follow-up then has to rehydrate those rows from the parent bundle
        // while consuming the same source content from a renamed path.
        let parent = root.appendingPathComponent(
            "primary-parent.lungfishprimeranalysis", isDirectory: true)
        let parentOptions = PrimalScheme3DesignOptions(
            ampliconSize: 200, poolCount: 2, minOverlap: 10,
            minimumBaseFrequency: 0, highGC: false, coreCount: 1,
            terminalGapPolicy: .legacy, dimerScore: -26, useMatchDB: true,
            panelMode: .equal, maxAmplicons: 1,
            ampliconSizeMinimum: 150, ampliconSizeMaximum: 280)
        let parentRequest = PrimalScheme3DesignRequest(
            inputURLs: [originalInput], destinationURL: parent, options: parentOptions,
            grouping: .combined,
            invocation: .init(
                argv: ["lungfish-cli", "primers", "design", originalInput.path],
                callerVersion: "native-recovery-test",
                explicitOptions: parentOptions.provenanceOptions,
                runtimeIdentity: .init(executablePath: executable.path)),
            executableURL: executable,
            expectedInputChecksums: [originalInput: try Primer3InputLoader.fingerprint(originalInput)])
        _ = try await PrimalScheme3DesignPipeline().run(request: parentRequest)
        let parentBefore = try Self.inventory(parent)

        let destination = root.appendingPathComponent(
            "followup.lungfishprimeranalysis", isDirectory: true)
        let options = PrimalScheme3DesignOptions(
            ampliconSize: 200, poolCount: 3, minOverlap: 10,
            minimumBaseFrequency: 0, highGC: false, coreCount: 1,
            terminalGapPolicy: .legacy, dimerScore: -26, useMatchDB: true,
            panelMode: .equal, ampliconSizeMinimum: 150, ampliconSizeMaximum: 280,
            gapCompletionParent: parent,
            gapExpansionOptions: .init(mode: .bounded, maxAnchorsPerMSA: 32, maxPairsPerMSA: 16))
        let request = PrimalScheme3DesignRequest(
            inputURLs: [renamedInput], destinationURL: destination, options: options,
            grouping: .combined,
            invocation: .init(
                argv: ["lungfish-cli", "primers", "design", renamedInput.path,
                       "--gap-completion-parent", parent.path],
                callerVersion: "native-recovery-test",
                explicitOptions: options.provenanceOptions,
                runtimeIdentity: .init(executablePath: executable.path)),
            executableURL: executable,
            expectedInputChecksums: [renamedInput: try Primer3InputLoader.fingerprint(renamedInput)])

        let output = try await PrimalScheme3DesignPipeline().run(request: request)
        let bundle = try PrimerAnalysisBundle.load(from: output)
        XCTAssertEqual(try Self.inventory(parent), parentBefore, "The parent must remain byte-for-byte unchanged.")

        let nativeArtifacts = bundle.manifest.artifacts.filter { $0.role == "nativeOutput" }
        let nativePaths = Set(nativeArtifacts.map(\.relativePath))
        let reportPath = try XCTUnwrap(nativePaths.first { $0.hasSuffix("/gap-completion.json") })
        let coveragePath = try XCTUnwrap(nativePaths.first { $0.hasSuffix("/gap-completion-coverage.json") })
        let nativePrefix = String(reportPath.dropLast("/gap-completion.json".count))
        XCTAssertTrue(nativePaths.contains { $0.hasPrefix(nativePrefix + "/parent/") })
        XCTAssertTrue(nativePaths.contains(nativePrefix + "/primer.bed"))
        XCTAssertTrue(nativePaths.contains(nativePrefix + "/reference.fasta"))
        XCTAssertTrue(nativePaths.contains { $0.hasSuffix("/panel-provenance.json") })

        let report = try Self.jsonObject(bundle, relativePath: reportPath)
        let coverage = try Self.jsonObject(bundle, relativePath: coveragePath)
        let parentReport = try XCTUnwrap(report["parent"] as? [String: Any])
        XCTAssertEqual(parentReport["unchangedAfterRun"] as? Bool, true)
        XCTAssertNotNil(parentReport["schemeId"] as? String)
        XCTAssertNotNil(report["followup"] as? [String: Any])
        XCTAssertNotNil(coverage["primary"])
        XCTAssertNotNil(coverage["followup"])
        XCTAssertNotNil(coverage["combined"])

        let followup = try XCTUnwrap(report["followup"] as? [String: Any])
        XCTAssertEqual(followup["poolCount"] as? Int, 3)
        XCTAssertEqual(followup["poolIds"] as? [String], [
            "followup-pool-1", "followup-pool-2", "followup-pool-3"
        ])
        let manifest = try XCTUnwrap(report["candidateManifest"] as? [[String: Any]])
        for candidate in manifest where candidate["poolId"] != nil {
            XCTAssertTrue((candidate["poolId"] as? String)?.hasPrefix("followup-pool-") == true)
        }

        let followupPrimerPath = nativePrefix + "/primer.bed"
        XCTAssertTrue(nativePaths.contains(followupPrimerPath))
        let primerText = try String(contentsOf: bundle.artifactURL(forRelativePath: followupPrimerPath), encoding: .utf8)
        let pools = Set(primerText.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(separator: "\t")
            guard fields.count > 4, !line.hasPrefix("#") else { return nil }
            return String(fields[4])
        })
        XCTAssertFalse(pools.isEmpty, "The one-amplicon parent must leave a recoverable gap in this fixture.")
        XCTAssertTrue(pools.allSatisfy { (1...3).contains(Int($0) ?? 0) })

        let executionArtifact = try XCTUnwrap(bundle.manifest.artifacts.first { $0.role == "toolProvenance" })
        let executionData = try Data(contentsOf: bundle.artifactURL(forRelativePath: executionArtifact.relativePath))
        let execution = try ProvenanceEnvelopeReader.decodeCanonical(executionData)
        XCTAssertEqual(execution.exitStatus, 0)
        XCTAssertNotNil(execution.wallTimeSeconds)
        XCTAssertTrue(execution.argv.contains("--gap-completion-parent"))
        XCTAssertTrue(execution.files.contains { $0.path.contains("/\(destination.lastPathComponent)/") }, "files=\(execution.files)")
        XCTAssertTrue(execution.files.contains { $0.path.hasSuffix("/inputs/\(bundle.manifest.inputs[0].id.uuidString).fasta") })
        XCTAssertTrue(String(data: executionData, encoding: .utf8)?.contains(renamedInput.lastPathComponent) == true, "execution=\(String(data: executionData, encoding: .utf8) ?? "<non-UTF8>")")
        XCTAssertEqual(bundle.manifest.provenance.relativePath, "provenance/wrapper.json")
    }

    private static func inventory(_ root: URL) throws -> [String: String] {
        let manifest = try ProvenanceFileHasher.directoryManifest(for: root)
        return Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.checksumSHA256 ?? "") })
    }

    private static func jsonObject(_ bundle: PrimerAnalysisBundle, relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.artifactURL(forRelativePath: relativePath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
