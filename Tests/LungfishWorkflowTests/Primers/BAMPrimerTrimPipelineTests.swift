import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class BAMPrimerTrimPipelineTests: XCTestCase {
    func testBuildIvarTrimArgvIncludesAllExpectedFlags() throws {
        let argv = BAMPrimerTrimPipeline.buildIvarTrimArgv(
            bedPath: "/tmp/primers.bed",
            inputBAMPath: "/tmp/input.bam",
            outputPrefix: "/tmp/output",
            minReadLength: 30,
            minQuality: 20,
            slidingWindow: 4,
            primerOffset: 0
        )

        XCTAssertEqual(argv, [
            "trim",
            "-b", "/tmp/primers.bed",
            "-i", "/tmp/input.bam",
            "-p", "/tmp/output",
            "-q", "20",
            "-m", "30",
            "-s", "4",
            "-x", "0",
            "-e"
        ])
    }

    func testEndToEndPipelineAgainstSarsCov2Fixture() async throws {
        // This test validates orchestration: argv shape, tool dispatch, success/failure
        // handling, and sidecar serialization. It does NOT validate primer-trim
        // correctness — that's iVar's contract. Strengthening the assertions (e.g.,
        // exact read-count deltas) would couple the test to the synthetic primer
        // coordinates and fixture BAM content, making it flaky on fixture changes.
        let runner = NativeToolRunner()

        // Load the integration primer scheme bundle (canonical = MT192765.1,
        // which matches the sarscov2 fixture BAM's @SQ SN).
        let primerBundleURL = try XCTUnwrap(Bundle.module.url(
            forResource: "primerschemes/mt192765-integration.lungfishprimers",
            withExtension: nil
        ))
        let primerBundle = try PrimerSchemeBundle.load(from: primerBundleURL)

        // Locate the sarscov2 BAM fixture (relative to the repo root).
        // Walk up from #filePath to find Tests/Fixtures/sarscov2/test.paired_end.sorted.bam.
        // Using #filePath (not #file) because SwiftPM's #file is a concise, package-relative
        // form that drops the absolute prefix we need for file-system lookup.
        let sourceBAMURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Primers/
            .deletingLastPathComponent()  // LungfishWorkflowTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")

        guard FileManager.default.fileExists(atPath: sourceBAMURL.path) else {
            throw XCTSkip("sarscov2 test BAM fixture not found at \(sourceBAMURL.path)")
        }

        // Create a temp output dir scoped to this test run.
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMPrimerTrimPipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: outputDir)
        }

        let outputBAMURL = outputDir.appendingPathComponent("trimmed.bam")

        let request = BAMPrimerTrimRequest(
            sourceBAMURL: sourceBAMURL,
            primerSchemeBundle: primerBundle,
            outputBAMURL: outputBAMURL
        )

        let result: BAMPrimerTrimResult
        do {
            result = try await BAMPrimerTrimPipeline.run(
                request,
                targetReferenceName: "MT192765.1",
                runner: runner
            )
        } catch let err as NativeToolError {
            // If ivar or samtools is not findable by NativeToolRunner, skip
            // rather than fail. NativeToolRunner throws toolNotFound /
            // toolsDirectoryNotFound when a managed tool is missing from
            // ~/.lungfish.
            switch err {
            case .toolNotFound, .toolsDirectoryNotFound:
                throw XCTSkip(
                    "ivar/samtools not installed in ~/.lungfish; skipping integration test. \(err)"
                )
            default:
                throw err
            }
        }

        // Assert outputs exist on disk.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.outputBAMURL.path),
            "Output BAM missing at \(result.outputBAMURL.path)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.outputBAMIndexURL.path),
            "Output BAI missing at \(result.outputBAMIndexURL.path)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.provenanceURL.path),
            "Provenance sidecar missing at \(result.provenanceURL.path)"
        )

        // Verify intermediate cleanup (the defer in `run` must remove this).
        let unsortedBAM = outputDir.appendingPathComponent("trimmed.unsorted.bam")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unsortedBAM.path),
            "Intermediate unsorted BAM should have been cleaned up"
        )

        // Assert in-memory provenance content matches expectations.
        XCTAssertEqual(result.provenance.operation, "primer-trim")
        XCTAssertEqual(result.provenance.primerScheme.bundleName, "mt192765-integration")
        XCTAssertEqual(result.provenance.primerScheme.canonicalAccession, "MT192765.1")
        XCTAssertEqual(result.provenance.sourceBAMRelativePath, "test.paired_end.sorted.bam")
        XCTAssertTrue(result.provenance.ivarTrimArgs.contains("trim"))
        XCTAssertEqual(result.provenance.schemaVersion, 2)
        XCTAssertEqual(result.provenance.workflowName, "lungfish bam primer-trim")
        XCTAssertFalse(result.provenance.workflowVersion.isEmpty)
        XCTAssertEqual(result.provenance.resolvedOptions["ivar_min_quality"], "20")
        XCTAssertEqual(result.provenance.resolvedOptions["ivar_min_length"], "30")
        XCTAssertEqual(result.provenance.resolvedOptions["ivar_sliding_window"], "4")
        XCTAssertEqual(result.provenance.resolvedOptions["ivar_primer_offset"], "0")
        XCTAssertEqual(result.provenance.resolvedOptions["target_reference"], "MT192765.1")
        XCTAssertEqual(result.provenance.exitStatus, 0)
        XCTAssertNotNil(result.provenance.wallTimeSeconds)
        XCTAssertGreaterThan(result.provenance.steps.count, 2)
        XCTAssertEqual(result.provenance.steps.map(\.toolName), ["ivar", "samtools", "samtools"])
        XCTAssertTrue(result.provenance.steps.allSatisfy { !$0.command.isEmpty })
        XCTAssertTrue(result.provenance.steps.allSatisfy { $0.exitCode == 0 })
        XCTAssertTrue(result.provenance.steps.allSatisfy { $0.wallTime != nil })
        XCTAssertTrue(result.provenance.steps.allSatisfy { $0.endTime != nil })
        XCTAssertTrue(result.provenance.inputFiles.contains { $0.path == sourceBAMURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(result.provenance.outputFiles.contains { $0.path == result.outputBAMURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(result.provenance.outputFiles.contains { $0.path == result.outputBAMIndexURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(result.provenance.runtimeIdentity.keys.contains("ivar"))
        XCTAssertTrue(result.provenance.runtimeIdentity.keys.contains("samtools"))

        // Round-trip the provenance JSON to confirm on-disk serialization
        // matches the struct returned from the pipeline. ISO-8601 encoding
        // truncates Date to second precision, so compare timestamps with a
        // one-second tolerance and the other (lossless) fields exactly.
        let onDiskData = try Data(contentsOf: result.provenanceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedProvenance = try decoder.decode(BAMPrimerTrimProvenance.self, from: onDiskData)
        XCTAssertEqual(decodedProvenance.operation, result.provenance.operation)
        XCTAssertEqual(decodedProvenance.primerScheme, result.provenance.primerScheme)
        XCTAssertEqual(decodedProvenance.sourceBAMRelativePath, result.provenance.sourceBAMRelativePath)
        XCTAssertEqual(decodedProvenance.ivarVersion, result.provenance.ivarVersion)
        XCTAssertEqual(decodedProvenance.ivarTrimArgs, result.provenance.ivarTrimArgs)
        XCTAssertEqual(decodedProvenance.schemaVersion, result.provenance.schemaVersion)
        XCTAssertEqual(decodedProvenance.workflowName, result.provenance.workflowName)
        XCTAssertEqual(decodedProvenance.resolvedOptions, result.provenance.resolvedOptions)
        XCTAssertEqual(decodedProvenance.inputFiles, result.provenance.inputFiles)
        XCTAssertEqual(decodedProvenance.outputFiles, result.provenance.outputFiles)
        XCTAssertEqual(decodedProvenance.runtimeIdentity, result.provenance.runtimeIdentity)
        XCTAssertEqual(decodedProvenance.steps.map(\.toolName), result.provenance.steps.map(\.toolName))
        XCTAssertEqual(
            decodedProvenance.timestamp.timeIntervalSince1970,
            result.provenance.timestamp.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testPipelineRemovesBAMAndIndexWhenProvenanceWriteFails() async throws {
        let runner = NativeToolRunner()
        let primerBundleURL = try XCTUnwrap(Bundle.module.url(
            forResource: "primerschemes/mt192765-integration.lungfishprimers",
            withExtension: nil
        ))
        let primerBundle = try PrimerSchemeBundle.load(from: primerBundleURL)
        let sourceBAMURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")

        guard FileManager.default.fileExists(atPath: sourceBAMURL.path) else {
            throw XCTSkip("sarscov2 test BAM fixture not found at \(sourceBAMURL.path)")
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMPrimerTrimPipelineRollbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: outputDir)
        }

        let outputBAMURL = outputDir.appendingPathComponent("trimmed.bam")
        let outputBAIURL = URL(fileURLWithPath: outputBAMURL.path + ".bai")
        let provenanceURL = PrimerTrimProvenanceLoader.sidecarURL(forBAMAt: outputBAMURL)
        try FileManager.default.createDirectory(at: provenanceURL, withIntermediateDirectories: true)
        let request = BAMPrimerTrimRequest(
            sourceBAMURL: sourceBAMURL,
            primerSchemeBundle: primerBundle,
            outputBAMURL: outputBAMURL
        )

        do {
            _ = try await BAMPrimerTrimPipeline.run(
                request,
                targetReferenceName: "MT192765.1",
                runner: runner
            )
            XCTFail("Expected provenance sidecar write to fail")
        } catch let err as NativeToolError {
            switch err {
            case .toolNotFound, .toolsDirectoryNotFound:
                throw XCTSkip(
                    "ivar/samtools not installed in ~/.lungfish; skipping integration test. \(err)"
                )
            default:
                throw err
            }
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputBAMURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputBAIURL.path))
        }
    }
}
