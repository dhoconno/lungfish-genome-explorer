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

    /// SKESA reads a comma-separated `--reads` value as the R1 and R2 files
    /// of one pair. SKESA 2.5.1 refuses two unpaired files of different
    /// sizes ("contain different number of mates") and pairs two of the same
    /// size read for read, so each unpaired file is its own `--reads`, the
    /// form SKESA's usage gives for several runs (R3, lane 1q).
    func testSkesaReadsEachUnpairedFileAsItsOwnRunNotAsMates() throws {
        let files = ["/tmp/run_a.fastq", "/tmp/run_b.fastq", "/tmp/run_c.fastq.gz"].map { URL(fileURLWithPath: $0) }
        let unpaired = try ManagedAssemblyPipeline.buildCommand(for: request(tool: .skesa, inputURLs: files))
        XCTAssertEqual(readsValues(in: unpaired.arguments), files.map(\.path))
        XCTAssertFalse(unpaired.arguments.contains { $0.contains(",") }, "no comma list, which SKESA reads as mates")
        XCTAssertFalse(unpaired.arguments.contains("--use_paired_ends"))

        let mates = [URL(fileURLWithPath: "/tmp/R1.fastq"), URL(fileURLWithPath: "/tmp/R2.fastq")]
        let paired = try ManagedAssemblyPipeline.buildCommand(
            for: request(tool: .skesa, inputURLs: mates, pairedEnd: true)
        )
        XCTAssertEqual(readsValues(in: paired.arguments), ["/tmp/R1.fastq,/tmp/R2.fastq"], "a pair stays one value")

        let single = try ManagedAssemblyPipeline.buildCommand(for: request(tool: .skesa))
        XCTAssertEqual(readsValues(in: single.arguments), ["/tmp/hg002.fastq"])
    }

    /// Every value that follows a `--reads` flag, in order.
    private func readsValues(in arguments: [String]) -> [String] {
        zip(arguments, arguments.dropFirst()).filter { $0.0 == "--reads" }.map(\.1)
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

    // MARK: - Pairs and single reads (owner decision 1 of 2026-10-03)

    private let readSetInputs = ["R1", "R2", "merged", "orphans"].map { URL(fileURLWithPath: "/tmp/\($0).fastq") }
    private let readSetRoles: [AssemblyInputRole] = [.mateR1, .mateR2, .merged, .single]

    private func readSetRequest(
        tool: AssemblyTool = .spades,
        roles: [AssemblyInputRole]? = nil,
        inputURLs: [URL]? = nil
    ) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: .illuminaShortReads,
            inputURLs: inputURLs ?? readSetInputs,
            projectName: "mixed",
            outputDirectory: tempDir.appendingPathComponent("out-\(tool.rawValue)"),
            threads: 4,
            inputRoles: roles ?? readSetRoles
        )
    }

    func testARequestWithInputRolesAssemblesPairsAndSingleReads() {
        let request = readSetRequest()
        XCTAssertEqual(request.readPairing, .pairedFilesWithSingleReads)
        XCTAssertTrue(request.readPairing.assemblesPairs)
        XCTAssertEqual(request.readPairing.displayName, "yes (R1/R2 files and single reads)")
        XCTAssertEqual(request.readLayoutHandling, .asPairs)
        XCTAssertEqual(request.effectiveInputLayout, .mixedMergedAndPairs)
        XCTAssertEqual(
            request.readSetFiles,
            AssemblyReadSetFiles(
                forward: readSetInputs[0],
                reverse: readSetInputs[1],
                singleReads: [
                    .init(url: readSetInputs[2], isMerged: true),
                    .init(url: readSetInputs[3], isMerged: false),
                ]
            )
        )
    }

    func testInputRolesSurviveEveryRequestCopyAndDecodeWhenAbsent() throws {
        let original = readSetRequest()
        XCTAssertEqual(original.normalizedForExecution().inputRoles, readSetRoles)
        XCTAssertEqual(original.withInputLayout(nil).inputRoles, readSetRoles)

        let roundTripped = try JSONDecoder().decode(AssemblyRunRequest.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(roundTripped, original)

        // A request persisted before `inputRoles` existed still decodes.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "inputRoles")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(AssemblyRunRequest.self, from: legacyData).inputRoles)
    }

    func testRolesThatDoNotNameOnePairAreRefusedByEveryShortReadAssembler() {
        let bad: [(label: String, roles: [AssemblyInputRole], inputs: [URL]?)] = [
            ("too few roles", [.mateR1, .mateR2], nil),
            ("two R1 files", [.mateR1, .mateR1, .mateR2, .single], nil),
            ("no R2 file", [.mateR1, .merged, .single, .single], nil),
        ]
        for testCase in bad {
            for tool in [AssemblyTool.spades, .megahit, .skesa] {
                let request = readSetRequest(tool: tool, roles: testCase.roles, inputURLs: testCase.inputs)
                XCTAssertNil(request.readSetFiles, testCase.label)
                XCTAssertThrowsError(try ManagedAssemblyPipeline.buildCommand(for: request), "\(testCase.label) \(tool.rawValue)") { error in
                    guard case ManagedAssemblyPipelineError.unsupportedInputTopology = error else {
                        return XCTFail("\(error)")
                    }
                }
            }
        }
    }

    func testLongReadAssemblersRefuseASampleOfSeveralFiles() {
        for tool in [AssemblyTool.flye, .hifiasm] {
            XCTAssertThrowsError(try ManagedAssemblyPipeline.buildCommand(for: readSetRequest(tool: tool)), tool.rawValue)
        }
    }

    func testEveryAssemblerCommandNamesTheRolesOfAPairWithSingleReads() throws {
        let host = AssemblyExecutionHost(operatingSystem: .other, architecture: "x86_64")
        let spades = try ManagedAssemblyPipeline.buildCommand(for: readSetRequest(tool: .spades), host: host).arguments
        XCTAssertEqual(
            Array(spades.prefix(9)),
            ["--isolate", "-1", "/tmp/R1.fastq", "-2", "/tmp/R2.fastq", "--merged", "/tmp/merged.fastq", "-s", "/tmp/orphans.fastq"]
        )
        let megahit = try ManagedAssemblyPipeline.buildCommand(for: readSetRequest(tool: .megahit), host: host).arguments
        XCTAssertEqual(
            Array(megahit.prefix(6)),
            ["-1", "/tmp/R1.fastq", "-2", "/tmp/R2.fastq", "-r", "/tmp/merged.fastq,/tmp/orphans.fastq"]
        )
        let skesa = try ManagedAssemblyPipeline.buildCommand(for: readSetRequest(tool: .skesa), host: host).arguments
        XCTAssertEqual(
            Array(skesa.prefix(6)),
            ["--reads", "/tmp/R1.fastq,/tmp/R2.fastq", "--reads", "/tmp/merged.fastq", "--reads", "/tmp/orphans.fastq"]
        )
        XCTAssertFalse(skesa.contains("--use_paired_ends"))
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
