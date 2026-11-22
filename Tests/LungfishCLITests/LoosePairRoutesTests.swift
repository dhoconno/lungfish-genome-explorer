// LoosePairRoutesTests.swift - A loose R1 and R2 that do not pair are refused by map, assemble and Viral Recon before any tool starts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// BIO ruling BIO-ROUTES, binding items 1 to 4 (S1 on every route). `lungfish-cli map --paired`,
/// `lungfish-cli assemble --paired` and a Viral Recon samplesheet row with `fastq_1` and `fastq_2`
/// handed a loose R1 and R2 to minimap2, bwa-mem2, bowtie2, MEGAHIT, SPAdes or fastp, which pair two
/// files by position. A short R2 left the rest of R1 out with no word, and an R2 out of step joined
/// two different fragments in each pair. Each route now reads both files at planning
/// (`LooseMatePairCheck.refusal`, FIX-B) and refuses with the run words B1 and B2 and the command's
/// input exit code 3. Every test stops at the resolver, or at a stand-in for Nextflow, so no mapper,
/// assembler, Nextflow or Docker runs, at the base or after the fix.
final class LoosePairRoutesTests: XCTestCase {

    var root: URL!
    var loose: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "loose-pair-routes").resolvingSymlinksInPath()
        loose = root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    static let shortMateWords = "Paired FASTQ mates do not match. S_R1.fastq has 100 reads, but S_R2.fastq has 60. Nothing ran. Check that both files are complete or run each as single reads."
    static let outOfStepWords = "Paired FASTQ mates are out of step at read 2. S_R1.fastq has 'frag2/1', but S_R2.fastq has 'frag3/2'. Nothing ran. Check that both files are from the same run and neither was sorted or subsampled on its own, or run each file as single reads."

    // MARK: - A 100-read R1 with a 60-read R2

    func testA100ReadR1WithA60ReadR2IsRefusedByEveryRoute() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        let r2 = try writeMates("S_R2.fastq", mate: 2, count: 60)

        var observed: [String] = []
        var expected: [String] = []
        for route in Route.allCases {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            observed.append("\(route.name) | \(refusal.words ?? "nil") | \(refusal.exitCode.map(String.init) ?? "nil")")
            expected.append("\(route.name) | \(route.frame + Self.shortMateWords) | 3")
        }
        XCTAssertEqual(observed, expected)
    }

    // MARK: - Equal counts, records 2 and 3 of R2 swapped

    func testEqualCountMatesOutOfStepAreRefusedByEveryRoute() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        var names = (1...100).map { "frag\($0)/2" }
        names.swapAt(1, 2)
        let r2 = loose.appendingPathComponent("S_R2.fastq")
        try Data(ReadSetFixtures.fastq(names).utf8).write(to: r2)

        var observed: [String] = []
        var expected: [String] = []
        for route in Route.allCases {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            observed.append("\(route.name) | \(refusal.words ?? "nil") | \(refusal.exitCode.map(String.init) ?? "nil")")
            expected.append("\(route.name) | \(route.frame + Self.outOfStepWords) | 3")
        }
        XCTAssertEqual(observed, expected)
    }

    // MARK: - Equal pairs (guard)

    func testAnEqualInStepPairPlansAsBeforeOnEveryRoute() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        let r2 = try writeMates("S_R2.fastq", mate: 2, count: 100)

        for route in Route.allCases {
            let refusal = await planRefusal(route, r1: r1, r2: r2)
            XCTAssertEqual(refusal.words, nil, route.name)
            XCTAssertEqual(refusal.exitCode, nil, route.name)
        }

        for tool in MappingTool.allCases {
            let resolved = try await resolveMapping(tool: tool, r1: r1, r2: r2)
            XCTAssertEqual(resolved.request.inputFASTQURLs, [r1.standardizedFileURL, r2.standardizedFileURL], tool.rawValue)
            XCTAssertEqual(resolved.request.pairedEnd, true, tool.rawValue)
            XCTAssertEqual(resolved.layoutResolution.layout, .pairedFiles, tool.rawValue)
        }
        for tool in [AssemblyTool.spades, .megahit, .skesa] {
            let resolved = try await resolveAssembly(tool: tool, r1: r1, r2: r2)
            XCTAssertEqual(resolved.inputs.executionInputURLs.map(\.standardizedFileURL), [r1.standardizedFileURL, r2.standardizedFileURL], tool.rawValue)
            XCTAssertEqual(resolved.inputRoles, nil, tool.rawValue)
        }

        let runner = CapturingNextflowRunner()
        let runBundleURL = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        try await viralReconCommand(r1: r1, r2: r2, runBundleURL: runBundleURL).run(nfCoreRunner: runner)
        XCTAssertEqual(runner.launches, 1, "the equal pair is launched as before")
        XCTAssertEqual(try NFCoreRunBundleStore.read(from: runBundleURL).executionStatus, .completed)
    }

    // MARK: - Viral Recon records the refusal

    /// BIO-ROUTES item 3. The refused run writes its failed manifest with the input exit code, as a failed
    /// split does, and Nextflow never starts.
    func testARefusedViralReconRowRecordsAFailedRunAndNeverStartsNextflow() async throws {
        let r1 = try writeMates("S_R1.fastq", mate: 1, count: 100)
        let r2 = try writeMates("S_R2.fastq", mate: 2, count: 60)
        let runner = CapturingNextflowRunner()
        let runBundleURL = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        do {
            try await viralReconCommand(r1: r1, r2: r2, runBundleURL: runBundleURL).run(nfCoreRunner: runner)
        } catch {}

        let manifest = try NFCoreRunBundleStore.read(from: runBundleURL)
        XCTAssertEqual(manifest.executionStatus, .failed)
        XCTAssertEqual(manifest.exitCode, 3)
        XCTAssertEqual(runner.launches, 0, "Nextflow never started")
    }

    // MARK: - Routes

    /// Each route that runs a loose R1 and R2 as one pair.
    enum Route: CaseIterable {
        case map(MappingTool)
        case assemble(AssemblyTool)
        case viralReconSamplesheet

        static var allCases: [Route] {
            MappingTool.allCases.map(Route.map) + [AssemblyTool.spades, .megahit, .skesa].map(Route.assemble) + [.viralReconSamplesheet]
        }

        var name: String {
            switch self {
            case .map(let tool): return "map --paired --mapper \(tool.rawValue)"
            case .assemble(let tool): return "assemble --paired --assembler \(tool.rawValue)"
            case .viralReconSamplesheet: return "workflow run nf-core/viralrecon --input samplesheet.csv"
            }
        }

        /// The command's own frame around the run words: the mapper resolver's input refusal, the
        /// assembler resolver's words as they are, and `workflow run`'s input refusal (exit 3).
        var frame: String {
            switch self {
            case .map: return "The reads cannot be handed to the mapper: "
            case .assemble: return ""
            case .viralReconSamplesheet: return "Validation failed:\n  - "
            }
        }
    }

    /// The words and exit code of the refusal of `r1` and `r2` on `route`, both nil when it plans. The map
    /// and assemble commands give every error of their resolvers the input exit code
    /// (`MapCommand.swift`, `MappingInputResolverError` to `MapRunFailure.input`, and
    /// `AssembleCommand.swift`, `AssemblyReadSetResolutionError` to `.inputError`).
    func planRefusal(_ route: Route, r1: URL, r2: URL) async -> (words: String?, exitCode: Int32?) {
        do {
            switch route {
            case .map(let tool):
                _ = try await resolveMapping(tool: tool, r1: r1, r2: r2)
            case .assemble(let tool):
                _ = try await resolveAssembly(tool: tool, r1: r1, r2: r2)
            case .viralReconSamplesheet:
                let runBundleURL = root.appendingPathComponent("viralrecon-\(UUID().uuidString).lungfishrun", isDirectory: true)
                try await viralReconCommand(r1: r1, r2: r2, runBundleURL: runBundleURL).run(nfCoreRunner: CapturingNextflowRunner())
            }
            return (nil, nil)
        } catch let error as MappingInputResolverError {
            return (error.localizedDescription, MapRunFailure.input(error.localizedDescription).exitCode.rawValue)
        } catch let error as AssemblyReadSetResolutionError {
            return (error.localizedDescription, CLIExitCode.inputError.rawValue)
        } catch let error as CLIError {
            return (error.localizedDescription, error.exitCode.rawValue)
        } catch {
            return (error.localizedDescription, nil)
        }
    }

    func resolveMapping(tool: MappingTool, r1: URL, r2: URL) async throws -> MappingResolvedInputs {
        try await MappingInputResolver.resolve(
            request: MappingRunRequest(
                tool: tool,
                modeID: tool == .bbmap ? MappingMode.bbmapStandard.id : MappingMode.defaultShortRead.id,
                inputFASTQURLs: [r1, r2],
                referenceFASTAURL: root.appendingPathComponent("reference.fa"),
                outputDirectory: root.appendingPathComponent("map-\(tool.rawValue)", isDirectory: true),
                sampleName: "S",
                pairedEnd: true,
                threads: 1
            ),
            materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
        )
    }

    func resolveAssembly(tool: AssemblyTool, r1: URL, r2: URL) async throws -> AssemblyResolvedInputs {
        try await AssemblyReadSetResolution.resolve(
            inputURLs: [r1, r2],
            tool: tool,
            pairedEnd: true,
            explicitLayout: nil,
            materializationDirectory: root.appendingPathComponent("assemble-\(UUID().uuidString)", isDirectory: true),
            materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
        )
    }

    /// `workflow run nf-core/viralrecon` on a samplesheet whose one row names `r1` as `fastq_1` and `r2`
    /// as `fastq_2`.
    func viralReconCommand(r1: URL, r2: URL, runBundleURL: URL) throws -> RunSubcommand {
        let samplesheet = root.appendingPathComponent("samplesheet-\(UUID().uuidString).csv")
        try "sample,fastq_1,fastq_2\nS,\(r1.path),\(r2.path)\n".write(to: samplesheet, atomically: true, encoding: .utf8)
        let results = root.appendingPathComponent("results-\(UUID().uuidString)", isDirectory: true)
        return try RunSubcommand.parse([
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", samplesheet.path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", runBundleURL.path,
            "--version", "3.0.0",
            "--param", "platform=illumina",
            "--quiet",
        ])
    }

    /// Stands in for Nextflow: counts launches and makes the results folder the run expects.
    private final class CapturingNextflowRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        private(set) var launches = 0

        func runNextflow(_ launch: NFCoreWorkflowLaunch) async throws -> NFCoreWorkflowProcessResult {
            launches += 1
            if let index = launch.arguments.firstIndex(of: "--outdir"), index + 1 < launch.arguments.count {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: launch.arguments[index + 1]), withIntermediateDirectories: true)
            }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "done\n", standardError: "")
        }
    }

    /// Writes `count` records named `frag<i>/<mate>` to `name` in the loose folder.
    func writeMates(_ name: String, mate: Int, count: Int) throws -> URL {
        let url = loose.appendingPathComponent(name)
        try Data(ReadSetFixtures.fastq((1...count).map { "frag\($0)/\(mate)" }).utf8).write(to: url)
        return url
    }
}
