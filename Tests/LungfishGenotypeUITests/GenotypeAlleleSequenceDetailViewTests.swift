import AppKit
import XCTest
@testable import LungfishCore
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeAlleleSequenceDetailViewTests: XCTestCase {
    func testContentTypographyScalesSequenceReaderWithoutRerenderingOrLosingSelection() throws {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let view = GenotypeAlleleSequenceDetailView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        view.show(records: [makeRecord("A")])
        view.testingSelectFormat(.fasta)
        view.testingSelectedRange = NSRange(location: 2, length: 4)
        let baselineFont = view.testingTextFontPointSize
        let baselineText = view.renderedText
        let baselineRenderCount = view.testingRenderCount

        settings.contentTextSizePreference = .custom(200)
        settings.save()

        XCTAssertEqual(view.testingTextFontPointSize, baselineFont * 2, accuracy: 0.01)
        XCTAssertEqual(view.renderedText, baselineText)
        XCTAssertEqual(view.testingSelectedRange, NSRange(location: 2, length: 4))
        XCTAssertEqual(view.testingRenderCount, baselineRenderCount)

        settings.contentTextSizePreference = .custom(100)
        settings.save()

        XCTAssertEqual(view.testingTextFontPointSize, baselineFont, accuracy: 0.01)
        XCTAssertEqual(view.renderedText, baselineText)
        XCTAssertEqual(view.testingSelectedRange, NSRange(location: 2, length: 4))
        XCTAssertEqual(view.testingRenderCount, baselineRenderCount)
    }

    func testInitialStateIsEmptyAndDefaultsToGenBank() throws {
        let view = GenotypeAlleleSequenceDetailView(frame: .zero)

        XCTAssertEqual(view.accessibilityIdentifier(), "mhc-sequence-detail")
        XCTAssertEqual(view.currentFormat, .genBank)
        XCTAssertTrue(view.isEmpty)
        XCTAssertEqual(view.renderedText, "")

        let control = try formatControl(in: view)
        XCTAssertEqual(control.segmentCount, 3)
        XCTAssertEqual((0..<3).map(control.label(forSegment:)), ["GenBank", "FASTA", "EMBL"])
        XCTAssertEqual(control.selectedSegment, GenotypeAlleleSequenceDetailView.Format.genBank.rawValue)
        XCTAssertTrue(control.isHidden)
        XCTAssertEqual(try textView(in: view).string, "")
    }

    func testFirstSelectionShowsGenBankRecord() throws {
        let view = GenotypeAlleleSequenceDetailView(frame: .zero)
        let record = makeRecord("A")

        view.show(records: [record])

        XCTAssertFalse(view.isEmpty)
        XCTAssertFalse(try formatControl(in: view).isHidden)
        XCTAssertEqual(view.renderedText, record.genBankText)
        XCTAssertEqual(try textView(in: view).string, record.genBankText)
    }

    func testFormatToggleRendersSameRecordAsFASTAAndEMBL() {
        let view = GenotypeAlleleSequenceDetailView(frame: .zero)
        let record = makeRecord("A")
        view.show(records: [record])

        view.testingSelectFormat(.fasta)
        XCTAssertEqual(view.currentFormat, .fasta)
        XCTAssertEqual(view.renderedText, record.fastaText)

        view.testingSelectFormat(.embl)
        XCTAssertEqual(view.currentFormat, .embl)
        XCTAssertEqual(view.renderedText, record.emblText)

        view.testingSelectFormat(.genBank)
        XCTAssertEqual(view.currentFormat, .genBank)
        XCTAssertEqual(view.renderedText, record.genBankText)
    }

    func testMultipleRecordsRenderInInputOrderWithOneBlankLine() {
        let view = GenotypeAlleleSequenceDetailView(frame: .zero)
        let a = makeRecord("A")
        let b = makeRecord("B")
        let c = makeRecord("C")

        view.show(records: [c, a, b])

        XCTAssertEqual(
            view.renderedText,
            c.genBankText + "\n" + a.genBankText + "\n" + b.genBankText
        )
    }

    func testFormatPersistsAcrossSelectionChanges() {
        let view = GenotypeAlleleSequenceDetailView(frame: .zero)
        let a = makeRecord("A")
        let b = makeRecord("B")
        view.show(records: [a])
        view.testingSelectFormat(.embl)

        view.show(records: [b])

        XCTAssertEqual(view.currentFormat, .embl)
        XCTAssertEqual(view.renderedText, b.emblText)
    }

    func testResetForNewResultClearsAndRestoresGenBank() throws {
        let view = GenotypeAlleleSequenceDetailView(frame: .zero)
        view.show(records: [makeRecord("A")])
        view.testingSelectFormat(.fasta)

        view.resetForNewResult()

        XCTAssertEqual(view.currentFormat, .genBank)
        XCTAssertEqual(try formatControl(in: view).selectedSegment, 0)
        XCTAssertTrue(view.isEmpty)
        XCTAssertEqual(view.renderedText, "")
        XCTAssertTrue(try formatControl(in: view).isHidden)
    }

    func testClearRemovesVisibleContentWithoutChangingFormat() throws {
        let view = GenotypeAlleleSequenceDetailView(frame: .zero)
        view.show(records: [makeRecord("A")])
        view.testingSelectFormat(.fasta)

        view.clear()

        XCTAssertEqual(view.currentFormat, .fasta)
        XCTAssertTrue(view.isEmpty)
        XCTAssertEqual(view.renderedText, "")
        XCTAssertEqual(try textView(in: view).string, "")
        XCTAssertTrue(try formatControl(in: view).isHidden)
    }

    func testTextIsSelectableNoneditableMonospacedAndTracksReaderWidth() throws {
        let view = GenotypeAlleleSequenceDetailView(frame: .zero)
        let text = try textView(in: view)
        let scroll = try XCTUnwrap(text.enclosingScrollView)

        XCTAssertTrue(text.isSelectable)
        XCTAssertFalse(text.isEditable)
        XCTAssertFalse(text.isRichText)
        XCTAssertEqual(
            text.font?.fontName,
            NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                .fontName
        )
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertTrue(text.isVerticallyResizable)
        XCTAssertFalse(text.isHorizontallyResizable)
        XCTAssertTrue(text.textContainer?.widthTracksTextView ?? false)
    }

    func testSequenceReaderTracksResizedPaneWidthAndHeight() throws {
        let view = GenotypeAlleleSequenceDetailView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        let record = GenotypeAlleleSequenceRecord(
            identity: "resized",
            displayName: "resized",
            genBankText: String(repeating: "/qualifier=\"example\" ", count: 120),
            fastaText: ">resized\nACGT\n",
            emblText: "ID   resized\n"
        )

        view.show(records: [record])
        view.layoutSubtreeIfNeeded()
        let text = try textView(in: view)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let compactScrollHeight = scroll.frame.height

        view.frame.size = NSSize(width: 1_280, height: 720)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(text.frame.width, scroll.contentSize.width, accuracy: 1)
        XCTAssertGreaterThan(scroll.frame.height, compactScrollHeight)
        XCTAssertEqual(scroll.frame.height - compactScrollHeight, 360, accuracy: 1)
    }

    func testRepeatedUpdatesReuseOneStableHierarchy() throws {
        let view = GenotypeAlleleSequenceDetailView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 360)
        )
        let initialSubviews = allSubviews(of: view).count
        let initialConstraints = allConstraints(in: view).count

        for index in 0..<1_000 {
            switch index % 5 {
            case 0:
                view.clear()
            case 1:
                view.show(records: [makeRecord("A")])
            case 2:
                view.testingSelectFormat(.fasta)
            case 3:
                view.show(records: [makeRecord("B"), makeRecord("C")])
            default:
                view.testingSelectFormat(.embl)
            }
        }

        XCTAssertEqual(allSubviews(of: view).count, initialSubviews)
        XCTAssertEqual(allConstraints(in: view).count, initialConstraints)
        XCTAssertEqual(
            allSubviews(of: view).filter { $0 is NSSegmentedControl }.count,
            1
        )
        XCTAssertEqual(
            allSubviews(of: view).filter { $0 is NSTextView }.count,
            1
        )
    }

    private func makeRecord(_ suffix: String) -> GenotypeAlleleSequenceRecord {
        GenotypeAlleleSequenceRecord(
            identity: "id-\(suffix)",
            displayName: "allele-\(suffix)",
            genBankText: "GENBANK-\(suffix)\n",
            fastaText: ">FASTA-\(suffix)\nACGT\n",
            emblText: "EMBL-\(suffix)\n"
        )
    }

    private func formatControl(
        in root: NSView
    ) throws -> NSSegmentedControl {
        try XCTUnwrap(
            allSubviews(of: root).first {
                $0.accessibilityIdentifier() == "mhc-sequence-format"
            } as? NSSegmentedControl
        )
    }

    private func textView(in root: NSView) throws -> NSTextView {
        try XCTUnwrap(
            allSubviews(of: root).first {
                $0.accessibilityIdentifier() == "mhc-sequence-text"
            } as? NSTextView
        )
    }

    private func allSubviews(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    private func allConstraints(in root: NSView) -> [NSLayoutConstraint] {
        root.constraints + root.subviews.flatMap(allConstraints(in:))
    }
}
