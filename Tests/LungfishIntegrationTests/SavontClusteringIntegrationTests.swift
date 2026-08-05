import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class SavontClusteringIntegrationTests: XCTestCase {
    private static let inputEnvironmentVariable = "LUNGFISH_SAVONT_TEST_INPUT"
    private static let boundedReadCount = 1_000

    func testManagedSavontPublishesCountedClustersWithDurableProvenance() async throws {
        let sourceURL = try configuredSourceURL()
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SavontClusteringIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let subsetURL = temporaryRoot.appendingPathComponent("first-1000-reads.fastq")
        let materializedReadCount = try await materializeFirstReads(
            from: sourceURL,
            count: Self.boundedReadCount,
            to: subsetURL
        )
        XCTAssertEqual(materializedReadCount, Self.boundedReadCount)

        let scratchRootURL = temporaryRoot.appendingPathComponent("scratch", isDirectory: true)
        let outputURL = temporaryRoot.appendingPathComponent("first-1000-savont-clusters.fasta")
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: subsetURL,
            outputFASTAURL: outputURL
        )
        let managedCondaManager = try installedManagedCondaManager()
        let result = try await SavontClusteringPipeline(
            processRunner: ManagedSavontProcessRunner(
                condaManager: managedCondaManager
            ),
            scratchRootURL: scratchRootURL
        ).run(request)

        XCTAssertEqual(result.outputFASTAURL.standardizedFileURL, outputURL.standardizedFileURL)
        XCTAssertEqual(
            result.provenanceURL.standardizedFileURL,
            ProvenanceRecorder.fileSidecarURL(for: outputURL).standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))
        XCTAssertTrue(result.cleanupPendingURLs.isEmpty)
        XCTAssertGreaterThan(
            result.summary.clusterCount,
            0,
            "The 1,000-read fixture did not produce a nonempty cluster set; use the approved deterministic 10,000-read bound if this is a legitimate Savont result."
        )

        let headers = try String(contentsOf: outputURL, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.hasPrefix(">") }
            .map(String.init)
        XCTAssertEqual(headers.count, result.summary.clusterCount)
        let countedHeader = try NSRegularExpression(pattern: #"^>\S+_ReadCount-[0-9]+$"#)
        for header in headers {
            let range = NSRange(header.startIndex..<header.endIndex, in: header)
            XCTAssertNotNil(
                countedHeader.firstMatch(in: header, range: range),
                "Published Savont header is missing a terminal supporting-read count: \(header)"
            )
        }

        let independentlyNormalizedURL = temporaryRoot.appendingPathComponent("freshly-parsed.fasta")
        let freshSummary = try SavontClusterFASTA.normalize(
            sourceURL: outputURL,
            destinationURL: independentlyNormalizedURL
        )
        XCTAssertEqual(freshSummary, result.summary)

        let envelopeData = try Data(contentsOf: result.provenanceURL)
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: envelopeData)
        XCTAssertEqual(envelope.workflowName, "lungfish fastq savont-cluster")
        XCTAssertEqual(envelope.toolName, "savont")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertTrue(envelope.outputs.contains { $0.path == outputURL.path })
        XCTAssertTrue(
            envelope.files.contains {
                $0.role == .input && $0.path == subsetURL.path
                    && $0.checksumSHA256 != nil && $0.fileSize != nil
            },
            "Provenance does not contain the durable 1,000-read input snapshot."
        )

        let actualOutputDescriptor = try ProvenanceFileDescriptor.file(
            url: outputURL,
            format: .fasta,
            role: .output
        )
        XCTAssertEqual(envelope.output?.checksumSHA256, actualOutputDescriptor.checksumSHA256)
        XCTAssertEqual(envelope.output?.fileSize, actualOutputDescriptor.fileSize)
        XCTAssertTrue(envelope.steps.contains { $0.toolName == "savont" })
        XCTAssertTrue(
            envelope.steps
                .filter { $0.toolName == "savont" }
                .allSatisfy {
                    $0.runtimeIdentity?.condaEnvironment == SavontClusteringRunRequest.condaEnvironment
                        && $0.argv.contains("savont")
                        && $0.argv.contains("asv")
                        && $0.exitStatus != nil
                }
        )

        let scratchPaths = envelope.steps
            .flatMap { $0.inputs + $0.outputs }
            .map(\.path)
            .filter { $0.hasPrefix(scratchRootURL.path + "/") }
        XCTAssertFalse(scratchPaths.isEmpty, "Provenance did not record any run-owned scratch artifacts.")
        for path in scratchPaths {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: path),
                "Run-owned scratch artifact remains after successful publication: \(path)"
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: scratchRootURL.path),
            [],
            "Savont left a run workspace behind after successful publication."
        )
    }

    private func configuredSourceURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[Self.inputEnvironmentVariable],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip(
                "Set \(Self.inputEnvironmentVariable) to a FASTQ file or .lungfishfastq bundle to run this real-tool test."
            )
        }
        let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            XCTFail("Configured Savont test input does not exist: \(sourceURL.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return sourceURL
    }

    private func installedManagedCondaManager() throws -> CondaManager {
        let environment = ProcessInfo.processInfo.environment
        let condaRootURL: URL
        if let configuredPath = environment["LUNGFISH_CONDA_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty {
            condaRootURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
        } else if let homePath = environment["HOME"], !homePath.isEmpty {
            condaRootURL = URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent(".lungfish/conda", isDirectory: true)
        } else {
            condaRootURL = ManagedStorageConfigStore().currentCondaRootURL()
        }

        let standardizedRootURL = condaRootURL.standardizedFileURL
        let micromambaURL = standardizedRootURL.appendingPathComponent("bin/micromamba")
        let savontURL = standardizedRootURL.appendingPathComponent("envs/savont/bin/savont")
        guard FileManager.default.isExecutableFile(atPath: micromambaURL.path),
              FileManager.default.isExecutableFile(atPath: savontURL.path) else {
            throw XCTSkip(
                "Managed Savont is not installed under \(standardizedRootURL.path); install or repair the full-length MHC tool pack before running this integration test."
            )
        }
        // SwiftPM integration-test bundles do not contain the app's bundled micromamba
        // resource. Point the test manager at the already-installed managed binary so
        // `ensureMicromamba()` can perform its normal version and executable checks.
        return CondaManager(
            rootPrefix: standardizedRootURL,
            bundledMicromambaProvider: { micromambaURL },
            bundledMicromambaVersionProvider: { nil }
        )
    }

    private func materializeFirstReads(
        from sourceURL: URL,
        count: Int,
        to destinationURL: URL
    ) async throws -> Int {
        guard let primaryFASTQURL = FASTQBundle.resolvePrimaryFASTQURL(for: sourceURL) else {
            XCTFail("Configured Savont test input has no resolvable FASTQ payload: \(sourceURL.path)")
            throw CocoaError(.fileReadUnknown)
        }

        var records: [FASTQRecord] = []
        records.reserveCapacity(count)
        let reader = FASTQReader(validateSequence: false)
        for try await record in reader.records(from: primaryFASTQURL) {
            records.append(record)
            if records.count == count { break }
        }
        try FASTQWriter.write(records, to: destinationURL, encoding: .phred33)
        return records.count
    }
}
