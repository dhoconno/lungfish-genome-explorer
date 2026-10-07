// FASTQBatchImporterFolderPairsTests.swift - Mates pair inside a folder first, and across folders only by unique names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Review B-S1 made a mate pair only with a file of its own folder, so two
/// folders that share file names never pair one folder's R1 with the other's
/// R2. Mates that sit in two folders, `R1/x_R1` and `R2/x_R2`, then imported
/// as two single-end samples, even with `--pairing paired`, and nothing said
/// why (re-review N1). Detection now pairs inside a folder first. An R1 with
/// no mate in its own folder pairs with another folder's mate only when no
/// other listed file has either name, so a name two folders share never
/// pairs across folders. A run's third file joins a pair of another folder
/// by the same rule. Detection reads names alone, so the files need not
/// exist.
final class FASTQBatchImporterFolderPairsTests: XCTestCase {

    // MARK: - Mates

    func testMatesInTwoFoldersPairWhenNoOtherListedFileHasTheirNames() {
        for (r1Name, r2Name, sample) in [
            ("x_R1.fastq.gz", "x_R2.fastq.gz", "x"),
            ("s_R1_001.fastq.gz", "s_R2_001.fastq.gz", "s"),
            ("SRR5_1.fq", "SRR5_2.fq", "SRR5"),
        ] {
            let r1 = Self.file("R1/\(r1Name)"), r2 = Self.file("R2/\(r2Name)")
            for files in [[r1, r2], [r2, r1]] {
                let samples = FASTQBatchImporter.detectPairs(from: files)
                XCTAssertEqual(samples.map(\.sampleName), [sample], "\(files.map(\.path))")
                XCTAssertEqual(samples.map(\.inputFiles), [[r1, r2]], "\(files.map(\.path))")
            }
        }
    }

    func testAMateInItsOwnFolderComesFirst() {
        let a1 = Self.file("A/x_R1.fastq"), a2 = Self.file("A/x_R2.fastq"), b2 = Self.file("B/x_R2.fastq")
        let samples = FASTQBatchImporter.detectPairs(from: [b2, a1, a2])
        XCTAssertEqual(samples.map(\.inputFiles), [[a1, a2], [b2]])
    }

    func testTheMatesOfTwoFoldersThatShareNamesPairInsideEachFolder() {
        // The review B-S1 layout. Each folder holds a whole pair.
        let a = [Self.file("A/reads_R1.fastq"), Self.file("A/reads_R2.fastq")]
        let b = [Self.file("B/reads_R1.fastq"), Self.file("B/reads_R2.fastq")]
        let samples = FASTQBatchImporter.detectPairs(from: a + b)
        XCTAssertEqual(samples.map(\.sampleName), ["reads", "reads"])
        XCTAssertEqual(samples.map(\.inputFiles), [a, b])
    }

    func testAMateNameTwoFoldersShareNeverPairsAcrossFolders() {
        let a1 = Self.file("A/reads_R1.fastq"), a2 = Self.file("A/reads_R2.fastq")
        let b1 = Self.file("B/reads_R1.fastq"), b2 = Self.file("B/reads_R2.fastq")
        let c1 = Self.file("C/reads_R1.fastq"), c2 = Self.file("C/reads_R2.fastq")
        for (files, expected) in [
            // An R1 alone in its folder, and two folders that hold its mate's name.
            ([a1, b2, c2], [[a1], [b2], [c2]]),
            // Two R1s alone in their folders, and one mate of another folder.
            ([a1, b1, c2], [[a1], [b1], [c2]]),
            // Folder A pairs inside itself, so B's R1 and C's R2 share names with A's mates.
            ([a1, a2, b1, c2], [[a1, a2], [b1], [c2]]),
        ] {
            let samples = FASTQBatchImporter.detectPairs(from: files)
            XCTAssertEqual(samples.map(\.inputFiles), expected, "\(files.map(\.path))")
        }
    }

    // MARK: - A run's third file

    func testARunsThirdFileInAnotherFolderJoinsWhenNoOtherListedFileHasItsNames() {
        let r1 = Self.file("A/SRR1_1.fastq"), r2 = Self.file("A/SRR1_2.fastq"), third = Self.file("B/SRR1.fastq")
        let samples = FASTQBatchImporter.detectPairs(from: [r1, r2, third])
        XCTAssertEqual(samples.map(\.inputFiles), [[r1, r2, third]])
        XCTAssertEqual(samples.first?.unpaired, third)

        // Mates of two folders, and the third file in a third.
        let m1 = Self.file("R1/SRR2_1.fastq.gz"), m2 = Self.file("R2/SRR2_2.fastq.gz"), u = Self.file("U/SRR2.fastq.gz")
        XCTAssertEqual(FASTQBatchImporter.detectPairs(from: [u, m2, m1]).map(\.inputFiles), [[m1, m2, u]])
    }

