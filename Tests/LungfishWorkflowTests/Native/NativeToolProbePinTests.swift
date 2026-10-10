// NativeToolProbePinTests.swift - Freeze of NativeTool executables, version argv and environments
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Pins the facts a probe table must reproduce for every `NativeTool` case. The runner's own
/// tests run only in the conformance tier, so this pure class carries the unit-tier guard.
final class NativeToolProbePinTests: XCTestCase {
    private struct Row {
        let executable: String
        let versionArguments: [String]
        let environment: String
    }

    private static let table: [String: Row] = [
        "samtools": Row(executable: "samtools", versionArguments: ["--version"], environment: "samtools"),
        "bcftools": Row(executable: "bcftools", versionArguments: ["--version"], environment: "bcftools"),
        "bgzip": Row(executable: "bgzip", versionArguments: ["--version"], environment: "htslib"),
        "tabix": Row(executable: "tabix", versionArguments: ["--version"], environment: "htslib"),
        "bedGraphToBigWig": Row(executable: "bedGraphToBigWig", versionArguments: ["--version"], environment: "ucsc-bedgraphtobigwig"),
        "pigz": Row(executable: "pigz", versionArguments: ["--version"], environment: "pigz"),
        "seqkit": Row(executable: "seqkit", versionArguments: ["version"], environment: "seqkit"),
        "fastp": Row(executable: "fastp", versionArguments: ["--version"], environment: "fastp"),
        "vsearch": Row(executable: "vsearch", versionArguments: ["--version"], environment: "vsearch"),
        "blastn": Row(executable: "blastn", versionArguments: ["-version"], environment: "blast"),
        "cutadapt": Row(executable: "cutadapt", versionArguments: ["--version"], environment: "cutadapt"),
        "trimGalore": Row(executable: "trim_galore", versionArguments: ["--version"], environment: "trim_galore"),
        "ribodetector": Row(executable: "ribodetector_cpu", versionArguments: ["-v"], environment: "ribodetector"),
        "clumpify": Row(executable: "clumpify.sh", versionArguments: ["--version"], environment: "bbtools"),
        "bbduk": Row(executable: "bbduk.sh", versionArguments: ["--version"], environment: "bbtools"),
        "bbmerge": Row(executable: "bbmerge.sh", versionArguments: ["--version"], environment: "bbtools"),
        "repair": Row(executable: "repair.sh", versionArguments: ["--version"], environment: "bbtools"),
        "tadpole": Row(executable: "tadpole.sh", versionArguments: ["--version"], environment: "bbtools"),
        "reformat": Row(executable: "reformat.sh", versionArguments: ["--version"], environment: "bbtools"),
        "bbmap": Row(executable: "bbmap.sh", versionArguments: ["--version"], environment: "bbtools"),
        "mapPacBio": Row(executable: "mapPacBio.sh", versionArguments: ["--version"], environment: "bbtools"),
        "fasterqDump": Row(executable: "fasterq-dump", versionArguments: ["--version"], environment: "sra-tools"),
        "prefetch": Row(executable: "prefetch", versionArguments: ["--version"], environment: "sra-tools"),
        "deacon": Row(executable: "deacon", versionArguments: ["--version"], environment: "deacon"),
        "lofreq": Row(executable: "lofreq", versionArguments: ["version"], environment: "lofreq"),
        "ivar": Row(executable: "ivar", versionArguments: ["version"], environment: "ivar"),
        "medaka": Row(executable: "medaka", versionArguments: ["--version"], environment: "medaka"),
        "medakaVariant": Row(executable: "medaka_variant", versionArguments: ["--version"], environment: "medaka"),
        "clair3": Row(executable: "run_clair3.sh", versionArguments: ["--version"], environment: "clair3"),
        "whatshap": Row(executable: "whatshap", versionArguments: ["--version"], environment: "phasing"),
        "freyja": Row(executable: "freyja", versionArguments: ["--version"], environment: "freyja"),
    ]

    func testTableKeysEqualTheNativeToolCaseSet() {
        XCTAssertEqual(Self.table.count, 31)
        XCTAssertEqual(Set(NativeTool.allCases.map(\.rawValue)), Set(Self.table.keys))
    }

    func testExecutableNameForEveryCase() {
        for tool in NativeTool.allCases {
            XCTAssertEqual(tool.executableName, Self.table[tool.rawValue]?.executable, "executable of \(tool.rawValue)")
        }
    }

    func testVersionArgumentsForEveryCase() {
        for tool in NativeTool.allCases {
            XCTAssertEqual(tool.versionArguments, Self.table[tool.rawValue]?.versionArguments, "version argv of \(tool.rawValue)")
        }
    }

    func testManagedEnvironmentAndExecutableForEveryCase() {
        for tool in NativeTool.allCases {
            guard let row = Self.table[tool.rawValue] else {
                XCTFail("no row for \(tool.rawValue)")
                continue
            }
            XCTAssertEqual(
                tool.location,
                .managed(environment: row.environment, executableName: row.executable),
                "location of \(tool.rawValue)"
            )
            XCTAssertFalse(tool.isBundled, tool.rawValue)
        }
    }
}
