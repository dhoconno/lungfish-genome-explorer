// CrossProjectFolderResultCopyTests+Refusals.swift - The words of the copier's refusals and what a cancel leaves behind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane COPYFOLDER, review COPYFOLDER-UX should-fix 1 and 2. Every refusal of the copier names its item first,
// says that the original is untouched and says what to try, and a person who imported a result is offered the import as well
// as the analysis. A cancel inside the byte comparison stays a cancel, and a cancel at any check leaves nothing in the
// target's `.tmp` folder under any name, and nothing in its `Analyses` folder.

import XCTest
import LungfishCore
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

extension CrossProjectFolderResultCopyTests {
    // MARK: - Words

    /// The six refusals share one voice. The record refusals offer the import as well as the analysis, since the item may
    /// have been imported, and the copy that differs names the usual causes of a source that changes during a copy.
    func testEveryRefusalOfTheCopierNamesTheItemAndWhatToTry() {
        let item = "nvd-100"
        let file = "hits.sqlite"
        let record: [CrossProjectItemCopier.CopyError] = [
            .recordFileMissing(item: item, file: file), .recordUnreadable(item: item), .recordDoesNotMatch(item: item, file: file),
            .recordLacksChecksum(item: item, file: file), .recordListsNoFile(item: item)
        ]
        for refusal in record + [.copyDiffers(item: item, file: file)] {
            let words = refusal.localizedDescription
            XCTAssertTrue(words.hasPrefix("\(item) was not copied."), words)
            XCTAssertTrue(words.contains("This copy changed nothing in the original"), words)
            XCTAssertTrue(words.contains("again"), "says what to try: \(words)")
            for punctuation in [":", ";", "\u{2014}", "\u{2013}"] {
                XCTAssertFalse(words.contains(punctuation), "\(punctuation) inside a sentence: \(words)")
            }
        }
        for refusal in record {
            let words = refusal.localizedDescription
            XCTAssertTrue(words.contains("analysis or import again"), "an imported result is offered the import: \(words)")
            XCTAssertFalse(words.contains("analysis again"), words)
        }
        let differs = CrossProjectItemCopier.CopyError.copyDiffers(item: item, file: file).localizedDescription
        XCTAssertTrue(differs.contains("\(file) in the copy does not match the original"), differs)
        XCTAssertTrue(differs.contains("room on its disk"), differs)
        XCTAssertTrue(differs.contains("nothing is writing to \(item)"), differs)
    }

    // MARK: - A cancel

    /// A cancel that the hash of a file asks for is a cancel and never a copy that differs. The last check of the
    /// comparison lies inside the hash of the last file, so the comparison throws there.
    func testACancelInsideTheByteComparisonIsNotARefusal() async throws {
        let source = try await buildWithRecord(.naoMgs)
        let files = try CrossProjectItemCopier.readSourceFiles(of: source, checkCancellation: {})
        let staged = root.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: source, to: staged)
        let record = ProvenanceRecorder.provenanceFilename
        let compared = files.filter { $0.path != record && $0.path != record + ".sig" }.count
        var total = 0
        try CrossProjectItemCopier.verifyStagedBytes(files, in: staged, item: source, checkCancellation: { total += 1 })
        XCTAssertGreaterThan(total, compared, "the hash of a file asks for a cancel as well as the file does")

        var calls = 0
        XCTAssertThrowsError(try CrossProjectItemCopier.verifyStagedBytes(files, in: staged, item: source, checkCancellation: {
            calls += 1
            if calls == total { throw CancellationError() }
        })) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertFalse(error is CrossProjectItemCopier.CopyError, "a cancel became a refusal: \(error)")
        }
        XCTAssertEqual(calls, total, "the cancel came from the last check")
    }

    /// A cancel at the first check, in the middle, just before the link rewrite and just before the item is published
    /// leaves no entry in the target's `.tmp` folder under any name and nothing in `Analyses`.
    func testACancelAtAnyCheckLeavesNothingInTmp() async throws {
        let source = try await buildWithRecord(.kraken2)
        let scratch = root.appendingPathComponent("Scratch.lungfish", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        var total = 0
        _ = try CrossProjectItemCopier.copy(itemAt: source, intoProject: scratch, identity: .neutral, checkCancellation: { total += 1 })
        XCTAssertGreaterThan(total, 4, "the copy asks for a cancel at several places")

        for stop in Set([1, total / 2, total - 1, total]).sorted() {
            var calls = 0
            XCTAssertThrowsError(try CrossProjectItemCopier.copy(
                itemAt: source, intoProject: targetProject, identity: .neutral,
                checkCancellation: {
                    calls += 1
                    if calls == stop { throw CancellationError() }
                }
            ), "a cancel at check \(stop) of \(total)") { error in
                XCTAssertTrue(error is CancellationError, "check \(stop): \(error)")
            }
            let temp = ProjectTempDirectory.tempRoot(for: targetProject)
            XCTAssertEqual((try? fm.contentsOfDirectory(atPath: temp.path)) ?? [], [], "check \(stop) left something in .tmp")
            try expectNothingLeftInTarget()
        }
    }
}