    func testARunsThirdFileOfANameTwoFoldersShareNeverJoinsAcrossFolders() {
        let a1 = Self.file("A/SRR1_1.fastq"), a2 = Self.file("A/SRR1_2.fastq"), a3 = Self.file("A/SRR1.fastq")
        let b1 = Self.file("B/SRR1_1.fastq"), b2 = Self.file("B/SRR1_2.fastq"), b3 = Self.file("B/SRR1.fastq")
        let c3 = Self.file("C/SRR1.fastq")
        for (files, expected) in [
            // Two folders hold the third file's name.
            ([a1, a2, b3, c3], [[a1, a2], [b3], [c3]]),
            // Two folders hold the pair's names.
            ([a1, a2, b1, b2, c3], [[a1, a2], [b1, b2], [c3]]),
            // A's third file joins A's pair, and B's pair takes nothing of another folder.
            ([a1, a2, a3, b1, b2], [[a1, a2, a3], [b1, b2]]),
        ] {
            let samples = FASTQBatchImporter.detectPairs(from: files)
            XCTAssertEqual(samples.map(\.inputFiles), expected, "\(files.map(\.path))")
        }
    }

    // MARK: - Notices

    func testANoticeNamesTheFilesThatANameTwoFoldersShareKeptApart() {
        let a1 = Self.file("A/reads_R1.fastq"), a2 = Self.file("A/reads_R2.fastq")
        let b1 = Self.file("B/reads_R1.fastq"), c2 = Self.file("C/reads_R2.fastq"), d2 = Self.file("D/reads_R2.fastq")

        XCTAssertEqual(FASTQBatchImporter.detectingPairs(from: [a1, a2, b1, c2]).notices, [
            FASTQBatchImporter.PairingNotice(
                sample: "reads_R1", r1: b1,
                message: "/runs/B/reads_R1.fastq was not paired with /runs/C/reads_R2.fastq, because mates pair "
                    + "across folders only when their names are unique among the listed files."
            ),
        ])
        // One R1 alone in its folder and the mate's name in two other folders.
        XCTAssertEqual(FASTQBatchImporter.detectingPairs(from: [b1, c2, d2]).notices.map(\.message), [
            "/runs/B/reads_R1.fastq was not paired with /runs/C/reads_R2.fastq or /runs/D/reads_R2.fastq, because "
                + "mates pair across folders only when their names are unique among the listed files.",
        ])
        // Two R1s alone in their folders, one notice each.
        XCTAssertEqual(
            FASTQBatchImporter.detectingPairs(from: [a1, b1, c2]).notices.map(\.r1), [a1, b1]
        )
    }

    func testANoticeNamesARunsFilesThatANameTwoFoldersShareKeptFromItsPair() {
        let r1 = Self.file("A/SRR1_1.fastq"), r2 = Self.file("A/SRR1_2.fastq")
        let b = Self.file("B/SRR1.fastq"), c = Self.file("C/SRR1.fastq")

        XCTAssertEqual(FASTQBatchImporter.detectingPairs(from: [r1, r2, b, c]).notices, [
            FASTQBatchImporter.PairingNotice(
                sample: "SRR1", r1: r1,
                message: "/runs/B/SRR1.fastq and /runs/C/SRR1.fastq were not joined to /runs/A/SRR1_1.fastq and "
                    + "/runs/A/SRR1_2.fastq as reads whose mate is missing, because a run's files join across "
                    + "folders only when their names are unique among the listed files."
            ),
        ])
    }

    func testNoNoticeWhenNoFileOfAnotherFolderWasLeftOut() {
        let a1 = Self.file("A/x_R1.fastq"), a2 = Self.file("A/x_R2.fastq")
        let b1 = Self.file("B/x_R1.fastq"), b2 = Self.file("B/x_R2.fastq")
        for files in [
            [a1, a2, b1, b2],
            [a1, b2],
            // B pairs inside itself, so no mate of another folder is free for A's R1.
            [a1, b1, b2],
            // One folder.
            [a1, a2, Self.file("A/x.fastq")],
        ] {
            XCTAssertEqual(FASTQBatchImporter.detectingPairs(from: files).notices, [], "\(files.map(\.path))")
        }
    }

    // MARK: - Helpers

    private static func file(_ path: String) -> URL {
        URL(fileURLWithPath: "/runs").appendingPathComponent(path)
    }
}
