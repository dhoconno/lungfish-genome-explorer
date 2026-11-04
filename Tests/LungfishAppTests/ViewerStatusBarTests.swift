import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class ViewerStatusBarTests: XCTestCase {
    func testLongStatusTextDoesNotOverlapAtNarrowWidth() throws {
        let statusBar = ViewerStatusBar(frame: NSRect(x: 0, y: 0, width: 360, height: 24))

        statusBar.update(
            position: "MF0214_2__h2tg000003l_28523125_35203480:1-6680356",
            selection: "Visible: 1-6680356 (6,680,356 bp)",
            scale: 6680.4
        )
        statusBar.layoutSubtreeIfNeeded()

        let labels = allTextFields(in: statusBar)
        let positionLabel = try XCTUnwrap(labels.first { $0.accessibilityIdentifier() == "position-label" })
        let selectionLabel = try XCTUnwrap(labels.first { $0.accessibilityIdentifier() == "selection-label" })
        let scaleLabel = try XCTUnwrap(labels.first { $0.accessibilityIdentifier() == "scale-label" })

        XCTAssertLessThanOrEqual(positionLabel.frame.maxX, selectionLabel.frame.minX)
        XCTAssertLessThanOrEqual(selectionLabel.frame.maxX, scaleLabel.frame.minX)
    }

    /// The bar gives each label a third of its width and cuts a long sentence in the middle, so a refusal's file name,
    /// cause and next step can sit in the cut part. The tooltip is the whole text whichever way it was written, through
    /// `update` or straight into `stringValue`, and VoiceOver reads the same text.
    func testTheStatusBarKeepsAMessageWholeAsItsTooltipWhereverItIsWritten() throws {
        let bar = ViewerStatusBar(frame: NSRect(x: 0, y: 0, width: 900, height: 24))
        let sentence = "Unable to open the FASTQ for reads.fastq.gz. The drive Backup is not connected, so the file cannot be read. Connect it, then select the dataset again."
        bar.update(position: sentence, selection: nil, scale: 1)
        XCTAssertEqual(bar.positionLabel.toolTip, sentence, "a refusal through update keeps its whole text as the tooltip")

        let direct = "Unable to open the genotype result. Showing its workbook instead. The file is damaged."
        bar.positionLabel.stringValue = direct
        XCTAssertEqual(bar.positionLabel.toolTip, direct, "a direct write keeps its whole text too")
        XCTAssertEqual(bar.positionLabel.accessibilityValue(), direct, "VoiceOver reads a direct write too")

        let truncated = "Truncated: showing the first 5,000 of 12,000"
        bar.selectionLabel.stringValue = truncated
        XCTAssertEqual(bar.selectionLabel.toolTip, truncated, "the selection label keeps its whole text as the tooltip")
        XCTAssertEqual(bar.selectionLabel.accessibilityValue(), truncated, "VoiceOver reads the selection label's direct write")

        bar.positionLabel.stringValue = ""
        XCTAssertNil(bar.positionLabel.toolTip, "an empty label keeps no empty tooltip")

        let scaleLabel = try XCTUnwrap(allTextFields(in: bar).first { $0.accessibilityIdentifier() == "scale-label" })
        XCTAssertNil(scaleLabel.toolTip, "the scale label is short and keeps no tooltip that repeats it")
    }

    private func allTextFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview -> [NSTextField] in
            let current = (subview as? NSTextField).map { [$0] } ?? []
            return current + allTextFields(in: subview)
        }
    }
}
