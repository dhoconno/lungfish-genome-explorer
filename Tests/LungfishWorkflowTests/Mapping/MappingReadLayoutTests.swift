// MappingReadLayoutTests.swift - Per-mapper argv for every FASTQ input layout, and the recorded plan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The expected flags were verified against the installed tools (bwa-mem2
// 2.2.1, bowtie2 2.5.5, minimap2 2.31, BBMap 40.02) on synthetic files with
// identical-name, /1 /2, and Casava mates, a mixed file, and a single-end
// file; see MappingTool+ReadLayout.swift for the observed SAM flags.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class MappingReadLayoutTests: XCTestCase {

    private let interleaved = URL(fileURLWithPath: "/tmp/sample.lungfishfastq/sample.fastq.gz")
    private let r1 = URL(fileURLWithPath: "/tmp/reads_R1.fastq.gz")
    private let r2 = URL(fileURLWithPath: "/tmp/reads_R2.fastq.gz")
    private let reference = URL(fileURLWithPath: "/tmp/reference.fa")
    private let output = URL(fileURLWithPath: "/tmp/mapping-output")

    private func request(
        tool: MappingTool,
        layout: FASTQInputLayout?,
        modeID: String? = nil
    ) -> MappingRunRequest {
        let inputs: [URL] = layout == .pairedFiles ? [r1, r2] : [interleaved]
        return MappingRunRequest(
            tool: tool,
            modeID: modeID ?? (tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id),
            inputFASTQURLs: inputs,
            referenceFASTAURL: reference,
            outputDirectory: output,
            sampleName: "sample",
            pairedEnd: layout == .pairedFiles,
            threads: 4,
            inputLayout: layout
        )
    }

    private func argv(_ request: MappingRunRequest) throws -> [String] {
        try MappingCommandBuilder.buildCommand(
            for: request,
            referenceLocator: ReferenceLocator(
                referenceURL: reference,
                indexPrefixURL: output.appendingPathComponent("reference-index")
            )
        ).arguments
    }

    // MARK: - Declarations

    func testEveryMapperDeclaresEveryLayout() {
        for tool in MappingTool.allCases {
            XCTAssertTrue(tool.fastqConsumerDeclaration.undeclaredLayouts.isEmpty, tool.rawValue)
            XCTAssertTrue(tool.fastqConsumerDeclaration.consumerID.hasPrefix("map."), tool.rawValue)
        }
    }

    func testDeclaredHandlingMatchesVerifiedToolBehaviour() {
        let expected: [MappingTool: [FASTQInputLayout: FASTQReadLayoutHandling]] = [
            .minimap2: [.singleEnd: .asSingle, .strictlyInterleaved: .asPairs, .mixedMergedAndPairs: .asPairs, .pairedFiles: .asPairs],
            .bwaMem2: [.singleEnd: .asSingle, .strictlyInterleaved: .asPairs, .mixedMergedAndPairs: .asPairs, .pairedFiles: .asPairs],
            .bowtie2: [.singleEnd: .asSingle, .strictlyInterleaved: .asPairs, .mixedMergedAndPairs: .asSingle, .pairedFiles: .asPairs],
            .bbmap: [.singleEnd: .asSingle, .strictlyInterleaved: .asPairs, .mixedMergedAndPairs: .asSingle, .pairedFiles: .asPairs],
        ]
        for (tool, handling) in expected {
            XCTAssertEqual(tool.fastqConsumerDeclaration.handling, handling, tool.rawValue)
            XCTAssertTrue(tool.fastqConsumerDeclaration.mixedHandlingIsGraceful, tool.rawValue)
        }
    }

    // MARK: - bwa-mem2

    func testBwaMem2SmartPairsInterleavedAndMixedInput() throws {
        for layout in [FASTQInputLayout.strictlyInterleaved, .mixedMergedAndPairs] {
            let arguments = try argv(request(tool: .bwaMem2, layout: layout))
            XCTAssertTrue(arguments.contains("-p"), "\(layout)")
            XCTAssertEqual(arguments.suffix(2).map { $0 }, [output.appendingPathComponent("reference-index").path, interleaved.path])
            let pIndex = try XCTUnwrap(arguments.firstIndex(of: "-p"))
            XCTAssertLessThan(pIndex, arguments.count - 2, "-p must precede the index prefix")
        }
    }

    func testBwaMem2MapsSingleEndAndPairedFilesWithoutSmartPairing() throws {
        XCTAssertFalse(try argv(request(tool: .bwaMem2, layout: .singleEnd)).contains("-p"))
        let paired = try argv(request(tool: .bwaMem2, layout: .pairedFiles))
        XCTAssertFalse(paired.contains("-p"))
        XCTAssertEqual(paired.suffix(2).map { $0 }, [r1.path, r2.path])
    }

    func testBwaMem2WithoutResolvedLayoutKeepsTheLegacySingleEndCommand() throws {
        XCTAssertFalse(try argv(request(tool: .bwaMem2, layout: nil)).contains("-p"))
    }

    // MARK: - bowtie2

    func testBowtie2InterleavesOnlyStrictlyInterleavedInput() throws {
        let strict = try argv(request(tool: .bowtie2, layout: .strictlyInterleaved))
        XCTAssertEqual(strict.suffix(2).map { $0 }, ["--interleaved", interleaved.path])
        XCTAssertFalse(strict.contains("-U"))

        for layout in [FASTQInputLayout.mixedMergedAndPairs, .singleEnd] {
            let arguments = try argv(request(tool: .bowtie2, layout: layout))
            XCTAssertEqual(arguments.suffix(2).map { $0 }, ["-U", interleaved.path], "\(layout)")
            XCTAssertFalse(arguments.contains("--interleaved"), "\(layout)")
        }

        let paired = try argv(request(tool: .bowtie2, layout: .pairedFiles))
        XCTAssertEqual(paired.suffix(4).map { $0 }, ["-1", r1.path, "-2", r2.path])
    }

    // MARK: - BBMap

    func testBBMapStatesTheInterleaveFlagFromTheResolvedLayout() throws {
        XCTAssertTrue(try argv(request(tool: .bbmap, layout: .strictlyInterleaved)).contains("interleaved=t"))
        for layout in [FASTQInputLayout.mixedMergedAndPairs, .singleEnd] {
            let arguments = try argv(request(tool: .bbmap, layout: layout))
            XCTAssertTrue(arguments.contains("interleaved=f"), "\(layout)")
            XCTAssertTrue(arguments.contains("in=\(interleaved.path)"), "\(layout)")
        }
        let paired = try argv(request(tool: .bbmap, layout: .pairedFiles))
        XCTAssertTrue(paired.contains("in=\(r1.path)"))
        XCTAssertTrue(paired.contains("in2=\(r2.path)"))
        XCTAssertFalse(paired.contains { $0.hasPrefix("interleaved=") })
    }

    // MARK: - minimap2

    func testMinimap2NeedsNoFlagAndPairsOnlyInShortReadMode() throws {
        for layout in FASTQInputLayout.allCases {
            let arguments = try argv(request(tool: .minimap2, layout: layout))
            XCTAssertFalse(arguments.contains { $0.contains("interleaved") || $0 == "-p" }, "\(layout)")
        }
        XCTAssertEqual(request(tool: .minimap2, layout: .strictlyInterleaved).readLayoutPlan.handling, .asPairs)
        XCTAssertEqual(request(tool: .minimap2, layout: .mixedMergedAndPairs).readLayoutPlan.handling, .asPairs)
        XCTAssertEqual(
            request(tool: .minimap2, layout: .strictlyInterleaved, modeID: MappingMode.minimap2MapONT.id).readLayoutPlan.handling,
            .asSingle
        )
        XCTAssertEqual(
            request(tool: .minimap2, layout: .pairedFiles, modeID: MappingMode.minimap2MapONT.id).readLayoutPlan.handling,
            .asPairs
        )
    }

    // MARK: - Plan and request

    func testEffectiveLayoutFallsBackToThePairedEndFlag() {
        XCTAssertEqual(request(tool: .bowtie2, layout: nil).effectiveInputLayout, .singleEnd)
        let paired = MappingRunRequest(
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [r1, r2],
            referenceFASTAURL: reference,
            outputDirectory: output,
            sampleName: "sample",
            pairedEnd: true,
            threads: 2
        )
        XCTAssertEqual(paired.effectiveInputLayout, .pairedFiles)
        XCTAssertEqual(paired.withInputLayout(.singleEnd).effectiveInputLayout, .singleEnd)
        XCTAssertEqual(paired.withInputFASTQURLs([r1]).inputLayout, nil)
    }

    func testPairedEndDescriptionsPerPlan() {
        XCTAssertEqual(MappingReadLayoutPlan(layout: .pairedFiles, handling: .asPairs).pairedEndDescription, "Yes")
        XCTAssertEqual(MappingReadLayoutPlan(layout: .strictlyInterleaved, handling: .asPairs).pairedEndDescription, "Yes (interleaved)")
        XCTAssertEqual(
            MappingReadLayoutPlan(layout: .mixedMergedAndPairs, handling: .asPairs).pairedEndDescription,
            "Yes (interleaved; merged reads mapped as single reads)"
        )
        XCTAssertEqual(
            MappingReadLayoutPlan(layout: .mixedMergedAndPairs, handling: .asSingle).pairedEndDescription,
            "No (mixed merged reads and pairs mapped as single-end)"
        )
        XCTAssertEqual(
            MappingReadLayoutPlan(layout: .strictlyInterleaved, handling: .asSingle).pairedEndDescription,
            "No (interleaved input mapped as single-end)"
        )
        XCTAssertEqual(MappingReadLayoutPlan(layout: .singleEnd, handling: .asSingle).pairedEndDescription, "No")
        XCTAssertTrue(MappingReadLayoutPlan(layout: .mixedMergedAndPairs, handling: .asPairs).pairsMates)
        XCTAssertFalse(MappingReadLayoutPlan(layout: .mixedMergedAndPairs, handling: .asSingle).pairsMates)
    }

    func testSummaryParametersRecordTheLayoutDecision() {
        let parameters = request(tool: .bowtie2, layout: .mixedMergedAndPairs).summaryParameters()
        XCTAssertEqual(parameters["inputLayout"], .string("mixed_merged_and_pairs"))
        XCTAssertEqual(parameters["readLayoutHandling"], .string("as_single"))
        XCTAssertEqual(parameters["isPairedEnd"], .bool(false))
    }

    // MARK: - Provenance

    func testProvenanceRecordsAndReloadsTheLayoutDecision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-layout-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = request(tool: .bwaMem2, layout: .mixedMergedAndPairs)
        let result = MappingResult(
            mapper: .bwaMem2,
            modeID: request.modeID,
            bamURL: directory.appendingPathComponent("sample.sorted.bam"),
            baiURL: directory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 50,
            mappedReads: 50,
            unmappedReads: 0,
            wallClockSeconds: 1,
            contigs: []
        )
        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: try MappingProvenance.mapperInvocation(for: request),
            normalizationInvocations: [],
            mapperVersion: "2.2.1",
            samtoolsVersion: "1.24",
            inputLayoutReason: "The first 50 records hold 20 adjacent mate pairs and 10 unpaired reads (merged or orphan)."
        )
        XCTAssertEqual(provenance.inputLayout, .mixedMergedAndPairs)
        XCTAssertEqual(provenance.readLayoutHandling, .asPairs)
        XCTAssertTrue(provenance.mapperInvocation.argv.contains("-p"))

        try provenance.save(to: directory)
        let reloaded = try XCTUnwrap(MappingProvenance.load(from: directory))
        XCTAssertEqual(reloaded.inputLayout, .mixedMergedAndPairs)
        XCTAssertEqual(reloaded.readLayoutHandling, .asPairs)
        XCTAssertEqual(reloaded.inputLayoutReason, provenance.inputLayoutReason)
    }

    func testProvenanceLeavesTheLayoutNilWhenTheRequestNeverResolvedIt() throws {
        let request = request(tool: .minimap2, layout: nil)
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            bamURL: output.appendingPathComponent("sample.sorted.bam"),
            baiURL: output.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 1,
            mappedReads: 1,
            unmappedReads: 0,
            wallClockSeconds: 1,
            contigs: []
        )
        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: try MappingProvenance.mapperInvocation(for: request),
            normalizationInvocations: [],
            mapperVersion: "2.31",
            samtoolsVersion: "1.24"
        )
        XCTAssertNil(provenance.inputLayout)
        XCTAssertNil(provenance.readLayoutHandling)
    }

    func testLegacyProvenanceWithoutLayoutFieldsStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-legacy-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = request(tool: .bowtie2, layout: .strictlyInterleaved)
        let result = MappingResult(
            mapper: .bowtie2,
            modeID: request.modeID,
            bamURL: directory.appendingPathComponent("sample.sorted.bam"),
            baiURL: directory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 1,
            mappedReads: 1,
            unmappedReads: 0,
            wallClockSeconds: 1,
            contigs: []
        )
        try MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: try MappingProvenance.mapperInvocation(for: request),
            normalizationInvocations: [],
            mapperVersion: "2.5.5",
            samtoolsVersion: "1.24"
        ).save(to: directory)

        // Strip the layout keys the way a pre-contract file lacks them.
        let url = directory.appendingPathComponent(MappingProvenance.filename)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["inputLayout"] as? String, "strictly_interleaved")
        json.removeValue(forKey: "inputLayout")
        json.removeValue(forKey: "readLayoutHandling")
        json.removeValue(forKey: "inputLayoutReason")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reloaded = try XCTUnwrap(MappingProvenance.load(from: directory))
        XCTAssertNil(reloaded.inputLayout)
        XCTAssertNil(reloaded.readLayoutHandling)
        XCTAssertEqual(reloaded.mapper, .bowtie2)
    }

    // MARK: - CLI invocation

    func testCLIInvocationPinsAResolvedSingleFileLayout() {
        let mixed = request(tool: .bowtie2, layout: .mixedMergedAndPairs)
        let arguments = MappingCLIInvocationBuilder.arguments(for: mixed)
        XCTAssertEqual(arguments.first, interleaved.path)
        XCTAssertTrue(arguments.contains("--read-layout"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--read-layout")! + 1], "mixed")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--mapper")! + 1], "bowtie2")
        XCTAssertFalse(arguments.contains("--preset"))
        XCTAssertFalse(arguments.contains("--paired"))

        XCTAssertEqual(MappingCLIInvocationBuilder.readLayoutArgument(for: .strictlyInterleaved), "interleaved")
        XCTAssertEqual(MappingCLIInvocationBuilder.readLayoutArgument(for: .singleEnd), "single-end")
        XCTAssertNil(MappingCLIInvocationBuilder.readLayoutArgument(for: .pairedFiles))
        XCTAssertNil(MappingCLIInvocationBuilder.readLayoutArgument(for: nil))
    }

    func testCLIInvocationLeavesAutoDetectionForAnUnresolvedRequest() {
        let bundle = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [bundle],
            referenceFASTAURL: reference,
            outputDirectory: output,
            sampleName: "sample",
            threads: 8,
            includeSecondary: true,
            includeSupplementary: false,
            minimumMappingQuality: 20,
            advancedArguments: ["--MD"]
        )
        let arguments = MappingCLIInvocationBuilder.arguments(for: request)
        XCTAssertEqual(arguments.first, bundle.path)
        XCTAssertFalse(arguments.contains("--read-layout"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--preset")! + 1], "map-ont")
        XCTAssertTrue(arguments.contains("--secondary"))
        XCTAssertTrue(arguments.contains("--no-supplementary"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--min-mapq")! + 1], "20")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--extra-args")! + 1], "--MD")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--threads")! + 1], "8")
    }

    func testCLIInvocationBindsTwoFilesWithPaired() {
        let arguments = MappingCLIInvocationBuilder.arguments(for: request(tool: .bwaMem2, layout: .pairedFiles))
        XCTAssertEqual(Array(arguments.prefix(2)), [r1.path, r2.path])
        XCTAssertTrue(arguments.contains("--paired"))
        XCTAssertFalse(arguments.contains("--read-layout"))
    }
}
