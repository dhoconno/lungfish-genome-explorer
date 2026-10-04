// MapReadSetReplayTests.swift - Real mappers on a merge derivative, window run and recorded command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/READ-PAIRING.md (decision 1) and CLI-EQUIVALENCE.md. A merge
// derivative holds 23 unmerged pairs and 77 merged reads, made by bbmerge
// from Tests/Fixtures/sarscov2/test_{1,2}. Each managed mapper maps it to the
// SARS-CoV-2 genome through the Map Reads window's path, and the BAM must
// hold 123 primary reads of which 46 are paired in sequencing, so the 23
// pairs mapped as pairs and the 77 merged reads as single reads. The command
// the window recorded is then replayed on a copy and must give the same
// alignment records. The real tools run, so the class name ends in
// ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class MapReadSetReplayTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "map-read-set-replay")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testMinimap2MapsTheUnmergedPairsAsPairs() async throws {
        try await assertReplay(tool: .minimap2, modeID: MappingMode.defaultShortRead.id)
    }

    func testBWAMEM2MapsTheUnmergedPairsAsPairs() async throws {
        try await assertReplay(tool: .bwaMem2, modeID: MappingMode.defaultShortRead.id)
    }

    func testBowtie2MapsTheUnmergedPairsAsPairs() async throws {
        try await assertReplay(tool: .bowtie2, modeID: MappingMode.defaultShortRead.id)
    }

    func testBBMapMergesItsTwoRunsIntoOneSortedIndexedBAM() async throws {
        let bam = try await assertReplay(tool: .bbmap, modeID: MappingMode.bbmapStandard.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bam.path + ".bai"), "the merged BAM is not indexed")
        let header = try samtools(["view", "-H", bam.path])
        XCTAssertTrue(header.contains("SO:coordinate"), "the merged BAM is not coordinate sorted:\n\(header)")
        XCTAssertEqual(header.components(separatedBy: "\n").filter { $0.hasPrefix("@RG") }.count, 1, "one read group")
    }

    // MARK: - Helpers

    /// Maps the merge derivative through the window's path on root A,
    /// checks the flagstat counts, replays the recorded command on root B
    /// and checks that B holds the same alignment records. Returns A's BAM.
    @discardableResult
    private func assertReplay(tool: MappingTool, modeID: String) async throws -> URL {
        _ = try XCTUnwrap(BamFixtureBuilder.locateSamtools(), "the replay needs samtools")
        do {
            if tool == .bbmap {
                guard await NativeToolRunner.shared.isToolAvailable(.bbmap) else { throw XCTSkip("BBMap is not installed") }
            } else {
                _ = try await CondaManager.shared.toolPath(name: tool.executableName, environment: tool.environmentName)
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip("\(tool.displayName) is not installed")
        }

        let rootA = scratch.appendingPathComponent("A-\(tool.rawValue)", isDirectory: true)
        let rootB = scratch.appendingPathComponent("B-\(tool.rawValue)", isDirectory: true)
        for root in [rootA, rootB] {
            try Self.makeProject(in: root)
        }
        let projectA = rootA.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundleA = projectA.appendingPathComponent("Imports/merge.lungfishfastq", isDirectory: true)
        let analysisA = try AnalysesFolder.createAnalysisDirectory(tool: tool.rawValue, in: projectA)

        // The window's path on root A: the dialog's request, the begin
        // helper, then the resolution and pipeline its launch closure runs.
        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [bundleA],
            mode: .perBundle,
            tool: tool,
            modeID: modeID,
            referenceFASTAURL: projectA.appendingPathComponent("genome.fasta"),
            sourceReferenceBundleURL: nil,
            projectURL: projectA,
            outputDirectory: analysisA,
            runToken: "replay",
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 2,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
        let request = try XCTUnwrap(plan.requests.first).withOutputDirectory(analysisA)
        let reporter = RecordingOperationReporter()
        var launched = false
        AppDelegate.beginManagedMappingOperation(request: request, routeContext: nil, reporter: reporter) { _ in
            launched = true
        }
        XCTAssertTrue(launched)
        let resolved = try await AppDelegate().resolveManagedMappingInputs(for: request, progress: { _ in })
        let result = try await ManagedMappingPipeline().run(
            request: resolved.request,
            inputLayoutReason: resolved.layoutResolution.reason,
            readSetPlan: resolved.readSetPlan
        )

        let flagstat = try Self.flagstatCounts(samtools(["flagstat", result.bamURL.path]))
        XCTAssertEqual(flagstat["primary"], 123, "\(tool.rawValue): \(flagstat)")
        XCTAssertEqual(flagstat["paired in sequencing"], 46, "\(tool.rawValue): the 23 unmerged pairs map as pairs")
        XCTAssertEqual(flagstat["read1"], 23, "\(tool.rawValue)")
        XCTAssertEqual(flagstat["read2"], 23, "\(tool.rawValue)")
        XCTAssertEqual(
            (flagstat["primary"] ?? 0) - (flagstat["paired in sequencing"] ?? 0),
            77,
            "\(tool.rawValue): the 77 merged reads map as single reads"
        )

        // The recorded command, rebased onto root B and run in this process.
        let recorded = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertEqual(try RecordedCLICommand.parseScript(recorded).count, 1)
        let replay = try RecordedCLICommand.rebased(recorded, from: rootA, to: rootB)
        try await RecordedCLICommand.runInProcess(replay)
        let projectB = rootB.appendingPathComponent("Project.lungfish", isDirectory: true)
        let analysisB = projectB.appendingPathComponent("Analyses/\(analysisA.lastPathComponent)", isDirectory: true)
        let resultB = try MappingResult.load(from: analysisB)
        XCTAssertEqual(
            try alignmentRecords(resultB.bamURL),
            try alignmentRecords(result.bamURL),
            "\(tool.rawValue): the recorded command mapped the reads differently"
        )
        return result.bamURL
    }

    /// A project holding the merge derivative and the reference.
    private static func makeProject(in root: URL) throws {
        let fileManager = FileManager.default
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Imports/merge.lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        let readPairing = fixtures.appendingPathComponent("read-pairing/mapping", isDirectory: true)
        for (source, name) in [("merged.fq", "merged.fastq"), ("u1.fq", "unmerged_R1.fastq"), ("u2.fq", "unmerged_R2.fastq")] {
            try fileManager.copyItem(at: readPairing.appendingPathComponent(source), to: bundle.appendingPathComponent(name))
        }
        try fileManager.copyItem(
            at: fixtures.appendingPathComponent("sarscov2/genome.fasta"),
            to: project.appendingPathComponent("genome.fasta")
        )
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 77),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 23),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 23),
        ])
        let operation = FASTQDerivativeOperation(kind: .pairedEndMerge)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "merge",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "merged.fastq",
                payload: .fullMixed(classification),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 123, baseCount: 30_000),
                pairingMode: .pairedEnd,
                readClassification: classification,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
    }

    /// The alignment records of a BAM, sorted, without the header.
    private func alignmentRecords(_ bam: URL) throws -> [String] {
        try samtools(["view", bam.path]).split(separator: "\n").map(String.init).sorted()
    }

    /// `samtools flagstat` counts by label, such as `primary` or `read1`.
    private static func flagstatCounts(_ output: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: " + ")
            guard parts.count == 2, let count = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let rest = parts[1].drop { $0.isNumber || $0 == " " }
            let label = rest.components(separatedBy: " (")[0].trimmingCharacters(in: .whitespaces)
            counts[label] = count
        }
        return counts
    }

    private func samtools(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(BamFixtureBuilder.locateSamtools()))
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "samtools \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }
}
