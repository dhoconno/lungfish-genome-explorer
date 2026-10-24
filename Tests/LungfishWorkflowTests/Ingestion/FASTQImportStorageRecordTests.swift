// FASTQImportStorageRecordTests.swift - The Mac import records its stored gzip's writer, level and groups (C4-10)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// C4-10 (tally-r2 N3, ARCH N3 conditions 2 and 3, XC-4 B). A Mac import runs BBTools' writer probe right before each
/// BBTools launch that writes the stored gzip and records on that launch's step which program wrote the gzip, the
/// level that took effect and clumpify's group count and memory lines, under the key names the node's record uses.
/// A mixed file's two `clumpify.sh` halves write plain FASTQ, so they run no probe and state their own groups.
final class FASTQImportStorageRecordTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestTempDirectory.make(prefix: "import-storage-record")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(tempDir)
    }

    // MARK: - The import's record

    func testImportRecordNamesBBToolsWriterAndEffectiveLevel() async throws {
        _ = try await ToolAvailability.require("clumpify.sh", environment: "bbtools")

        let clumped = try await importedSteps(
            label: "clumpify", clumpingTool: .bbtools, qualityBinning: .illumina4, level: .maximum
        )
        let clumpify = try XCTUnwrap(clumped.first { $0.toolName == "clumpify.sh" }, "\(clumped.map(\.toolName))")
        try assertBgzipWriter(of: clumpify, level: 4)
        XCTAssertEqual(
            clumpify.resolvedOptions["effectiveCompressionLevel"], .integer(4),
            "clumpify.sh compresses at zl=4 whatever level the import chose"
        )
        let groups = try XCTUnwrap(Self.integer(clumpify.resolvedOptions["clumpifyGroups"]), "\(clumpify.resolvedOptions)")
        XCTAssertGreaterThanOrEqual(groups, 1)
        XCTAssertTrue(
            Self.string(clumpify.resolvedOptions["clumpifyMemoryEstimateLine"])?.hasPrefix("Memory Estimate:") == true,
            "\(clumpify.resolvedOptions)"
        )
        XCTAssertTrue(
            Self.string(clumpify.resolvedOptions["clumpifyMemoryAvailableLine"])?.hasPrefix("Memory Available:") == true,
            "\(clumpify.resolvedOptions)"
        )

        let binned = try await importedSteps(
            label: "reformat", clumpingTool: ClumpingTool.none, qualityBinning: .illumina4, level: .maximum
        )
        let reformat = try XCTUnwrap(
            binned.first { $0.toolName == "reformat.sh" && $0.argv.contains("zl=9") }, "\(binned.map(\.argv))"
        )
        try assertBgzipWriter(of: reformat, level: 9)
        XCTAssertEqual(reformat.resolvedOptions["effectiveCompressionLevel"], .integer(9), "the user's level")
        XCTAssertNil(reformat.resolvedOptions["clumpifyGroups"], "groups are clumpify's alone")
    }

    /// A mixed file's `clumpify.sh` halves write plain FASTQ that a compress step then writes, so each half states
    /// its own groups and no writer, and the compress step is its own writer (ARCH N3 condition 2).
    func testAMixedImportRecordsEachHalfsGroupsAndTheCompressStepAsWriter() async throws {
        _ = try await ToolAvailability.require("fastp", environment: "fastp")
        _ = try await ToolAvailability.require("clumpify.sh", environment: "bbtools")
        let recipe = Recipe(
            id: "merge-keep-unmerged", name: "Merge and keep the unmerged pairs", requiredInput: .paired,
            steps: [RecipeStep(type: "fastp-merge", label: nil, params: ["keepUnmerged": .bool(true)])]
        )

        let steps = try await importedSteps(
            label: "mixed", recipe: recipe, clumpingTool: .bbtools, qualityBinning: QualityBinningScheme.none,
            level: .balanced
        )

        let halves = steps.filter { $0.toolName == "clumpify.sh" }
        XCTAssertEqual(halves.count, 2, "\(steps.map(\.toolName))")
        for half in halves {
            XCTAssertNil(half.resolvedOptions["writer"], "a half writes no stored gzip and runs no probe")
            XCTAssertNil(half.resolvedOptions["effectiveCompressionLevel"])
            XCTAssertNotNil(Self.integer(half.resolvedOptions["clumpifyGroups"]), "\(half.resolvedOptions)")
        }
        let compress = try XCTUnwrap(
            steps.first { $0.toolName == "bgzip" || $0.toolName == "pigz" }, "\(steps.map(\.toolName))"
        )
        XCTAssertEqual(compress.resolvedOptions["writer"], .dictionary(["name": .string(compress.toolName)]))
        XCTAssertNil(compress.resolvedOptions["effectiveCompressionLevel"], "a compress step passes no level")
    }

    // MARK: - The parsers and the record values

    func testClumpifyLogReadsTheLastGroupsAndBothMemoryLines() {
        let log = PortableClumpifyLog("""
            Clumpify version 40.02
            Memory Estimate:        11 MB
            Memory Available:       2867 MB
            Set groups to 1
            Set groups to 3
            Reads In:               28
            """)
        XCTAssertEqual(
            log,
            PortableClumpifyLog(
                groups: 3, memoryEstimate: "Memory Estimate:        11 MB",
                memoryAvailable: "Memory Available:       2867 MB"
            )
        )
        XCTAssertEqual(PortableClumpifyLog("Reads In: 28\nSet groups to many"), PortableClumpifyLog())
    }

    func testBgzipVersionAndTheArgvLevelAreReadAsPrinted() {
        typealias Step = PortableStorageStep<NativeToolStorageLauncher>
        XCTAssertEqual(Step.bgzipVersion(fromHelp: "\nVersion: 1.21\nUsage:   bgzip [OPTIONS] [FILE] ..."), "1.21")
        XCTAssertNil(Step.bgzipVersion(fromHelp: "Usage:   bgzip [OPTIONS] [FILE]"))
        XCTAssertNil(Step.bgzipVersion(fromHelp: "Version:   \nUsage: bgzip"))
        XCTAssertEqual(Step.compressionLevel(of: ["in=a.fq", "zl=1", "out=b.fq.gz", "zl=4"]), 4)
        XCTAssertNil(Step.compressionLevel(of: ["in=a.fq", "out=b.fq"]))
    }

    func testTheRecordValuesNameTheWriterInTheNodesToolForm() throws {
        let bgzip = URL(fileURLWithPath: "/env/bin/bgzip")
        let probe = PortableBBToolsWriterProbe(
            writer: .bgzip(executable: bgzip, arguments: ["-c", "-f", "-l", "4", "-@", "2"]),
            effectiveCompressionLevel: 4, version: "1.21"
        )
        let options = try XCTUnwrap(FASTQIngestionPipeline.storageResolvedOptions(
            writerProbe: probe, clumpifyLog: PortableClumpifyLog(groups: 2)
        ))
        XCTAssertEqual(options, [
            "writer": .dictionary([
                "name": .string("bgzip"),
                "tool": .dictionary([
                    "id": .string("bgzip"), "version": .string("1.21"), "build": .string(""),
                    "path": .string("/env/bin/bgzip"), "versionSource": .string("observed"),
                ]),
                "arguments": .array(["-c", "-f", "-l", "4", "-@", "2"].map(ParameterValue.string)),
            ]),
            "effectiveCompressionLevel": .integer(4),
            "clumpifyGroups": .integer(2),
        ])

        let silent = PortableBBToolsWriterProbe(
            writer: .bgzip(executable: bgzip, arguments: []), effectiveCompressionLevel: 9
        )
        guard case .dictionary(let writer) = FASTQIngestionPipeline.writerValue(silent),
              case .dictionary(let tool)? = writer["tool"] else {
            return XCTFail("a bgzip writer carries its tool")
        }
        XCTAssertEqual(tool["version"], .string(""), "a bgzip that states no version records none (XC-4 B)")
        XCTAssertEqual(tool["versionSource"], .string("unknown"))

        let native = PortableBBToolsWriterProbe(writer: .nativeBGZF, effectiveCompressionLevel: 1)
        XCTAssertEqual(
            FASTQIngestionPipeline.storageResolvedOptions(writerProbe: native),
            ["writer": .dictionary(["name": .string("BBTools native BGZF")]), "effectiveCompressionLevel": .integer(1)]
        )
        XCTAssertNil(FASTQIngestionPipeline.storageResolvedOptions(), "a launch with nothing to state adds no key")
    }

    func testImportConfigTakesTheChosenLevel() {
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: tempDir, platform: .illumina, compressionLevel: .fast
        )
        XCTAssertEqual(config.compressionLevel, .fast)
    }

    // MARK: - Helpers

    /// Imports eight pairs that stay apart and six that overlap and returns the steps of the bundle's record.
    private func importedSteps(
        label: String, recipe: Recipe? = nil, clumpingTool: ClumpingTool, qualityBinning: QualityBinningScheme,
        level: CompressionLevel
    ) async throws -> [ProvenanceStep] {
        let input = tempDir.appendingPathComponent("\(label)-input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let r1 = input.appendingPathComponent("s_R1.fastq")
        let r2 = input.appendingPathComponent("s_R2.fastq")
        try MixedStorageFASTQ.writeReadPairs(r1: r1, r2: r2, apart: 8, overlapping: 6)
        let project = tempDir.appendingPathComponent("\(label).lungfish", isDirectory: true)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: project, platform: .illumina, newRecipe: recipe, qualityBinning: qualityBinning,
            optimizeStorage: clumpingTool.isClumpingEnabled, clumpingTool: clumpingTool, compressionLevel: level,
            threads: 2
        )

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: "s", r1: r1, r2: r2)], config: config
        )

        XCTAssertEqual(result.completed, 1, "\(result.errors)")
        let record = project.appendingPathComponent("Imports/s.lungfishfastq/\(ProvenanceRecorder.provenanceFilename)")
        let data = PortablePath.resolveJSON(try Data(contentsOf: record), forFileAt: record)
        return try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data).steps
    }

    /// The step names the `bgzip` BBTools started, in the node's tool form, with the level of its argv.
    private func assertBgzipWriter(
        of step: ProvenanceStep, level: Int, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        guard case .dictionary(let writer)? = step.resolvedOptions["writer"],
              case .dictionary(let tool)? = writer["tool"] else {
            return XCTFail("\(step.toolName) names no bgzip writer: \(step.resolvedOptions)", file: file, line: line)
        }
        XCTAssertEqual(writer["name"], .string("bgzip"), file: file, line: line)
        XCTAssertEqual(tool["id"], .string("bgzip"), file: file, line: line)
        let path = try XCTUnwrap(Self.string(tool["path"]), file: file, line: line)
        XCTAssertTrue(path.hasSuffix("/bgzip"), path, file: file, line: line)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), path, file: file, line: line)
        XCTAssertFalse(Self.string(tool["version"])?.isEmpty ?? true, "\(tool)", file: file, line: line)
        XCTAssertEqual(tool["versionSource"], .string("observed"), file: file, line: line)
        XCTAssertEqual(
            writer["arguments"], .array(["-c", "-f", "-l", "\(level)", "-@", "2"].map(ParameterValue.string)),
            file: file, line: line
        )
    }

    private static func string(_ value: ParameterValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }

    private static func integer(_ value: ParameterValue?) -> Int? {
        if case .integer(let number)? = value { return number }
        return nil
    }
}
