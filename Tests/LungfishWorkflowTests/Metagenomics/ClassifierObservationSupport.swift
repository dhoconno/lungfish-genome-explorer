// ClassifierObservationSupport.swift - Stand-in classifier runs and masked captures of their records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane S36. Kraken2 and Bracken run on the fake tools of `FakeClassificationCondaFixture`. EsViritu runs
// on the stand-in below, the one `ClassifierLegacyRuns.StandInEsVirituConda` in LungfishAppTests uses, so these
// Workflow tests need no App target.

import Foundation
import XCTest
@testable import LungfishWorkflow
import LungfishTestSupport

/// A conda root whose stand-in micromamba answers a version probe and runs a stand-in EsViritu that writes an empty
/// detection table, with one small FASTQ sample to detect on.
struct StandInEsVirituRun {
    let root: URL
    let condaManager: CondaManager
    let config: EsVirituConfig

    init() throws {
        let fm = FileManager.default
        root = try TestTempDirectory.make(prefix: "esviritu-observation")
        let database = root.appendingPathComponent("esviritu-db", isDirectory: true)
        try fm.createDirectory(at: database, withIntermediateDirectories: true)
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try Self.script.write(to: micromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
        let input = root.appendingPathComponent("inputs/sample.fastq")
        try fm.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@sample-1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
        config = EsVirituConfig(
            inputFiles: [input],
            isPairedEnd: false,
            sampleName: "sample",
            outputDirectory: root.appendingPathComponent("Analyses/esviritu-batch/sample", isDirectory: true),
            databasePath: database,
            threads: 4,
            readFormat: .unpaired
        )
    }

    func remove() {
        TestTempDirectory.cleanup(root)
    }

    private static let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "micromamba 2.0.0"; exit 0; fi
        [ "$1" = "run" ] || { echo "unexpected micromamba invocation: $*" >&2; exit 64; }
        shift
        if [ "$1" = "-n" ]; then shift; shift; fi
        tool="$1"; shift
        [ "$tool" = "EsViritu" ] || { echo "unexpected tool: $tool" >&2; exit 64; }
        if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then echo "EsViritu 1.3.3"; exit 0; fi
        sample=""; output=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -s) shift; sample="$1" ;;
            -o) shift; output="$1" ;;
          esac
          shift
        done
        mkdir -p "$output"
        printf 'sample_ID\\tName\\tdescription\\tLength\\tSegment\\tAccession\\tAssembly\\tAsm_length\\tkingdom\\tphylum\\ttclass\\torder\\tfamily\\tgenus\\tspecies\\tsubspecies\\tRPKMF\\tread_count\\tcovered_bases\\tmean_coverage\\tavg_read_identity\\tPi\\tfiltered_reads_in_sample\\n' > "$output/$sample.detected_virus.info.tsv"
        echo "EsViritu stand-in finished" >&2
        exit 0
        """
}

/// The masked capture of the record a classifier run leaves in its output folder: the record's own key names, then
/// one line per step in record order with its tool name, its exit status and its key names. Every other value is
/// masked, because `ClassifierWriterFactsTests` pins the values of the same records.
enum ClassifierRecordCapture {
    /// The record's JSON object, read from the bytes the writer left.
    static func record(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The record's steps, in record order.
    static func steps(in directory: URL) throws -> [[String: Any]] {
        try XCTUnwrap(try record(in: directory)["steps"] as? [[String: Any]])
    }

    static func lines(in directory: URL) throws -> [String] {
        let record = try record(in: directory)
        let steps = try XCTUnwrap(record["steps"] as? [[String: Any]])
        return ["record: " + record.keys.sorted().joined(separator: ",")] + steps.map { step in
            let exit = step["exitStatus"].map { "\($0)" } ?? "none"
            return "\(step["toolName"] as? String ?? "?") exit=\(exit): " + step.keys.sorted().joined(separator: ",")
        }
    }

    /// Every key name anywhere in the record, at any depth, including the embedded legacy run.
    static func allKeyNames(in directory: URL) throws -> Set<String> {
        var names = Set<String>()
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                for (key, member) in object {
                    names.insert(key)
                    walk(member)
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(try record(in: directory))
        return names
    }

    /// Compares a capture, and on a difference prints the actual capture as Swift literals for review.
    static func assertLines(
        _ actual: [String],
        equal expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual, expected,
            "The masked capture differs. It reads\n" + actual.map { "\"\($0)\"," }.joined(separator: "\n"),
            file: file, line: line
        )
    }
}
