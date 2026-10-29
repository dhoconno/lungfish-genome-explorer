// ClassifierReadResolverTests+StrandFix.swift - Extract refuses a NAO-MGS BAM made before the strand fix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane NAO-BAM-STALE (UX ruling UX-NAO-BAM-STALE, sections 4a, 5 and 6, tests T4 and T5). A NAO-MGS BAM whose
// header lacks `@PG ID:lungfish-naomgs-materializer` at VN:1.1 or later stores reverse-strand reads the wrong way
// round, so the estimate and the run refuse in words and write nothing. The check reads one header and changes no file.

import XCTest
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension ClassifierReadResolverTests {

    /// The words of the refusal for sample S1 (ruling 4a), spelled out so a change of wording fails this test.
    private static let strandFixRefusalWords =
        "The alignment file of sample 'S1' comes from an earlier NAO-MGS import, which stored reads that map to the "
        + "reverse strand the wrong way round, so Lungfish does not extract reads from it. Import the same NAO-MGS "
        + "results file again in the Import Center (NAO-MGS Results), then extract from the new result. "
        + "The counts and read IDs shown for this result are right."

    /// T4. At VN:1.0 the estimate and the run both refuse with the ruling's case and words, the output folder stays
    /// empty and no file of the result changes.
    func testNaoMgsExtractionRefusesABAMMadeBeforeTheStrandFix() async throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let rig = try makeStrandFixResult(version: "1.0", samtools: samtools)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let before = try strandFixDigests(of: rig.result)

        try await assertTheStaleBAMIsRefused(rig)

        XCTAssertEqual(try strandFixDigests(of: rig.result), before, "a refusal changes no file of the result")
    }

    /// T4's control. At VN:1.1 the same result extracts reads, so the refusal is the marker and not the fixture.
    func testNaoMgsExtractionReadsABAMMadeAfterTheStrandFix() async throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let rig = try makeStrandFixResult(version: "1.1", samtools: samtools)
        defer { try? FileManager.default.removeItem(at: rig.root) }

        let resolver = ClassifierReadResolver()
        let estimate = try await resolver.estimateReadCount(
            tool: .naomgs, resultPath: rig.resultPath, selections: rig.selections, options: ExtractionOptions()
        )
        XCTAssertGreaterThan(estimate, 0, "the estimate counts the reads of a BAM made after the fix")
        let outcome = try await resolver.resolveAndExtract(
            tool: .naomgs, resultPath: rig.resultPath, selections: rig.selections, options: rig.options,
            destination: .file(rig.output)
        )
        guard case .file(_, let readCount) = outcome else { return XCTFail("a file outcome, got \(outcome)") }
        XCTAssertGreaterThan(readCount, 0, "the run extracts reads at VN:1.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.output.path))
    }

    /// T5. The refusal only reads, so a result folder that nobody can write to (mode 0555) gives the same refusal and
    /// not a permission error.
    func testNaoMgsExtractionRefusesAStaleBAMInAReadOnlyResult() async throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let rig = try makeStrandFixResult(version: "1.0", samtools: samtools)
        let fm = FileManager.default
        let folders = [rig.result.appendingPathComponent("bams"), rig.result]
        defer {
            for folder in folders.reversed() { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            try? fm.removeItem(at: rig.root)
        }
        let before = try strandFixDigests(of: rig.result)
        for folder in folders { try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }

        try await assertTheStaleBAMIsRefused(rig)

        XCTAssertEqual(try strandFixDigests(of: rig.result), before, "a read-only result is left as it was")
    }

    // MARK: - Fixture

    private struct StrandFixRig {
        let root: URL
        let result: URL
        let output: URL
        var resultPath: URL { result.appendingPathComponent("hits.sqlite") }
        let selections = [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001"], taxIds: [])]
        let options = ExtractionOptions(
            format: .fastq,
            includeUnmappedMates: false,
            fileProvenance: ExtractionFileProvenance(
                workflowName: "lungfish app classifier read extraction",
                toolName: "Lungfish.app",
                argv: ["lungfish", "extract", "reads", "--by-classifier", "--tool", "naomgs", "--read-format", "fastq"],
                explicitOptions: ["tool": .string("naomgs"), "format": .string("fastq")],
                defaults: ["format": .string("fastq"), "includeUnmappedMates": .boolean(false)],
                resolved: ["samtoolsExcludeFlags": .integer(ExtractionOptions().samtoolsExcludeFlags)]
            )
        )
    }

    /// A project `Run.lungfish` holding the NAO-MGS result `Analyses/naomgs-run`, whose `bams/S1.bam` carries the
    /// materializer's `@PG` line at `version` and two reads on NC_001, and an empty output folder beside the project.
    private func makeStrandFixResult(version: String, samtools: String) throws -> StrandFixRig {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("strand-fix-\(UUID().uuidString)", isDirectory: true)
        let result = root.appendingPathComponent("Run.lungfish/Analyses/naomgs-run", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true).appendingPathComponent("reads.fastq")
        try fm.createDirectory(at: result.appendingPathComponent("bams"), withIntermediateDirectories: true)
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sam = root.appendingPathComponent("S1.sam")
        let text = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:NC_001\tLN:1000\n"
            + "@PG\tID:lungfish-naomgs-materializer\tPN:lungfish\tVN:\(version)\n"
            + "r1\t0\tNC_001\t10\t60\t20M\t*\t0\t0\tACGTACGTACGTACGTACGT\tIIIIIIIIIIIIIIIIIIII\n"
            + "r2\t16\tNC_001\t30\t60\t20M\t*\t0\t0\tTTGCATTGCATTGCATTGCA\tIIIIIIIIIIIIIIIIIIII\n"
        try text.write(to: sam, atomically: true, encoding: .utf8)
        let bam = result.appendingPathComponent("bams/S1.bam")
        try runStrandFixSamtools(samtools, ["sort", "-o", bam.path, sam.path])
        try runStrandFixSamtools(samtools, ["index", bam.path])
        return StrandFixRig(root: root, result: result, output: output)
    }

    /// The estimate and the run both throw the ruling's case, with its words, and the output folder stays empty.
    private func assertTheStaleBAMIsRefused(
        _ rig: StrandFixRig, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let refusal = ClassifierExtractionError.naoMgsBAMBeforeStrandFix(sampleId: "S1")
        let resolver = ClassifierReadResolver()
        do {
            let count = try await resolver.estimateReadCount(
                tool: .naomgs, resultPath: rig.resultPath, selections: rig.selections, options: ExtractionOptions()
            )
            XCTFail("the estimate refuses and counts nothing, it counted \(count)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ClassifierExtractionError, refusal, "the estimate threw \(error)", file: file, line: line)
            XCTAssertEqual(error.localizedDescription, Self.strandFixRefusalWords, file: file, line: line)
        }
        do {
            let outcome = try await resolver.resolveAndExtract(
                tool: .naomgs, resultPath: rig.resultPath, selections: rig.selections, options: rig.options,
                destination: .file(rig.output)
            )
            XCTFail("the run refuses and writes nothing, it returned \(outcome)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ClassifierExtractionError, refusal, "the run threw \(error)", file: file, line: line)
        }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: rig.output.deletingLastPathComponent().path)) ?? ["?"]
        XCTAssertEqual(written, [], "a refusal leaves the output folder empty", file: file, line: line)
    }

    /// The SHA-256 of every regular file under `folder`, keyed by its path inside the folder.
    private func strandFixDigests(of folder: URL) throws -> [String: String] {
        let fm = FileManager.default
        var digests: [String: String] = [:]
        guard let walker = fm.enumerator(atPath: folder.path) else { return digests }
        for case let relative as String in walker {
            let url = folder.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            digests[relative] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return digests
    }

    private func runStrandFixSamtools(_ samtools: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtools)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "samtools \(arguments.joined(separator: " ")) said: \(stderr)")
    }
}
