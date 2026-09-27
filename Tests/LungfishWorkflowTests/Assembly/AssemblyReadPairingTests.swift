// AssemblyReadPairingTests.swift - Interleaved bundles reach each assembler as pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A paired import is stored as ONE interleaved FASTQ inside its bundle. The
// managed pipeline used to hand that file to SPAdes as `-s`, MEGAHIT as `-r`
// and SKESA as a bare `--reads`, assembling every mate as a single read and
// reporting "Paired-end: no". A request whose single input resolves to a
// strictly interleaved layout must now run as pairs (`--12`,
// `--use_paired_ends`), while a mixed file of merged reads and pairs stays
// single because those flags pair records by position.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class AssemblyReadPairingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-read-pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func request(
        tool: AssemblyTool,
        inputURLs: [URL] = [URL(fileURLWithPath: "/tmp/hg002.fastq")],
        pairedEnd: Bool = false,
        inputLayout: FASTQInputLayout? = nil,
        selectedProfileID: String? = nil,
        extraArguments: [String] = []
    ) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: .illuminaShortReads,
            inputURLs: inputURLs,
            projectName: "hg002",
            outputDirectory: tempDir.appendingPathComponent("out-\(tool.rawValue)"),
            pairedEnd: pairedEnd,
            threads: 4,
            selectedProfileID: selectedProfileID,
            extraArguments: extraArguments,
            inputLayout: inputLayout
        )
    }

    // MARK: - Request model

    func testReadPairingFollowsTheResolvedLayoutForShortReadAssemblers() {
        for tool in [AssemblyTool.spades, .megahit, .skesa] {
            XCTAssertEqual(request(tool: tool).readPairing, .single, tool.rawValue)
            XCTAssertEqual(request(tool: tool, inputLayout: .singleEnd).readPairing, .single, tool.rawValue)
            XCTAssertEqual(request(tool: tool, inputLayout: .strictlyInterleaved).readPairing, .interleaved, tool.rawValue)
            XCTAssertEqual(request(tool: tool, inputLayout: .mixedMergedAndPairs).readPairing, .single, tool.rawValue)
            XCTAssertEqual(
                request(
                    tool: tool,
                    inputURLs: [URL(fileURLWithPath: "/tmp/R1.fastq"), URL(fileURLWithPath: "/tmp/R2.fastq")],
                    pairedEnd: true
                ).readPairing,
                .pairedFiles,
                tool.rawValue
            )
        }
        XCTAssertTrue(AssemblyReadPairing.interleaved.assemblesPairs)
        XCTAssertTrue(AssemblyReadPairing.pairedFiles.assemblesPairs)
        XCTAssertFalse(AssemblyReadPairing.single.assemblesPairs)
        XCTAssertEqual(AssemblyReadPairing.interleaved.displayName, "yes (interleaved pairs)")
    }

    func testLongReadAssemblersNeverPairEvenWhenALayoutIsRecorded() {
        let flye = AssemblyRunRequest(
            tool: .flye,
            readType: .ontReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/ont.fastq")],
            projectName: "ont",
            outputDirectory: tempDir,
            threads: 4,
            inputLayout: .strictlyInterleaved
        )
        XCTAssertEqual(flye.readPairing, .single)
        XCTAssertEqual(flye.readLayoutHandling, .asSingle)
    }

    func testInputLayoutSurvivesEveryRequestCopyAndDecodesWhenAbsent() throws {
        let original = request(tool: .spades, inputLayout: .strictlyInterleaved)
        XCTAssertEqual(original.normalizedForExecution().inputLayout, .strictlyInterleaved)
        XCTAssertEqual(original.withInputLayout(.mixedMergedAndPairs).inputLayout, .mixedMergedAndPairs)

        let roundTripped = try JSONDecoder().decode(AssemblyRunRequest.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(roundTripped, original)

        // A request persisted before `inputLayout` existed still decodes.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "inputLayout")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(AssemblyRunRequest.self, from: legacyData).inputLayout)
    }

    // MARK: - Command lines

    func testSpadesAssemblesAnInterleavedFileWithDashDash12() throws {
        let command = try ManagedAssemblyPipeline.buildCommand(
            for: request(tool: .spades, inputLayout: .strictlyInterleaved, selectedProfileID: "isolate")
        )
        let index = try XCTUnwrap(command.arguments.firstIndex(of: "--12"))
        XCTAssertEqual(command.arguments[index + 1], "/tmp/hg002.fastq")
        XCTAssertFalse(command.arguments.contains("-s"))
        XCTAssertFalse(command.arguments.contains("-1"))
    }

    func testMegahitAssemblesAnInterleavedFileWithDashDash12() throws {
        let command = try ManagedAssemblyPipeline.buildCommand(
            for: request(tool: .megahit, inputLayout: .strictlyInterleaved),
            host: AssemblyExecutionHost(operatingSystem: .other, architecture: "x86_64")
        )
        let index = try XCTUnwrap(command.arguments.firstIndex(of: "--12"))
        XCTAssertEqual(command.arguments[index + 1], "/tmp/hg002.fastq")
        XCTAssertFalse(command.arguments.contains("-r"))
    }

    func testSkesaAssemblesAnInterleavedFileWithUsePairedEnds() throws {
        let command = try ManagedAssemblyPipeline.buildCommand(
            for: request(tool: .skesa, inputLayout: .strictlyInterleaved)
        )
        let index = try XCTUnwrap(command.arguments.firstIndex(of: "--reads"))
        XCTAssertEqual(command.arguments[index + 1], "/tmp/hg002.fastq")
        XCTAssertTrue(command.arguments.contains("--use_paired_ends"))
    }

    func testMixedAndSingleEndFilesStillRunAsSingleReads() throws {
        for layout in [FASTQInputLayout.mixedMergedAndPairs, .singleEnd] {
            let spades = try ManagedAssemblyPipeline.buildCommand(
                for: request(tool: .spades, inputLayout: layout)
            )
            XCTAssertTrue(spades.arguments.contains("-s"), "\(layout)")
            XCTAssertFalse(spades.arguments.contains("--12"), "\(layout)")

            let megahit = try ManagedAssemblyPipeline.buildCommand(
                for: request(tool: .megahit, inputLayout: layout),
                host: AssemblyExecutionHost(operatingSystem: .other, architecture: "x86_64")
            )
            XCTAssertTrue(megahit.arguments.contains("-r"), "\(layout)")
            XCTAssertFalse(megahit.arguments.contains("--12"), "\(layout)")

            let skesa = try ManagedAssemblyPipeline.buildCommand(
                for: request(tool: .skesa, inputLayout: layout)
            )
            XCTAssertFalse(skesa.arguments.contains("--use_paired_ends"), "\(layout)")
        }
    }

    func testR1R2FilesStillTakePrecedenceOverALayout() throws {
        let command = try ManagedAssemblyPipeline.buildCommand(
            for: request(
                tool: .spades,
                inputURLs: [URL(fileURLWithPath: "/tmp/R1.fastq"), URL(fileURLWithPath: "/tmp/R2.fastq")],
                pairedEnd: true,
                inputLayout: .strictlyInterleaved
            )
        )
        XCTAssertTrue(command.arguments.contains("-1"))
        XCTAssertTrue(command.arguments.contains("-2"))
        XCTAssertFalse(command.arguments.contains("--12"))
    }

    // MARK: - Registry

    func testShortReadAssemblersDeclareInterleavedInputAsPairs() throws {
        for id in ["assemble.spades", "assemble.megahit", "assemble.skesa"] {
            let declaration = try XCTUnwrap(FASTQConsumerRegistry.declaration(for: id), id)
            XCTAssertEqual(declaration.handling(for: .strictlyInterleaved), .asPairs, id)
            XCTAssertEqual(declaration.handling(for: .pairedFiles), .asPairs, id)
            XCTAssertEqual(declaration.handling(for: .mixedMergedAndPairs), .asSingle, id)
            XCTAssertEqual(declaration.handling(for: .singleEnd), .asSingle, id)
            XCTAssertTrue(declaration.mixedRationale.contains("by position"), id)
        }
    }
}
