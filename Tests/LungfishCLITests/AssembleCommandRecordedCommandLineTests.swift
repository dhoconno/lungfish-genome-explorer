// AssembleCommandRecordedCommandLineTests.swift - assemble records its own command when a test runs it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// Row 424 of Phase 2.7, closed in Phase 2.8. `assemble` writes its record with the command line
/// it was given. A test runs the command inside another process, where `CommandLine.arguments` is
/// the test runner's, so the record must name the command that ran, as the one `esviritu detect`
/// records does. A stand-in SPAdes lets the whole command run.
final class AssembleCommandRecordedCommandLineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assemble-recorded-command")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testARunInThisProcessRecordsAssembleAndNotTheTestRunner() async throws {
        let spades = try StandInSPAdesConda(root: root.appendingPathComponent("tool", isDirectory: true))
        let reads = root.appendingPathComponent("sample.fastq")
        try "@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nACGTACGT\n+\nIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let command = try AssembleCommand.parse([
            reads.path, "--assembler", "spades", "--read-type", "illumina-short-reads",
            "--output", output.path, "--threads", "1", "--quiet",
        ])

        try await command.execute(pipeline: ManagedAssemblyPipeline(condaManager: spades.condaManager))

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(record.argv, [
            CLICommandIdentity.executableName, "assemble", reads.path, "--assembler", "spades",
            "--read-type", "illumina-short-reads", "--threads", "1", "--output", output.path,
        ])
    }

    /// The command line the process was started with names the command, so a run of the shipped
    /// binary records it as typed. Any other argv, such as the runner's, does not.
    func testACommandLineThatNamesTheCommandIsRecordedAsTyped() {
        let typed = ["/usr/local/bin/lungfish-cli", "assemble", "reads.fastq", "--assembler", "spades"]
        XCTAssertEqual(AssembleCommand.recordedCommandLine(typed, fallback: ["unused"]), typed)
        let runner = ["/usr/bin/xctest", "-XCTest", "AssembleCommandReadSetTests", "bundle.xctest"]
        XCTAssertEqual(AssembleCommand.recordedCommandLine(runner, fallback: ["lungfish-cli"]), ["lungfish-cli"])
    }

    /// The fallback spells out every option it was given, and a replay of it gives the same command.
    func testTheCanonicalCommandSpellsOutEveryOptionAndParsesBackToTheSame() throws {
        let cases: [(arguments: [String], canonical: [String])] = [
            (
                ["a_R1.fastq", "a_R2.fastq", "--paired", "--json-events", "--assembler", "spades",
                 "--read-type", "illumina-short-reads", "--project-name", "demo", "--threads", "4",
                 "--output", "/tmp/out", "--memory-gb", "8", "--min-contig-length", "500",
                 "--profile", "meta-sensitive", "--profile-basis", "chosen in the sheet",
                 "--extra-args", "--only-assembler", "--extra-arg", "--careful", "--format", "json"],
                [CLICommandIdentity.executableName, "assemble", "a_R1.fastq", "a_R2.fastq", "--paired", "--json-events",
                 "--assembler", "spades", "--read-type", "illumina-short-reads", "--project-name", "demo",
                 "--threads", "4", "--output", "/tmp/out", "--memory-gb", "8", "--min-contig-length", "500",
                 "--profile", "meta-sensitive", "--profile-basis", "chosen in the sheet",
                 "--extra-args", "--only-assembler", "--extra-arg", "--careful", "--format", "json"]
            ),
            (
                ["reads.fastq", "--read-layout", "interleaved"],
                [CLICommandIdentity.executableName, "assemble", "reads.fastq", "--read-layout", "interleaved"]
            ),
            (
                ["reads.fastq"],
                [CLICommandIdentity.executableName, "assemble", "reads.fastq"]
            ),
        ]
        for testCase in cases {
            let canonical = try AssembleCommand.parse(testCase.arguments).canonicalArguments()
            XCTAssertEqual(canonical, testCase.canonical)
            XCTAssertEqual(try AssembleCommand.parse(Array(canonical.dropFirst(2))).canonicalArguments(), canonical)
        }
    }
}

/// A conda root whose stand-in micromamba answers the version probes and runs a stand-in SPAdes
/// that writes one contig. `AssembleCommandReferenceBundleTests` runs it too.
struct StandInSPAdesConda {
    let condaManager: CondaManager

    init(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try Self.script.write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }

    private static let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "2.0.0"; exit 0; fi
        if [ "$1" != "run" ] || [ "$2" != "-n" ]; then echo "unexpected micromamba invocation: $*" >&2; exit 64; fi
        tool="$4"
        shift 4
        if [ "$tool" != "spades.py" ]; then echo "unexpected tool: $tool" >&2; exit 65; fi
        if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then echo "SPAdes 4.2.0"; exit 0; fi
        outdir=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then shift; outdir="$1"; fi
          shift
        done
        if [ -z "$outdir" ]; then echo "missing -o argument" >&2; exit 66; fi
        mkdir -p "$outdir"
        printf '>contig1\\nACGTACGTACGTACGTACGT\\n' > "$outdir/contigs.fasta"
        echo "SPAdes pipeline finished" > "$outdir/spades.log"
        exit 0
        """
}
