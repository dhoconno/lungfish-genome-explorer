// ExtractReadsByClassifierCLITests+StaleNaoMgs.swift - extract reads --by-classifier refuses a stale NAO-MGS BAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane NAO-BAM-STALE (UX ruling UX-NAO-BAM-STALE, section 4a, test T6). The command runs the same resolver
// as the app, so it refuses a NAO-MGS BAM made before the strand fix with the same words, ends with an error and
// writes no output file.

import XCTest
import ArgumentParser
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

extension ExtractReadsByClassifierCLITests {

    func testExtractByClassifierRefusesAStaleNaoMgsBAMWithItsWords() async throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cli-stale-naomgs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let result = root.appendingPathComponent("Run.lungfish/Analyses/naomgs-run", isDirectory: true)
        try fm.createDirectory(at: result.appendingPathComponent("bams"), withIntermediateDirectories: true)

        // A BAM whose materializer line names VN:1.0, the version before the strand fix.
        let sam = root.appendingPathComponent("S1.sam")
        let text = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:NC_001\tLN:1000\n"
            + "@PG\tID:lungfish-naomgs-materializer\tPN:lungfish\tVN:1.0\n"
            + "r1\t16\tNC_001\t10\t60\t20M\t*\t0\t0\tACGTACGTACGTACGTACGT\tIIIIIIIIIIIIIIIIIIII\n"
        try text.write(to: sam, atomically: true, encoding: .utf8)
        let bam = result.appendingPathComponent("bams/S1.bam")
        try runSamtools(samtools, ["sort", "-o", bam.path, sam.path])
        try runSamtools(samtools, ["index", bam.path])

        let output = root.appendingPathComponent("cli-stale-out.fastq").standardizedFileURL
        let argv = [
            "--by-classifier",
            "--tool", "naomgs",
            "--result", result.path,
            "--sample", "S1",
            "--accession", "NC_001",
            "-o", output.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()
        do {
            try await cmd.run()
            XCTFail("Expected the refusal for a NAO-MGS BAM made before the strand fix")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The alignment file of sample 'S1' comes from an earlier NAO-MGS import, which stored reads that map to the "
                    + "reverse strand the wrong way round, so Lungfish does not extract reads from it. Import the same NAO-MGS "
                    + "results file again in the Import Center (NAO-MGS Results), then extract from the new result. "
                    + "The counts and read IDs shown for this result are right."
            )
        }
        XCTAssertFalse(fm.fileExists(atPath: output.path), "A refusal writes no output")
    }

    private func runSamtools(_ samtools: String, _ arguments: [String]) throws {
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
