import XCTest
import SwiftUI
import ViewInspector
@testable import LungfishApp
import LungfishKit
import LungfishTestSupport

final class IQTreeInferenceOptionsDialogTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    @MainActor
    private func makeState(
        rows: String? = "row-1,row-2,row-3,row-4",
        columns: String? = "10-200",
        names: [String] = ["Homo sapiens", "Macaca mulatta", "Pan troglodytes", "Gorilla gorilla", "Mus musculus"]
    ) -> IQTreeInferenceDialogState {
        let request = MultipleSequenceAlignmentTreeInferenceRequest(
            bundleURL: URL(fileURLWithPath: "/project/Analyses/Multiple Sequence Alignments/alignment.lungfishmsa"),
            rows: rows,
            columns: columns,
            suggestedName: "alignment-tree.lungfishtree",
            displayName: "alignment"
        )
        return IQTreeInferenceDialogState(
            request: request,
            projectURL: URL(fileURLWithPath: "/project"),
            alignment: IQTreeAlignmentSummary(
                rows: names.enumerated().map { IQTreeAlignmentSummary.Row(id: "row-\($0.offset + 1)", displayName: $0.element) },
                alignedLength: 300,
                alphabet: "dna"
            ),
            performanceCoreCount: 4
        )
    }

    @MainActor
    private func makeDialog(_ state: IQTreeInferenceDialogState) -> IQTreeInferenceDialog {
        IQTreeInferenceDialog(state: state, onCancel: {}, onRun: {})
    }

    @MainActor
    func testDialogShowsGroupsInRulingOrder() throws {
        let state = makeState()
        state.advancedOptionsExpanded = true
        let inspected = try makeDialog(state).inspect()

        for title in ["Inputs", "Model", "Branch Support", "Rooting", "Output", "Run", "Advanced"] {
            _ = try inspected.find(text: title)
        }
        for label in [
            "Ultrafast bootstrap (UFBoot)",
            "SH-aLRT test",
            "Safe numerical mode",
            "Keep identical sequences",
        ] {
            _ = try inspected.find(ViewType.Toggle.self) { try $0.labelView().text().string() == label }
        }
        _ = try inspected.find(viewWithAccessibilityIdentifier: "iqtree-options-advanced-parameters")
        _ = try inspected.find(text: IQTreeInferenceDialogState.branchSupportCaption)
        _ = try inspected.find(text: IQTreeInferenceDialogState.seedCaption)
        _ = try inspected.find(text: IQTreeInferenceDialogState.threadsCaption)
        _ = try inspected.find(text: IQTreeInferenceDialogState.outgroupCaption)
        _ = try inspected.find(text: IQTreeInferenceDialogState.safeModeCaption)
        _ = try inspected.find(text: IQTreeInferenceDialogState.keepIdenticalCaption)
    }

    @MainActor
    func testDialogChromeAndPrimaryButton() throws {
        let inspected = try makeDialog(makeState()).inspect()
        _ = try inspected.find(text: "Build Tree with IQ-TREE")
        _ = try inspected.find(text: "Infer a maximum-likelihood tree from an alignment.")
        let primary = try inspected.find(viewWithAccessibilityIdentifier: "iqtree-options-primary-action").button()
        XCTAssertEqual(try primary.labelView().text().string(), "Build Tree")
        XCTAssertThrowsError(try inspected.find(text: "Readiness"), "The in-pane Readiness section is gone")
        XCTAssertThrowsError(try inspected.find(text: "Phylogenetic Tree Operations"))
    }

    @MainActor
    func testReadinessTextAppearsOnceInTheFooter() throws {
        let state = makeState()
        state.seedText = "12a"
        let inspected = try makeDialog(state).inspect()
        let matches = inspected.findAll(ViewType.Text.self) {
            try $0.string().contains("Seed must be a whole number")
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(
            try inspected.find(viewWithAccessibilityIdentifier: "iqtree-options-status-text").text().string(),
            "\(IQTreeInferenceDialogState.warningSymbol) Seed must be a whole number."
        )
    }

    /// D1. Every text field, pop-up, stepper and check box carries its own title,
    /// so its accessible name is never empty and equals the visible label.
    @MainActor
    func testEveryFieldHasANonEmptyAccessibleLabel() throws {
        let state = makeState()
        state.advancedOptionsExpanded = true
        state.modelChoice = .custom
        state.sequenceType = .codon
        let inspected = try makeDialog(state).inspect()

        let textFields = inspected.findAll(ViewType.TextField.self)
        XCTAssertGreaterThanOrEqual(textFields.count, 8)
        var fieldLabels: [String] = []
        for field in textFields {
            let label = try field.labelView().text().string()
            XCTAssertFalse(label.trimmingCharacters(in: .whitespaces).isEmpty)
            fieldLabels.append(label)
        }
        for expected in [
            "Custom model", "UFBoot replicates", "SH-aLRT replicates", "Name", "Seed", "Threads",
            "IQ-TREE executable", "Additional IQ-TREE parameters",
        ] {
            XCTAssertTrue(fieldLabels.contains(expected), "Missing field \(expected) in \(fieldLabels)")
        }

        let pickers = inspected.findAll(ViewType.Picker.self)
        let pickerLabels = try pickers.map { try $0.labelView().text().string() }
        for expected in ["Build from", "Model", "Sequence Type", "Genetic code"] {
            XCTAssertTrue(pickerLabels.contains(expected), "Missing pop-up \(expected) in \(pickerLabels)")
        }

        let steppers = inspected.findAll(ViewType.Stepper.self)
        XCTAssertEqual(steppers.count, 2)
        for stepper in steppers {
            XCTAssertFalse(try stepper.labelView().text().string().isEmpty)
        }

        for toggle in inspected.findAll(ViewType.Toggle.self) {
            XCTAssertFalse(try toggle.labelView().text().string().isEmpty)
        }
    }

    @MainActor
    func testReplicateFieldsAreDisabledWhileTheirBoxIsOff() throws {
        let state = makeState()
        state.bootstrapEnabled = false
        let inspected = try makeDialog(state).inspect()
        let ufboot = try inspected.find(ViewType.LabeledContent.self) {
            try $0.labelView().text().string() == "UFBoot replicates"
        }
        XCTAssertTrue(ufboot.isDisabled())
        let alrt = try inspected.find(ViewType.LabeledContent.self) {
            try $0.labelView().text().string() == "SH-aLRT replicates"
        }
        XCTAssertFalse(alrt.isDisabled())
    }

    @MainActor
    func testScopeRadioGroupAppearsOnlyWithSelection() throws {
        let withSelection = try makeDialog(makeState()).inspect()
        let picker = try withSelection.find(viewWithAccessibilityIdentifier: "iqtree-options-scope").picker()
        XCTAssertEqual(try picker.labelView().text().string(), "Build from")
        _ = try withSelection.find(text: "Selected rows and columns (4 sequences, columns 10-200)")
        _ = try withSelection.find(text: "Whole alignment (5 sequences, 300 columns)")

        let withoutSelection = try makeDialog(makeState(rows: nil, columns: nil)).inspect()
        XCTAssertThrowsError(try withoutSelection.find(viewWithAccessibilityIdentifier: "iqtree-options-scope").picker())
        _ = try withoutSelection.find(text: "Whole alignment (5 sequences, 300 columns)")
    }

    @MainActor
    func testOutgroupListOffersInScopeNamesAsCheckboxes() throws {
        let state = makeState(names: ["Homo sapiens", "Macaca mulatta", "Pan, troglodytes", "Gorilla gorilla", "Mus musculus"])
        let inspected = try makeDialog(state).inspect()
        let toggles = inspected.findAll(ViewType.Toggle.self)
        let labels = try toggles.map { try $0.labelView().text().string() }
        XCTAssertTrue(labels.contains("Homo sapiens"))
        XCTAssertTrue(labels.contains("Gorilla gorilla"))
        XCTAssertFalse(labels.contains("Pan, troglodytes"))
        XCTAssertFalse(labels.contains("Mus musculus"), "Mus musculus is outside the selected rows")
        _ = try inspected.find(text: IQTreeInferenceDialogState.outgroupCommaCaption)
    }

    func testMSATreeInferenceRoutesThroughDialogBeforeRunner() throws {
        let sourceURL = repositoryRoot.appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController+TreeInference.swift")
        let source = try readRepositorySource(sourceURL)

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // runIQTreeInferenceViaCLI is a private method on ViewerViewController and the
        // routing decision only manifests by presenting a real NSPanel sheet.
        XCTAssertTrue(source.contains("IQTreeInferenceDialogPresenter.present"))
        XCTAssertTrue(source.contains("runIQTreeInferenceViaCLI"))
        XCTAssertTrue(source.contains("IQTreeInferenceLaunch.make"))
    }

    @MainActor
    func testAdvancedDisclosureFollowsUITestConfiguration() throws {
        let state = makeState(rows: nil, columns: nil)
        XCTAssertEqual(state.advancedOptionsExpanded, AppUITestConfiguration.current.isEnabled)
        _ = try makeDialog(state).inspect().find(viewWithAccessibilityIdentifier: "iqtree-options-advanced-disclosure")

        // "No NSAlert/accessoryView anywhere in this file" is a dead-API-absence check.
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialog.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("NSAlert"))
        XCTAssertFalse(source.contains("accessoryView"))
    }

    @MainActor
    func testPresenterSizesTheSheetAt780By640WithAMinimum() {
        XCTAssertEqual(IQTreeInferenceDialogPresenter.contentSize, NSSize(width: 780, height: 640))
        let minimum = IQTreeInferenceDialogPresenter.minimumContentSize
        XCTAssertLessThan(minimum.width, 780)
        XCTAssertLessThan(minimum.height, 640)
        XCTAssertGreaterThan(minimum.width, 0)
    }

    /// The live AX tree, as VoiceOver reads it. Every text field speaks its
    /// visible title, and the one sidebar card reports AXSelected.
    @MainActor
    func testLiveAccessibilityTreeNamesFieldsAndMarksTheSelectedCard() throws {
        let state = makeState()
        state.advancedOptionsExpanded = true
        let window = AccessibilityTreeProbe.host(makeDialog(state), size: CGSize(width: 780, height: 1600))
        defer { window.orderOut(nil) }

        let seedID = "iqtree-options-seed"
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.element(in: window, identifier: seedID) != nil }
        let seed = try XCTUnwrap(AccessibilityTreeProbe.element(in: window, identifier: seedID), AccessibilityTreeProbe.dump(window))
        XCTAssertEqual(AccessibilityTreeProbe.label(seed), "Seed")

        let controlRoles: Set<String> = ["AXTextField", "AXPopUpButton", "AXCheckBox", "AXRadioGroup", "AXIncrementor"]
        let fields = AccessibilityTreeProbe.all(in: window).filter { controlRoles.contains(AccessibilityTreeProbe.role($0) ?? "") }
        XCTAssertFalse(fields.isEmpty, AccessibilityTreeProbe.dump(window))
        for field in fields {
            let label = AccessibilityTreeProbe.label(field) ?? ""
            XCTAssertFalse(label.isEmpty, "unnamed control; tree:\n" + AccessibilityTreeProbe.dump(window))
        }
        for (identifier, title) in [
            ("iqtree-options-threads", "Threads"),
            ("iqtree-options-output-name", "Name"),
            ("iqtree-options-bootstrap-count", "UFBoot replicates"),
            ("iqtree-options-alrt-count", "SH-aLRT replicates"),
            ("iqtree-options-model", "Model"),
            ("iqtree-options-sequence-type", "Sequence Type"),
            ("iqtree-options-scope", "Build from"),
            ("iqtree-options-bootstrap-checkbox", "Ultrafast bootstrap (UFBoot)"),
            ("iqtree-options-advanced-parameters", "Additional IQ-TREE parameters"),
        ] {
            let element = try XCTUnwrap(AccessibilityTreeProbe.element(in: window, identifier: identifier), identifier)
            XCTAssertEqual(AccessibilityTreeProbe.label(element), title)
        }

        let card = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "iqtree-options-tool-build-tree-with-iq-tree"),
            AccessibilityTreeProbe.dump(window)
        )
        XCTAssertTrue(AccessibilityTreeProbe.isSelected(card))
    }
}
