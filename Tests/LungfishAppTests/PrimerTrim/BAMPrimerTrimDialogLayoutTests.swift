import AppKit
import SwiftUI
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp

/// The Output Track Name field had no visible label and was too narrow at the
/// sheet's default size, so the default name for the longest built-in scheme
/// was cut at "...with Boost".
@MainActor
final class BAMPrimerTrimDialogLayoutTests: XCTestCase {
    private static let longestDefaultName =
        "SRR36291587 minimap2 • Primer-trimmed (QIAseq Direct SARS-CoV-2 with Booster A)"

    private var temporaryURL: URL?

    override func tearDown() async throws {
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        try await super.tearDown()
    }

    func testOutputTrackNameFieldIsLabelledAndShowsTheLongestDefaultNameWhole() throws {
        let state = BAMPrimerTrimDialogState(
            bundle: makeStubReferenceBundle(),
            availability: .available,
            builtInSchemes: [],
            projectSchemes: []
        )
        state.outputTrackName = Self.longestDefaultName

        let host = NSHostingView(rootView: BAMPrimerTrimDialog(
            state: state, onCancel: {}, onRun: {}, onBrowseScheme: {}
        ))
        let size = BAMPrimerTrimDialog.defaultSheetSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(
            allSubviews(of: host).compactMap { $0 as? NSTextField }
                .first { $0.isEditable && $0.stringValue == Self.longestDefaultName },
            "the output track name field must be hosted as an editable text field"
        )
        let font = field.font ?? NSFont.systemFont(ofSize: BAMPrimerTrimToolPanes.labelFontSize)
        let textWidth = (Self.longestDefaultName as NSString).size(withAttributes: [.font: font]).width
        let textRect = field.cell?.drawingRect(forBounds: field.bounds) ?? field.bounds
        XCTAssertGreaterThanOrEqual(
            textRect.width, ceil(textWidth),
            "the default name (\(textWidth)pt) must fit the field (\(textRect.width)pt) at the default sheet size"
        )

        // SwiftUI's Text and .help are not visible to AppKit in a headless
        // host, so the label is checked by the room it takes: the old field
        // had no label and started at the pane's leading inset.
        XCTAssertEqual(BAMPrimerTrimToolPanes.outputTrackFieldLabel, "Output Track Name")
        let labelWidth = (BAMPrimerTrimToolPanes.outputTrackFieldLabel as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: BAMPrimerTrimToolPanes.labelFontSize)]).width
        let fieldInHost = field.convert(field.bounds, to: host)
        XCTAssertGreaterThan(fieldInHost.minX, labelWidth,
                             "the label sits to the left of the field, so the field starts after it")
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func makeStubReferenceBundle() -> ReferenceBundle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMPrimerTrimDialogLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURL = url
        let manifest = BundleManifest(
            name: "Stub",
            identifier: "stub.test",
            source: SourceInfo(organism: "Virus", assembly: "StubAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/ref.fa",
                indexPath: "genome/ref.fa.fai",
                totalLength: 1000,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 1000, offset: 0, lineBases: 60, lineWidth: 61)
                ]
            ),
            variants: [],
            alignments: []
        )
        return ReferenceBundle(url: url, manifest: manifest)
    }
}
