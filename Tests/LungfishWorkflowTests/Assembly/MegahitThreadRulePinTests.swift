// MegahitThreadRulePinTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Pins of the thread count, the memory and the argv a MEGAHIT request gets on each host, and of the value the
// assembly record and the bundle metadata hold for a request of 8 threads (Phase 2.13 lane 13.19 M1, QA 1).
// The expected numbers are the arm64 cap, so a change of the cap moves exactly these lines.

import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO
import LungfishTestSupport

private enum MegahitRuleHosts {
    static let appleSilicon = AssemblyExecutionHost(operatingSystem: .macOS, architecture: "arm64")
    static let intelMac = AssemblyExecutionHost(operatingSystem: .macOS, architecture: "x86_64")
    static let otherSystem = AssemblyExecutionHost(operatingSystem: .other, architecture: "x86_64")
}

private enum MegahitRuleFixtures {
    static func request(
        tool: AssemblyTool = .megahit,
        threads: Int,
        memoryGB: Int? = nil,
        outputDirectory: URL
    ) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: tool,
            readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/R1.fastq.gz"), URL(fileURLWithPath: "/tmp/R2.fastq.gz")],
            projectName: "megahit-rule-pin",
            outputDirectory: outputDirectory,
            pairedEnd: true,
            threads: threads,
            memoryGB: memoryGB
        )
    }

    static func scratch(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("megahit-rule-pin-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A completed MEGAHIT result for `request`, whose contigs sit in `request.outputDirectory`.
    static func result(for request: AssemblyRunRequest) throws -> AssemblyResult {
        let folder = request.outputDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ">megahit_ctg_1\nACGTACGTACGTACGT\n>megahit_ctg_2\nTTTTCCCCAAAAGGGG\n"
            .write(to: folder.appendingPathComponent("final.contigs.fa"), atomically: true, encoding: .utf8)
        try "megahit completed\n".write(
            to: folder.appendingPathComponent("assembly.log"), atomically: true, encoding: .utf8)
        return try AssemblyOutputNormalizer.normalize(
            request: request,
            primaryOutputDirectory: folder,
            commandLine: "megahit -1 R1.fastq.gz -2 R2.fastq.gz -o megahit-output",
            wallTimeSeconds: 18,
            assemblerVersion: "1.2.9"
        )
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

final class MegahitThreadRulePinTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/megahit-rule-pin-never-written/out")

    func testOnlyAppleSiliconCapsMegahitThreads() {
        XCTAssertTrue(MegahitRuleHosts.appleSilicon.capsMegahitThreads)
        XCTAssertFalse(MegahitRuleHosts.intelMac.capsMegahitThreads)
        XCTAssertFalse(MegahitRuleHosts.otherSystem.capsMegahitThreads)
    }

    func testEffectiveThreadCountOfAMegahitRequestOnEachHost() {
        let eight = MegahitRuleFixtures.request(threads: 8, outputDirectory: folder)
        XCTAssertEqual(eight.effectiveThreadCount(on: MegahitRuleHosts.appleSilicon), 2)
        XCTAssertEqual(eight.effectiveThreadCount(on: MegahitRuleHosts.intelMac), 8)
        XCTAssertEqual(eight.effectiveThreadCount(on: MegahitRuleHosts.otherSystem), 8)
        XCTAssertEqual(eight.normalizedForExecution(on: MegahitRuleHosts.appleSilicon).threads, 2)
        XCTAssertEqual(eight.normalizedForExecution(on: MegahitRuleHosts.otherSystem).threads, 8)

        let one = MegahitRuleFixtures.request(threads: 1, outputDirectory: folder)
        XCTAssertEqual(one.effectiveThreadCount(on: MegahitRuleHosts.appleSilicon), 1)
        let none = MegahitRuleFixtures.request(threads: 0, outputDirectory: folder)
        XCTAssertEqual(none.effectiveThreadCount(on: MegahitRuleHosts.appleSilicon), 1)
        XCTAssertEqual(none.effectiveThreadCount(on: MegahitRuleHosts.otherSystem), 1)
    }

    func testOnlyMegahitIsCapped() {
        let spades = MegahitRuleFixtures.request(tool: .spades, threads: 8, outputDirectory: folder)
        XCTAssertEqual(spades.effectiveThreadCount(on: MegahitRuleHosts.appleSilicon), 8)
    }

    func testMegahitArgvOnAppleSiliconAndOnAnotherHost() throws {
        let scratch = try MegahitRuleFixtures.scratch("argv")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let request = MegahitRuleFixtures.request(
            threads: 8, memoryGB: 24, outputDirectory: scratch.appendingPathComponent("out"))

        let apple = try ManagedAssemblyPipeline.buildCommand(for: request, host: MegahitRuleHosts.appleSilicon).arguments
        XCTAssertEqual(MegahitRuleFixtures.value(after: "--num-cpu-threads", in: apple), "2")
        XCTAssertEqual(MegahitRuleFixtures.value(after: "--memory", in: apple), "25769803776")
        XCTAssertTrue(apple.contains("--no-hw-accel"))

        let other = try ManagedAssemblyPipeline.buildCommand(for: request, host: MegahitRuleHosts.otherSystem).arguments
        XCTAssertEqual(MegahitRuleFixtures.value(after: "--num-cpu-threads", in: other), "8")
        XCTAssertEqual(MegahitRuleFixtures.value(after: "--memory", in: other), "25769803776")
        XCTAssertFalse(other.contains("--no-hw-accel"))
    }

    func testMegahitMemoryBytesAreWholeGigabytesAndAtLeastOne() {
        let gigabyte: Int64 = 1024 * 1024 * 1024
        let none = MegahitRuleFixtures.request(threads: 4, outputDirectory: folder)
        XCTAssertNil(none.effectiveMegahitMemoryBytes)
        let zero = MegahitRuleFixtures.request(threads: 4, memoryGB: 0, outputDirectory: folder)
        XCTAssertEqual(zero.effectiveMegahitMemoryBytes, gigabyte)
        let negative = MegahitRuleFixtures.request(threads: 4, memoryGB: -3, outputDirectory: folder)
        XCTAssertEqual(negative.effectiveMegahitMemoryBytes, gigabyte)
        let twentyFour = MegahitRuleFixtures.request(threads: 4, memoryGB: 24, outputDirectory: folder)
        XCTAssertEqual(twentyFour.effectiveMegahitMemoryBytes, 24 * gigabyte)
        let spades = MegahitRuleFixtures.request(tool: .spades, threads: 4, memoryGB: 24, outputDirectory: folder)
        XCTAssertNil(spades.effectiveMegahitMemoryBytes)
    }

    func testRecordHoldsTheCountsOfTheRequestItIsGiven() throws {
        let scratch = try MegahitRuleFixtures.scratch("record")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let asked = MegahitRuleFixtures.request(
            threads: 8, memoryGB: 24, outputDirectory: scratch.appendingPathComponent("asked"))
        let ran = asked.normalizedForExecution(on: MegahitRuleHosts.appleSilicon)

        let askedRecord = ProvenanceBuilder.build(
            request: asked, result: try MegahitRuleFixtures.result(for: asked), inputRecords: [])
        XCTAssertEqual(askedRecord.parameters.threads, 8, "a record holds the count of the request it is handed")
        XCTAssertEqual(askedRecord.parameters.memoryGB, 24)

        let ranRecord = ProvenanceBuilder.build(
            request: ran, result: try MegahitRuleFixtures.result(for: ran), inputRecords: [])
        XCTAssertEqual(ranRecord.parameters.threads, 2, "the CLI hands over the normalized request")
        XCTAssertEqual(ranRecord.parameters.memoryGB, 24)
    }

    func testRecordOfAZeroGigabyteRequestNamesZeroWhileTheArgvAsksForOne() throws {
        let scratch = try MegahitRuleFixtures.scratch("zero-memory")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let zero = MegahitRuleFixtures.request(
            threads: 2, memoryGB: 0, outputDirectory: scratch.appendingPathComponent("zero"))
        let ran = zero.normalizedForExecution(on: MegahitRuleHosts.appleSilicon)

        let arguments = try ManagedAssemblyPipeline.buildCommand(for: zero, host: MegahitRuleHosts.appleSilicon).arguments
        XCTAssertEqual(MegahitRuleFixtures.value(after: "--memory", in: arguments), "1073741824")
        let record = ProvenanceBuilder.build(
            request: ran, result: try MegahitRuleFixtures.result(for: ran), inputRecords: [])
        XCTAssertEqual(record.parameters.memoryGB, 0)
    }
}

final class MegahitThreadRuleBundleConformanceTests: XCTestCase {
    func testBundleMetadataAndRecordOptionsHoldTheCountsOfTheRequestTheBuilderIsGiven() async throws {
        _ = try await ToolAvailability.require("bgzip", environment: "htslib")
        let scratch = try MegahitRuleFixtures.scratch("bundle")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let asked = MegahitRuleFixtures.request(
            threads: 8, memoryGB: 24, outputDirectory: scratch.appendingPathComponent("megahit-output"))
        let ran = asked.normalizedForExecution(on: MegahitRuleHosts.appleSilicon)
        let result = try MegahitRuleFixtures.result(for: ran)
        let provenance = ProvenanceBuilder.build(request: ran, result: result, inputRecords: [])

        let bundleURL = try await AssemblyBundleBuilder().build(
            result: result,
            request: ran,
            provenance: provenance,
            outputDirectory: scratch,
            bundleName: "Rule Pin"
        ) { _, _ in }

        let manifest = try BundleManifest.load(from: bundleURL)
        let parameters = try XCTUnwrap(manifest.metadata?.first { $0.name == "Assembly Parameters" })
        XCTAssertEqual(parameters.items.first { $0.label == "Threads" }?.value, "2")
        XCTAssertEqual(parameters.items.first { $0.label == "Memory" }?.value, "24 GB")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(envelope.options.explicit["threads"], .integer(2))
        XCTAssertEqual(envelope.options.explicit["memoryGB"], .integer(24))
    }
}
