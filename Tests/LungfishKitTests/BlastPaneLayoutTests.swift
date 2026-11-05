// BlastPaneLayoutTests.swift - The BLAST pane cuts none of its words at the widths the walk used
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTWORDS, W-7 (the summary cut after "0..." at the default 1469-point window) and W-25 (the limit words of a failure
// cut after "Try again"). No network and no process. The tab is laid out at a width and each label must be tall enough for
// all of its words at the width Auto Layout gave it, so a label that truncates or clips fails whatever its design.

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import XCTest

@MainActor
final class BlastPaneLayoutTests: XCTestCase {
    /// The pane widths of the walk. The default 1469-point window gives the pane about 600 points, and the full-screen window
    /// gives it the rest. 360 stands for a pane squeezed beside the Inspector.
    private static let walkedWidths: [CGFloat] = [360, 520, 600, 900, 1469, 2056]

    private func sarsResult() -> BlastVerificationResult {
        let pair = BlastReadResult(id: "pair", verdict: .verified, otherMates: [BlastReadResult(id: "pair/2", verdict: .verified)])
        return BlastVerificationResult(
            taxonName: "Severe acute respiratory syndrome coronavirus 2 [tax adj: SARS-CoV-2_Gamma]", taxId: 2697049,
            readResults: [pair], submittedAt: Date(), completedAt: Date(), rid: "WALK6",
            blastProgram: "blastn", database: "core_nt", databaseSequenceCount: nil
        )
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub -> [NSTextField] in
            (sub as? NSTextField).map { [$0] + textFields(in: sub) } ?? textFields(in: sub)
        }
    }

    /// The height `field`'s words need when wrapped at `width`, whatever the field itself does with them.
    private func neededHeight(of field: NSTextField, atWidth width: CGFloat) -> CGFloat {
        let font = field.font ?? NSFont.systemFont(ofSize: 12)
        let box = (field.stringValue as NSString).boundingRect(
            with: NSSize(width: width, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        )
        return ceil(box.height)
    }

    // MARK: - W-7

    /// The counts sit after the sample, so a summary cut at a narrow pane lost them. Every word of the summary shows at each width.
    func testTheSummaryShowsEveryWordAtEachWalkedPaneWidth() throws {
        for width in Self.walkedWidths {
            let tab = BlastResultsDrawerTab(frame: NSRect(x: 0, y: 0, width: width, height: 420))
            tab.showResults(sarsResult(), recordURL: nil, subject: "SRR35517703")
            tab.layoutSubtreeIfNeeded()

            let label = tab.summaryLabel
            XCTAssertTrue(label.stringValue.contains("supporting"), "the summary lost its counts: \(label.stringValue)")
            let needed = neededHeight(of: label, atWidth: label.frame.width)
            XCTAssertGreaterThanOrEqual(
                label.frame.height + 0.5, needed,
                "At a pane \(Int(width)) points wide the summary is \(Int(label.frame.height)) points tall and needs \(Int(needed)), so it is cut: \(label.stringValue)"
            )
            let bar = try XCTUnwrap(label.superview)
            XCTAssertTrue(bar.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame), "At \(Int(width)) points the summary spills out of its bar")
        }
    }

    // MARK: - W-25

    private static let limitWords =
        "BLAST search failed: LGE's own limit stopped this search, and NCBI was not contacted. LGE sends at most 50 reads an hour, "
        + "and 44 have gone in the last hour. This search of 11 reads fits at 4:16 AM. Try again then, or send 6 or fewer reads now."

    /// The useful half of the limit words is the end. A failure pane shows all of them at each width.
    func testTheLimitWordsOfAFailureShowEveryLineAtEachWalkedPaneWidth() throws {
        for width in Self.walkedWidths {
            let tab = BlastResultsDrawerTab(frame: NSRect(x: 0, y: 0, width: width, height: 420))
            tab.showFailure(message: Self.limitWords)
            tab.layoutSubtreeIfNeeded()

            let label = try XCTUnwrap(textFields(in: tab).first { $0.stringValue == Self.limitWords }, "no label holds the words at \(Int(width)) points")
            let needed = neededHeight(of: label, atWidth: label.frame.width)
            XCTAssertGreaterThanOrEqual(
                label.frame.height + 0.5, needed,
                "At a pane \(Int(width)) points wide the failure words are \(Int(label.frame.height)) points tall and need \(Int(needed)), so the end is lost"
            )
            XCTAssertTrue(
                tab.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame),
                "At \(Int(width)) points the failure words spill out of the pane: \(label.frame)"
            )
        }
    }
}
