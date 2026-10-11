// FASTQIngestionVersionEvidenceTests.swift - Where a FASTQ ingestion step's tool version comes from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6, lane P4. A step used to record a version from the lock when the probe failed, and
// nothing in the record said so. The version is now typed evidence, observed when a probe answered
// and a lock pin when it did not. The recorded string is the same either way. Each step also names
// its tool by the ManagedToolID of the lock entry.

import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class FASTQIngestionVersionEvidenceTests: XCTestCase {
    /// A probe that answers is observed, and the version is the one it printed.
    func testAnAnsweringProbeIsObserved() {
        let evidence = FASTQIngestionPipeline.versionEvidence(observed: "40.02", for: .clumpify)
        XCTAssertEqual(evidence, .observed(version: "40.02", reportedLine: nil))
        XCTAssertEqual(evidence.recordedString, "40.02")
    }

    /// A probe that does not answer leaves the lock's pin for the tool's own id, never a measurement.
    /// Every wrapper of BBTools shares `bbtools`, and bgzip and pigz have their own entries.
    func testAMissingProbeIsTheLockPinOfTheToolsId() {
        let cases: [(NativeTool, String)] = [
            (.clumpify, "bbtools"), (.reformat, "bbtools"), (.trimGalore, "trim_galore"),
            (.bgzip, "htslib"), (.pigz, "pigz"),
        ]
        for (tool, id) in cases {
            let evidence = FASTQIngestionPipeline.versionEvidence(observed: nil, for: tool)
            guard case .lockPin(let version, let toolID) = evidence else {
                XCTFail("\(tool) is not a lock pin: \(evidence)")
                continue
            }
            XCTAssertEqual(toolID.rawValue, id, "\(tool)")
            XCTAssertEqual(version, ManagedToolLock.bundled.entry(id: toolID)?.version, "\(tool)")
            XCTAssertEqual(evidence.recordedString, version, "\(tool) records the pinned version")
            XCTAssertNotEqual(evidence, .observed(version: version, reportedLine: nil), "\(tool) is a pin, not observed")
        }
    }

    /// With no probe and no pin there is no version, and the record keeps the word it always kept.
    func testNoProbeAndNoPinIsUnknown() {
        let emptyLock = ManagedToolLock(
            packID: "empty", displayName: "Empty", version: "0", tools: [], managedData: []
        )
        let evidence = FASTQIngestionPipeline.versionEvidence(observed: nil, for: .bgzip, lock: emptyLock)
        XCTAssertEqual(evidence, .unknown(.noProbe))
        XCTAssertEqual(evidence.recordedString, "unknown")
        XCTAssertNil(evidence.version)
    }

    // MARK: - The steps an ingestion records
    //
    // The pipeline builds a step at six places, and each import below reaches its own. A bbtools
    // import runs `clumpify.sh`, a Trim Galore import runs `trim_galore` and then `reformat.sh` to
    // interleave its pair, binning without clumping runs `reformat.sh`, and an import with neither
    // runs the compressor, which a paired import reaches through the Swift interleaver and a
    // single-end import through a plain compress.

    private let r1Text = "@pair1/1\nACGTACGTACGTACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII\n"
        + "@pair2/1\nGGCCTTAAGGCCTTAAGGCCTTAAGGCCTTAA\n+\nIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII\n"
    private let r2Text = "@pair1/2\nTGCATGCATGCATGCATGCATGCATGCATGCA\n+\nIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII\n"
        + "@pair2/2\nTTAAGGCCTTAAGGCCTTAAGGCCTTAAGGCC\n+\nIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII\n"

    private func ingest(
        clumpingTool: ClumpingTool, qualityBinning: QualityBinningScheme,
        pairing: FASTQIngestionConfig.PairingMode = .pairedEnd
    ) async throws -> FASTQIngestionResult {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("FASTQIngestionVersionEvidence \(UUID().uuidString)", isDirectory: true)
        let importsDir = root.appendingPathComponent("Imports", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try fm.createDirectory(at: importsDir, withIntermediateDirectories: true)
        let r1 = root.appendingPathComponent("Sample_R1.fastq")
        try r1Text.write(to: r1, atomically: true, encoding: .utf8)
        var inputs = [r1]
        if pairing == .pairedEnd {
            let r2 = root.appendingPathComponent("Sample_R2.fastq")
            try r2Text.write(to: r2, atomically: true, encoding: .utf8)
            inputs.append(r2)
        }
        return try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: inputs, pairingMode: pairing, outputDirectory: importsDir, threads: 1,
                deleteOriginals: false, qualityBinning: qualityBinning, clumpingTool: clumpingTool
            ),
            progress: { _, _ in }
        )
    }

    /// Every step an ingestion records names its tool by the lock entry's id and carries the evidence
    /// behind its version. The evidence agrees with the version string the step records.
    private func assertEveryStepCarriesItsToolIdAndEvidence(
        _ steps: [StepExecution], expecting names: Set<String>, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(Set(steps.map(\.toolName)), names, file: file, line: line)
        for step in steps {
            let tool = try XCTUnwrap(
                NativeTool.allCases.first { $0.executableName == step.toolName }, step.toolName, file: file, line: line
            )
            XCTAssertEqual(step.managedToolID, tool.managedToolID, step.toolName, file: file, line: line)
            let evidence = try XCTUnwrap(step.toolVersionEvidence, step.toolName, file: file, line: line)
            XCTAssertEqual(evidence.recordedString, step.toolVersion, step.toolName, file: file, line: line)
            // The probe answered on this machine, so the version was observed. A missing probe would
            // leave the lock pin of the same id, and either way the value is the same string.
            switch evidence {
            case .observed(let version, _):
                XCTAssertFalse(version.isEmpty, step.toolName, file: file, line: line)
            case .lockPin(_, let id):
                XCTAssertEqual(id, tool.managedToolID, step.toolName, file: file, line: line)
            case .sourceBuild, .unknown:
                XCTFail("\(step.toolName) carries \(evidence)", file: file, line: line)
            }
        }
    }

    func testAPairedImportWithoutClumpingRecordsItsCompressorWithEvidence() async throws {
        let runner = NativeToolRunner.shared
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else { try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available") }
        let result = try await ingest(clumpingTool: .none, qualityBinning: .none)
        let compressor = Set(result.provenanceSteps.map(\.toolName))
        XCTAssertEqual(compressor.count, 1, "\(compressor)")
        try assertEveryStepCarriesItsToolIdAndEvidence(result.provenanceSteps, expecting: compressor)
        XCTAssertTrue(compressor.isSubset(of: ["bgzip", "pigz"]), "\(compressor)")
    }

    func testASingleEndImportRecordsItsCompressorWithEvidence() async throws {
        let runner = NativeToolRunner.shared
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else { try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available") }
        let result = try await ingest(clumpingTool: .none, qualityBinning: .none, pairing: .singleEnd)
        let compressor = Set(result.provenanceSteps.map(\.toolName))
        XCTAssertEqual(compressor.count, 1, "\(compressor)")
        XCTAssertTrue(compressor.isSubset(of: ["bgzip", "pigz"]), "\(compressor)")
        try assertEveryStepCarriesItsToolIdAndEvidence(result.provenanceSteps, expecting: compressor)
    }

    func testABinningImportWithoutClumpingRecordsReformatWithEvidence() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .reformat)) != nil else {
            try ToolAvailability.skipOrFail("Managed reformat.sh is not available")
        }
        let result = try await ingest(clumpingTool: .none, qualityBinning: .illumina4)
        try assertEveryStepCarriesItsToolIdAndEvidence(result.provenanceSteps, expecting: ["reformat.sh"])
        XCTAssertEqual(result.provenanceSteps.first?.managedToolID, ManagedToolID(rawValue: "bbtools"))
    }

    func testATrimGaloreImportRecordsTrimGaloreAndItsInterleaveWithEvidence() async throws {
        let runner = NativeToolRunner.shared
        guard (try? await runner.toolPath(for: .trimGalore)) != nil,
              (try? await runner.toolPath(for: .reformat)) != nil else {
            try ToolAvailability.skipOrFail("Managed trim_galore or reformat.sh is not available")
        }
        let result = try await ingest(clumpingTool: .trimGalore, qualityBinning: .none)
        try assertEveryStepCarriesItsToolIdAndEvidence(
            result.provenanceSteps, expecting: ["trim_galore", "reformat.sh"]
        )
        let ids = Dictionary(uniqueKeysWithValues: result.provenanceSteps.map { ($0.toolName, $0.managedToolID) })
        XCTAssertEqual(ids["trim_galore"], ManagedToolID(rawValue: "trim_galore"))
        XCTAssertEqual(ids["reformat.sh"], ManagedToolID(rawValue: "bbtools"))
    }

    func testAClumpifyImportRecordsItsBBToolsStepsWithEvidence() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .clumpify)) != nil else {
            try ToolAvailability.skipOrFail("Managed clumpify is not available")
        }
        let result = try await ingest(clumpingTool: .bbtools, qualityBinning: .illumina4)
        let names = Set(result.provenanceSteps.map(\.toolName))
        XCTAssertTrue(names.contains("clumpify.sh"), "\(names)")
        try assertEveryStepCarriesItsToolIdAndEvidence(result.provenanceSteps, expecting: names)
        let bbtools = ManagedToolID(rawValue: "bbtools")
        for step in result.provenanceSteps where step.toolName == "clumpify.sh" {
            XCTAssertEqual(step.managedToolID, bbtools)
        }
    }
}
