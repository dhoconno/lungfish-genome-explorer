import XCTest
@testable import LungfishApp

final class IQTreeInferenceOptionsDialogTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func testIQTreeInferenceDialogExposesCuratedAndAdvancedOptions() throws {
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialog.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Sequence Type"))
        XCTAssertTrue(source.contains("Branch Support"))
        XCTAssertTrue(source.contains("Ultrafast Bootstrap"))
        XCTAssertTrue(source.contains("SH-aLRT"))
        XCTAssertTrue(source.contains("Safe numerical mode"))
        XCTAssertTrue(source.contains("Keep identical sequences"))
        XCTAssertTrue(source.contains("Advanced Options"))
        XCTAssertTrue(source.contains("IQ-TREE Parameters"))
    }

    func testIQTreeInferenceDialogExposesScopeAndExecutableOverride() throws {
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialog.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("iqtree-options-scope"))
        XCTAssertTrue(source.contains("iqtree-options-executable-path"))
        XCTAssertTrue(source.contains("IQ-TREE Executable"))
    }

    func testMSATreeInferenceRoutesThroughDialogBeforeRunner() throws {
        let sourceURL = repositoryRoot.appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("IQTreeInferenceDialogPresenter.present"))
        XCTAssertFalse(source.contains("IQTreeInferenceOptionsDialog.present"))
        XCTAssertTrue(source.contains("runIQTreeInferenceViaCLI"))
    }

    func testIQTreeInferenceUsesDatasetOperationsSheetInsteadOfAlertAccessory() throws {
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialog.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("DatasetOperationsDialog"))
        XCTAssertTrue(source.contains("Phylogenetic Tree Operations"))
        XCTAssertTrue(source.contains("Build Tree with IQ-TREE"))
        XCTAssertTrue(source.contains("accessibilityNamespace: \"iqtree-options\""))
        XCTAssertTrue(source.contains("iqtree-options-advanced-disclosure"))
        XCTAssertFalse(source.contains("NSAlert"))
        XCTAssertFalse(source.contains("accessoryView"))
    }

    func testIQTreeInferencePresenterUsesOperationsPanelSizing() throws {
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialogPresenter.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

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
