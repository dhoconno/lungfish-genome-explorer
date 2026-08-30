import AppKit
import LungfishCore
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class AppIdentityPresentationTests: XCTestCase {

    private let preview = LungfishAppIdentity.preview

    func testPreviewApplicationMenuUsesPreviewIdentity() throws {
        let _ = NSApplication.shared
        let menu = MainMenu.createMainMenu(appIdentity: preview)
        let applicationMenu = try XCTUnwrap(menu.items.first?.submenu)

        XCTAssertEqual(menu.items.first?.title, "Lungfish Preview")
        XCTAssertNotNil(applicationMenu.items.first(where: {
            $0.title == "About Lungfish Genome Explorer Preview"
        }))
        XCTAssertNotNil(applicationMenu.items.first(where: {
            $0.title == "Hide Lungfish Genome Explorer Preview"
        }))
        XCTAssertNotNil(applicationMenu.items.first(where: {
            $0.title == "Quit Lungfish Genome Explorer Preview"
        }))
    }

    func testPreviewAboutWindowUsesPreviewIdentityAndCaveat() throws {
        let controller = AboutWindowController(appIdentity: preview)
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)

        XCTAssertEqual(window.title, "About Lungfish Genome Explorer Preview")
        XCTAssertTrue(root.descendantLabels().contains("Lungfish Genome Explorer Preview"))
        XCTAssertTrue(root.descendantLabels().contains(
            "Preview builds are under rapid iterative development. Features may be incomplete, change quickly, or require additional feedback."
        ))
    }

    func testPreviewDoesNotChangeChannelNeutralHelpIdentity() throws {
        let _ = NSApplication.shared
        let menu = MainMenu.createMainMenu(appIdentity: preview)
        let helpMenu = try XCTUnwrap(menu.items.first(where: { $0.title == "Help" })?.submenu)

        XCTAssertNotNil(helpMenu.items.first(where: { $0.title == "Lungfish Genome Explorer Help" }))
    }

    func testProvenanceFixtureKeepsChannelNeutralProductName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-identity-provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.fasta")
        try ">record\nAC\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let bundleURL = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: [">record\nAC\n"],
            suggestedName: "selected record",
            projectURL: root,
            durableSourceURLs: [sourceURL]
        )
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundleURL))

        XCTAssertEqual(envelope.steps.first?.argv.first, "Lungfish Genome Explorer")
    }
}

private extension NSView {
    func descendantLabels() -> [String] {
        let ownText = (self as? NSTextField).map { [$0.stringValue] } ?? []
        return ownText + subviews.flatMap { $0.descendantLabels() }
    }
}
