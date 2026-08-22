import XCTest
import ViewInspector
@testable import LungfishApp
import LungfishKit

final class IQTreeInferenceOptionsDialogTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    @MainActor
    private func makeDialog() -> IQTreeInferenceDialog {
        let request = MultipleSequenceAlignmentTreeInferenceRequest(
            bundleURL: URL(fileURLWithPath: "/project/Analyses/Multiple Sequence Alignments/alignment.lungfishmsa"),
            rows: "seq1,seq2",
            columns: "10-200",
            suggestedName: "alignment-tree.lungfishtree",
            displayName: "alignment"
        )
        let state = IQTreeInferenceDialogState(
            request: request,
            projectURL: URL(fileURLWithPath: "/project")
        )
        return IQTreeInferenceDialog(state: state, onCancel: {}, onRun: {})
    }

    @MainActor
    func testIQTreeInferenceDialogExposesCuratedAndAdvancedOptions() throws {
        let inspected = try makeDialog().inspect()

        // Converted from source-text grep to behavioral assertions: every curated and
        // advanced-option label below is proven to actually render in the live tree.
        for label in [
            "Sequence Type",
            "Ultrafast Bootstrap",
            "SH-aLRT",
            "Safe numerical mode",
            "Keep identical sequences",
            "Advanced Options",
        ] {
            _ = try inspected.find(text: label)
        }
        _ = try inspected.find(text: "Branch Support")
        _ = try inspected.find(viewWithAccessibilityIdentifier: "iqtree-options-advanced-parameters")
    }

    @MainActor
    func testIQTreeInferenceDialogExposesScopeAndExecutableOverride() throws {
        let inspected = try makeDialog().inspect()

        // Converted from source-text grep to behavioral assertions: the scope summary
        // and executable-override field both render with their stable accessibility
        // identifiers. `.accessibilityIdentifier("iqtree-options-executable-path")` is
        // chained onto `labeledTextField(...)`'s returned HStack (Text + TextField), so
        // the identifier lands on that HStack; its first child is the real
        // "IQ-TREE Executable" label.
        _ = try inspected.find(viewWithAccessibilityIdentifier: "iqtree-options-scope")
        let executableGroup = try inspected
            .find(viewWithAccessibilityIdentifier: "iqtree-options-executable-path")
            .hStack()
        XCTAssertEqual(try executableGroup.text(0).string(), "IQ-TREE Executable")
    }

    func testMSATreeInferenceRoutesThroughDialogBeforeRunner() throws {
        let sourceURL = repositoryRoot.appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // runIQTreeInferenceViaCLI is a private method on ViewerViewController with no
        // testing-prefixed wrapper (unlike AppDelegate's testing* convention), and the
        // routing decision only manifests by presenting a real NSPanel sheet
        // (IQTreeInferenceDialogPresenter.present calls window.beginSheet), which has no
        // safe, deterministic runtime seam to assert against without adding one.
        XCTAssertTrue(source.contains("IQTreeInferenceDialogPresenter.present"))
        XCTAssertFalse(source.contains("IQTreeInferenceOptionsDialog.present"))
        XCTAssertTrue(source.contains("runIQTreeInferenceViaCLI"))
    }

    @MainActor
    func testIQTreeInferenceUsesDatasetOperationsSheetInsteadOfAlertAccessory() throws {
        let inspected = try makeDialog().inspect()

        // Converted from source-text grep to behavioral assertions: the dialog's title,
        // subtitle-derived tool label, and advanced-options disclosure all actually
        // render, and the disclosure's default expanded state genuinely follows
        // AppUITestConfiguration rather than being hardcoded.
        _ = try inspected.find(text: "Phylogenetic Tree Operations")
        _ = try inspected.find(text: "Build Tree with IQ-TREE")
        _ = try inspected.find(viewWithAccessibilityIdentifier: "iqtree-options-advanced-disclosure")

        let request = MultipleSequenceAlignmentTreeInferenceRequest(
            bundleURL: URL(fileURLWithPath: "/project/alignment.lungfishmsa"),
            rows: nil,
            columns: nil,
            suggestedName: "tree.lungfishtree",
            displayName: "alignment"
        )
        let state = IQTreeInferenceDialogState(
            request: request,
            projectURL: URL(fileURLWithPath: "/project")
        )
        XCTAssertEqual(state.advancedOptionsExpanded, AppUITestConfiguration.current.isEnabled)

        // "No NSAlert/accessoryView anywhere in this file" is a dead-API-absence check
        // with no positive runtime equivalent (there's nothing to instantiate to prove a
        // *lack* of a call site) -- kept as a source check.
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialog.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("NSAlert"))
        XCTAssertFalse(source.contains("accessoryView"))
    }

    func testIQTreeInferencePresenterUsesOperationsPanelSizing() throws {
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialogPresenter.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // IQTreeInferenceDialogPresenter.present(from:) constructs a real NSPanel with an
        // observable contentSize, but calling it requires a real NSWindow that can host
        // an actual beginSheet(_:) presentation -- there is no existing safe/deterministic
        // pattern for this in the suite (window ordering / NSApp state), so exercising it
        // is out of scope for this task.
        XCTAssertTrue(source.contains("NSPanel"))
        XCTAssertTrue(source.contains("setContentSize(NSSize(width: 980, height: 700))"))
        XCTAssertTrue(source.contains("window.beginSheet(panel)"))
        XCTAssertFalse(source.contains("NSAlert"))
    }

    @MainActor
    func testIQTreeInferenceDialogStateProducesOptionsForRunner() throws {
        let request = MultipleSequenceAlignmentTreeInferenceRequest(
            bundleURL: URL(fileURLWithPath: "/project/Analyses/Multiple Sequence Alignments/alignment.lungfishmsa"),
            rows: "seq1,seq2",
            columns: "10-200",
            suggestedName: "alignment-tree.lungfishtree",
            displayName: "alignment"
        )
        let state = IQTreeInferenceDialogState(
            request: request,
            projectURL: URL(fileURLWithPath: "/project")
        )

        state.model = "GTR+G"
        state.sequenceType = .dna
        state.bootstrapEnabled = true
        state.bootstrapReplicates = 500
        state.alrtEnabled = true
        state.alrtReplicates = 1000
        state.seed = 42
        state.threads = 4
        state.safeMode = true
        state.keepIdenticalSequences = true
        state.iqtreePath = "/opt/iqtree/bin/iqtree2"
        state.extraIQTreeOptions = "-bnni"
        state.prepareForRun()

        let options = try XCTUnwrap(state.pendingOptions)
        XCTAssertEqual(options.outputName, "alignment-tree")
        XCTAssertEqual(options.model, "GTR+G")
        XCTAssertEqual(options.sequenceType, "DNA")
        XCTAssertEqual(options.bootstrap, 500)
        XCTAssertEqual(options.alrt, 1000)
        XCTAssertEqual(options.seed, 42)
        XCTAssertEqual(options.threads, 4)
        XCTAssertTrue(options.safeMode)
        XCTAssertTrue(options.keepIdenticalSequences)
        XCTAssertEqual(options.iqtreePath, "/opt/iqtree/bin/iqtree2")
        XCTAssertEqual(options.extraIQTreeOptions, "-bnni")
        XCTAssertTrue(state.scopeSummary.contains("2 rows"))
        XCTAssertTrue(state.scopeSummary.contains("columns 10-200"))
    }
}
