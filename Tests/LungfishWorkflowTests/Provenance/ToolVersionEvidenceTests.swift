// ToolVersionEvidenceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Pure checks on the stored-string classifier and on `recordedString`, which must equal
// what today's writers record for every value Phase 2.5 inventory C lists.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ToolVersionEvidenceTests: XCTestCase {
    private typealias Reason = ToolVersionEvidence.Reason

    private let libmambaLine = "critical libmamba The given prefix does not exist: \"<root>/conda/envs/bbmap\""
    private let lofreqLine = "FATAL(lofreq_main.c|main:336): Unrecognized command '--version'"

    // MARK: Classification

    func testLegacyUnknownSpellingsClassifyAsUnknown() {
        let table: [(String?, Reason)] = [
            (nil, .noProbe),
            ("", .legacySpelling("")),
            ("   ", .legacySpelling("")),
            ("unknown", .legacySpelling("unknown")),
            ("Unknown", .legacySpelling("Unknown")),
            (" unknown\n", .legacySpelling("unknown")),
            ("unresolved", .legacySpelling("unresolved")),
            ("unavailable", .legacySpelling("unavailable")),
            ("n/a", .legacySpelling("n/a")),
            ("N/A", .legacySpelling("N/A")),
            ("system", .legacySpelling("system")),
        ]
        for (recorded, reason) in table {
            let evidence = ToolVersionEvidence.classify(recorded: recorded)
            XCTAssertEqual(evidence, .unknown(reason), "\(String(describing: recorded))")
            XCTAssertTrue(evidence.isUnknown)
            XCTAssertNil(evidence.version)
        }
    }

    func testProbeErrorLinesClassifyAsRecordedProbeErrors() {
        let table = [
            libmambaLine,
            "ERROR: unknown command",
            lofreqLine,
            "Usage: samtools <command> [options]",
            "unrecognized option '--version'",
            "error: no such option",
        ]
        for line in table {
            XCTAssertEqual(ToolVersionEvidence.classify(recorded: line), .unknown(.recordedProbeError(line)), line)
        }
    }

    func testVersionsClassifyAsObservedWithTheStoredText() {
        let table = [
            "1.24", "2.31", "2.17.1", "0.24.0", "3.1.5", "3.3.0+lge.5", "2.31-r1302", "4.6.1.0",
            "sra-tools 3.4.1", "lungfish-cli 2026.10.10", "Lungfish 2026.10.10 (dev)", "dev (0)", "v1.3.3",
        ]
        for version in table {
            let evidence = ToolVersionEvidence.classify(recorded: version)
            XCTAssertEqual(evidence, .observed(version: version, reportedLine: nil), version)
            XCTAssertFalse(evidence.isUnknown)
            XCTAssertEqual(evidence.version, version)
        }
    }

    func testCompositeTextIsClassifiedByItsVersionPart() {
        let withPackage = "1.24 (managed conda environment samtools; executable samtools; package bioconda::samtools=1.24=h36b3a25_1)"
        let withoutPackage = "2.31 (managed conda environment minimap2; executable minimap2)"
        let note = "1.2 (bundled executable /opt/x/bin/tool)"
        XCTAssertEqual(ToolVersionEvidence.classify(recorded: withPackage), .observed(version: "1.24", reportedLine: nil))
        XCTAssertEqual(ToolVersionEvidence.classify(recorded: withoutPackage), .observed(version: "2.31", reportedLine: nil))
        XCTAssertEqual(ToolVersionEvidence.classify(recorded: note), .observed(version: "1.2", reportedLine: nil))
        XCTAssertEqual(
            ToolVersionEvidence.classify(recorded: "unknown (managed conda environment minimap2; executable minimap2)"),
            .unknown(.legacySpelling("unknown"))
        )
        XCTAssertEqual(
            ToolVersionEvidence.classify(recorded: "\(libmambaLine) (managed conda environment bbtools; executable bbmap.sh)"),
            .unknown(.recordedProbeError(libmambaLine))
        )
    }

    // MARK: recordedString

    /// Every value a writer can hand to `toolVersion`, with the string the record holds. The
    /// stored string is what `ProvenanceVersion.required` makes of the value (nil, empty and
    /// blank become `unknown`), and classifying the stored string and printing it again gives it back.
    func testRecordedStringEqualsWhatWritersRecordForEveryInventoryValue() {
        let writerValues: [String?] = [
            nil, "", "unknown", "unresolved", "unavailable", "n/a", "system",
            libmambaLine, lofreqLine, "ERROR: unknown command",
            "1.24", "2.31", "2.17.1", "40.02", "3.3.0+lge.5", "0.24.0", "3.1.5", "1.2.0", "1.23.1", "3.0.0", "0.1.0",
            "sra-tools 3.4.1", "Lungfish 2026.10.10 (dev)", "lungfish-cli 2026.10.10", "NCBI E-utilities API",
        ]
        for value in writerValues {
            let stored = ProvenanceVersion.required(value)
            XCTAssertEqual(ToolVersionEvidence.classify(recorded: value).recordedString, stored, "\(String(describing: value))")
            XCTAssertEqual(ToolVersionEvidence.classify(recorded: stored).recordedString, stored, stored)
        }
    }

    func testRecordedStringOfTheCompositeIsItsVersionPart() {
        let composites = [
            ("1.24", "1.24 (managed conda environment samtools; executable samtools; package bioconda::samtools=1.24=h36b3a25_1)"),
            ("2.31", "2.31 (managed conda environment minimap2; executable minimap2)"),
            ("40.02", "40.02 (managed conda environment bbtools; executable bbmap.sh; package bioconda::bbmap=40.02=he046917_0)"),
            ("2.1.5", "2.1.5 (managed conda environment lofreq; executable lofreq; package lofreq)"),
            ("unknown", "unknown (managed conda environment minimap2; executable minimap2)"),
        ]
        for (version, composite) in composites {
            XCTAssertEqual(ToolVersionEvidence.classify(recorded: composite).recordedString, version, composite)
        }
    }

    func testEvidenceWithoutStoredTextIsRecordedAsUnknown() {
        for reason in [Reason.noProbe, .probeFailed, .outputUnparseable] {
            XCTAssertEqual(ToolVersionEvidence.unknown(reason).recordedString, "unknown")
        }
        XCTAssertEqual(ToolVersionEvidence.observed(version: "2.31", reportedLine: "2.31-r1302").recordedString, "2.31")
    }

    // MARK: Lock pins

    func testLockPinRecordsTheLockVersionForEveryEntry() {
        let lock = ManagedToolLock.bundled
        XCTAssertEqual(lock.entries.count, 44)
        for entry in lock.entries {
            let evidence = ToolVersionEvidence.lockPin(for: entry.id, in: lock)
            XCTAssertEqual(evidence, .lockPin(version: entry.version ?? "", id: entry.id), entry.id.rawValue)
            XCTAssertEqual(evidence.recordedString, entry.version, entry.id.rawValue)
            XCTAssertFalse(evidence.isUnknown)
        }
    }

    func testLockPinForAnIdTheLockLacksIsUnknown() {
        XCTAssertEqual(ToolVersionEvidence.lockPin(for: ManagedToolID(rawValue: "bbmap")), .unknown(.noProbe))
        XCTAssertEqual(
            ToolVersionEvidence.lockPin(for: ManagedToolID(rawValue: "sra-tools")),
            .lockPin(version: "3.4.1", id: ManagedToolID(rawValue: "sra-tools"))
        )
    }
}
