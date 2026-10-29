// NaoMgsBamOrientationTests.swift - Telling a NAO-MGS BAM made before the strand fix by its header
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane NAO-BAM-STALE (UX ruling UX-NAO-BAM-STALE, section 3 "The marker rule", tests T1 and T2). Since lane
// NAO-BAM-ORIENT the materializer stores every 0x10 record on the reference strand and writes
// `@PG ID:lungfish-naomgs-materializer ... VN:1.1`. A BAM with VN:1.0, or with no such line, was made before that
// fix, and its orientation is unknown, so it counts as made before the fix.

import XCTest
import LungfishTestSupport
@testable import LungfishIO

final class NaoMgsBamOrientationTests: XCTestCase {

    /// A BAM header with the materializer's line at `materializerVersion` (none when nil) and the line samtools adds,
    /// whose own version must never count.
    private func header(materializerVersion: String?) -> String {
        var text = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:NC_001\tLN:1000\n"
        if let materializerVersion {
            text += "@PG\tID:lungfish-naomgs-materializer\tPN:lungfish\tVN:\(materializerVersion)\n"
        }
        text += "@PG\tID:samtools\tPN:samtools\tPP:lungfish-naomgs-materializer\tVN:9.9\tCL:samtools sort -o x.bam\n"
        return text
    }

    func testOrientationReadsTheMaterializerVersionFromTheHeader() {
        XCTAssertEqual(
            NaoMgsBamMaterializer.orientation(ofHeader: header(materializerVersion: "1.0")), .beforeStrandFix,
            "VN:1.0 is the version before the fix"
        )
        XCTAssertEqual(
            NaoMgsBamMaterializer.orientation(ofHeader: header(materializerVersion: nil)), .beforeStrandFix,
            "a header with no materializer line has an unknown orientation, and a refusal states no false fact"
        )
        XCTAssertEqual(NaoMgsBamMaterializer.orientation(ofHeader: ""), .beforeStrandFix, "an empty header is refused too")
        for version in ["1.1", "1.10", "2.0"] {
            XCTAssertEqual(
                NaoMgsBamMaterializer.orientation(ofHeader: header(materializerVersion: version)), .referenceStrand,
                "VN:\(version) is the fix or later, compared as numbers and never as a string"
            )
        }
        XCTAssertEqual(
            NaoMgsBamMaterializer.orientation(ofHeader: header(materializerVersion: NaoMgsBamMaterializer.headerVersion)),
            .referenceStrand,
            "the version the writer puts in the header is the version the check accepts"
        )
    }

    /// The check reads a real header through samtools, and a file samtools cannot read throws, so a caller never takes
    /// it for a BAM made before the fix.
    func testOrientationOfABAMBuiltFromSAMTextFollowsItsVersion() throws {
        guard let samtools = BamFixtureBuilder.locateSamtools() else {
            try ToolAvailability.skipOrFail("samtools is not installed")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsOrientation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let expected: [(version: String, orientation: NaoMgsBamOrientation)] = [
            ("1.0", .beforeStrandFix), ("1.1", .referenceStrand),
        ]
        for (version, orientation) in expected {
            let sam = folder.appendingPathComponent("v\(version).sam")
            let reads = "r1\t0\tNC_001\t10\t60\t20M\t*\t0\t0\tACGTACGTACGTACGTACGT\tIIIIIIIIIIIIIIIIIIII\n"
            try (header(materializerVersion: version) + reads).write(to: sam, atomically: true, encoding: .utf8)
            let bam = folder.appendingPathComponent("v\(version).bam")
            try runSamtools(samtools, ["sort", "-o", bam.path, sam.path])
            XCTAssertEqual(
                try NaoMgsBamMaterializer.orientation(ofBAM: bam, samtoolsPath: samtools), orientation,
                "a BAM built with VN:\(version)"
            )
        }
        let notABAM = folder.appendingPathComponent("not.bam")
        try Data([0x1F, 0x8B]).write(to: notABAM)
        XCTAssertThrowsError(
            try NaoMgsBamMaterializer.orientation(ofBAM: notABAM, samtoolsPath: samtools),
            "a header samtools cannot read is an error, never a stale BAM"
        )
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
