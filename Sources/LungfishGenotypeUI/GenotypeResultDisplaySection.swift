import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit

@inline(__always)
func isSupportedMHCCandidateDocumentSchemaVersion(_ schemaVersion: Int) -> Bool {
    (1 ... 5).contains(schemaVersion)
}

@MainActor
private struct GenotypeNumericFilterStepper: NSViewRepresentable {
    let value: Double
    let configuration: GenotypeNumericFilterConfiguration
    let accessibility: GenotypeNumericFilterAccessibilityState
    let onChange: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSStepper {
        let stepper = NSStepper()
        stepper.controlSize = .small
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.target = context.coordinator
        stepper.action = #selector(Coordinator.valueChanged(_:))
        return stepper
    }

    func updateNSView(_ stepper: NSStepper, context: Context) {
        context.coordinator.onChange = onChange
        stepper.minValue = configuration.bounds.lowerBound
        stepper.maxValue = configuration.bounds.upperBound
        stepper.increment = configuration.step
        stepper.doubleValue = value
        stepper.setAccessibilityIdentifier(
            configuration.stepperAccessibilityIdentifier
        )
        stepper.setAccessibilityLabel(accessibility.label)
        stepper.setAccessibilityValue(NSNumber(value: value))
        stepper.setAccessibilityValueDescription(accessibility.value)
        stepper.setAccessibilityHelp(
            "\(accessibility.bounds) "
                + "\(accessibility.incrementAction) "
                + accessibility.decrementAction
        )
    }

    final class Coordinator: NSObject {
        var onChange: (Double) -> Void

        init(onChange: @escaping (Double) -> Void) {
            self.onChange = onChange
        }

        @MainActor @objc func valueChanged(_ sender: NSStepper) {
            onChange(sender.doubleValue)
        }
    }
}

public struct GenotypeResultDisplaySection: View {
    private var typography: ContentTypographyModel { .shared }
    @AppStorage(GenotypeOutlineView.densityPreferenceKey) private var compactHaplotypeRows = false
    @State private var showsReviewHelp = false
    @State private var showsAdvancedDisplay = false
    @Bindable var viewModel: GenotypeResultDisplaySectionViewModel
    @FocusState private var focusedNumericFilter: NumericFilterFocus?

    private enum NumericFilterFocus: Hashable {
        case minimumReads
        case minimumPercent
        case minimumPrevalencePercent
    }

    public init(viewModel: GenotypeResultDisplaySectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.isAvailable {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    reviewHelp
                    summary
                    contentTextSizeControls
                    if viewModel.hasHaplotypingResult {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Haplotype spacing")
                                .foregroundStyle(.secondary)
                            Picker("Haplotype spacing", selection: $compactHaplotypeRows) {
                                Text("Comfortable").tag(false)
                                Text("Compact").tag(true)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .font(typography.font(for: .body))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .help("Comfortable spacing gives each assignment a larger target. Both modes follow Content Text Size.")
                        .onChange(of: compactHaplotypeRows) { _, _ in
                            NotificationCenter.default.post(name: GenotypeOutlineView.densityChanged, object: nil)
                        }
                    }
                    if viewModel.mhcCandidateControlsAvailable
                        || !viewModel.mhcCandidateIntegrityWarnings.isEmpty
                        || viewModel.mhcCandidatePersistenceWarning != nil {
                        GenotypeCandidateEvidenceSection(viewModel: viewModel)
                    }
                    if viewModel.hasHaplotypingResult
                        && viewModel.presentationChoices.isEmpty {
                        haplotypeGenotypeToggle
                    }
                    Divider()
                    if viewModel.showsViewportAndLayoutControls {
                        viewControls
                    }
                    if viewModel.hasHaplotypingResult {
                        diagnosticAlleleControls
                    }
                    matrixFilterControls
                    DisclosureGroup("Layout and locus order", isExpanded: $showsAdvancedDisplay) {
                        if viewModel.showsViewportAndLayoutControls { layoutControls }
                        if viewModel.locusDisplayOrderAvailable { locusDisplayOrderControls }
                    }
                    matrixVisibilityControls
                    colorControls
                    highlightControls
                }
                .padding(.top, 4)
                .font(typography.font(for: .body))
            } label: {
                Label("Genotype Display", systemImage: "tablecells")
                    .font(typography.font(for: .emphasizedBody))
            }
            .onChange(of: focusedNumericFilter) { oldValue, newValue in
                guard oldValue != newValue else { return }
                switch oldValue {
                case .minimumReads:
                    viewModel.commitMatrixMinimumReadsDraft()
                case .minimumPercent:
                    viewModel.commitMatrixMinimumPercentDraft()
                case .minimumPrevalencePercent:
                    viewModel.commitMatrixMinimumPrevalencePercentDraft()
                case nil:
                    break
                }
            }
        }
    }

    private var reviewHelp: some View {
        Button("How to review this result", systemImage: "questionmark.circle") {
            showsReviewHelp = true
        }
        .help("Learn how allele observations support haplotype assignments.")
        .accessibilityIdentifier("genotype-review-help")
        .popover(isPresented: $showsReviewHelp) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review a genotype result").font(typography.font(for: .emphasizedBody))
                    if viewModel.hasHaplotypingResult {
                        Text("Haplotype Calls shows assignments inferred from allele evidence. Select a call to inspect its support.")
                    }
                    Text("Genotype Matrix compares allele read support across samples. Slash-separated names can represent alleles the assay cannot distinguish.")
                    if viewModel.hasHaplotypingResult { Text("Diagnostic alleles only shows evidence used by the active definitions. Turn it off to inspect all observed alleles. Display filters do not change calls.") }
                    Text("Use Columns to choose the identifiers and read totals you need. Total Reads includes all samples in the result, even hidden columns.")
                    if viewModel.hasHaplotypingResult { Text("To correct an assignment, inspect its evidence and choose Change. Custom names require a rationale, acknowledgement and explicit application; the original call remains in the audit history.") }
                    Text(GenotypeExcelExportSessionState.disclosure)
                    Button("Done") { showsReviewHelp = false }.keyboardShortcut(.cancelAction)
                }
                .font(typography.font(for: .body))
                .textSelection(.enabled)
                .padding(20)
            }
            .frame(width: 420, height: 480)
        }
    }

    private var locusDisplayOrderControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Locus display order")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            Text(viewModel.locusDisplayOrderStatus)
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("F, G, AG, A1, A2/A3/A4/A5, K, L, E, B, DRB, DQA, DQB, DPA, DPB",
                      text: $viewModel.locusDisplayOrderDraft, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Locus display order")
                .accessibilityHint("Separate ordered loci with commas. A slash groups loci together.")
                .accessibilityIdentifier("genotype-locus-display-order")
                .disabled(!viewModel.locusDisplayOrderCanEdit)
            HStack {
                Button("Apply") { viewModel.applyLocusDisplayOrderDraft() }
                    .accessibilityIdentifier("genotype-locus-display-order-apply")
                Button("Use Bundle Default") { viewModel.resetLocusDisplayOrder() }
                    .accessibilityIdentifier("genotype-locus-display-order-reset")
            }
            .controlSize(.regular)
            .disabled(!viewModel.locusDisplayOrderCanEdit)
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help(locusOrderHelp)
                .accessibilityLabel("About locus display order")
                .accessibilityHint(locusOrderHelp)
            if let error = viewModel.locusDisplayOrderValidationError ?? viewModel.locusDisplayOrderPersistenceWarning {
                Text(error).font(typography.font(for: .body)).foregroundStyle(Color.lungfishDangerFallback)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("genotype-locus-display-order-error")
            }
        }
    }

    private var contentTextSizeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Content Text Size")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("A−") {
                    viewModel.decreaseContentTextSize()
                }
                .disabled(!viewModel.canDecreaseContentTextSize)
                .accessibilityLabel("Decrease content text size")
                .accessibilityIdentifier("genotype-view-content-text-size-decrease")

                Text(viewModel.contentTextSizeLabel)
                    .frame(minWidth: 48)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Content text size")
                    .accessibilityValue(viewModel.contentTextSizeLabel)
                    .accessibilityIdentifier("genotype-view-content-text-size-value")

                Button("A+") {
                    viewModel.increaseContentTextSize()
                }
                .disabled(!viewModel.canIncreaseContentTextSize)
                .accessibilityLabel("Increase content text size")
                .accessibilityIdentifier("genotype-view-content-text-size-increase")

                Button("Default") {
                    viewModel.restoreSystemContentTextSize()
                }
                .disabled(viewModel.contentTextSizePreference == .system)
                .accessibilityLabel("Use system content text size")
                .accessibilityIdentifier("genotype-view-content-text-size-default")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
        }
    }

    private var haplotypeGenotypeToggle: some View {
        Button {
            viewModel.toggleHaplotypeGenotypeSummaryView()
        } label: {
            Label(
                viewModel.displayState.summaryViewMode == .matrix
                    ? "Show haplotyping view"
                    : "Show genotype matrix",
                systemImage: viewModel.displayState.summaryViewMode == .matrix
                    ? "list.bullet.rectangle"
                    : "tablecells"
            )
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Rows", value: "\(viewModel.visibleRowCount) of \(viewModel.totalRowCount)")
            LabeledContent("Hidden Cells", value: "\(viewModel.hiddenCellCount)")
        }
        .font(typography.font(for: .body))
    }

    private var viewControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                viewModel.presentationChoices.isEmpty
                    ? "Viewport"
                    : "View Presentation"
            )
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            if viewModel.presentationChoices.isEmpty {
                Picker("Viewport", selection: Binding(
                    get: { viewModel.displayState.viewportLens },
                    set: { viewModel.setViewportLens($0) }
                )) {
                    ForEach(viewModel.legacyViewportLenses, id: \.self) { lens in
                        Label(lens.displayName, systemImage: lens.inspectorSystemImage)
                        .tag(lens)
                    }
                }
                .pickerStyle(.radioGroup)
                .controlSize(.regular)
                .labelsHidden()
            } else {
                Picker("View Presentation", selection: Binding(
                    get: { viewModel.displayState.summaryViewMode },
                    set: { viewModel.setSummaryViewMode($0) }
                )) {
                    ForEach(viewModel.presentationChoices, id: \.self) {
                        choice in
                        Text(choice.displayName)
                            .tag(choice.summaryViewMode)
                    }
                }
                .pickerStyle(.radioGroup)
                .controlSize(.regular)
                .labelsHidden()
                .accessibilityHint(
                    viewModel.presentationAccessibilityHelp
                )
            }
        }
    }

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Panel Layout")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
            Picker("Layout", selection: Binding(
                get: { viewModel.displayState.layout },
                set: { viewModel.setLayout($0) }
            )) {
                Label("Detail | List", systemImage: "sidebar.left")
                    .tag(GenotypeResultPanelLayout.listTrailing)
                Label("List | Detail", systemImage: "sidebar.right")
                    .tag(GenotypeResultPanelLayout.listLeading)
                Label("List Over Detail", systemImage: "rectangle.split.1x2")
                    .tag(GenotypeResultPanelLayout.listTop)
            }
            .pickerStyle(.radioGroup)
            .controlSize(.regular)
            .labelsHidden()
        }
    }

    private var matrixFilterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Search and Support Filters")
                    .font(typography.font(for: .body))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .help(filterAndThresholdHelp)
                    .accessibilityLabel("About search and support filters")
                    .accessibilityHint(filterAndThresholdHelp)
                    .accessibilityIdentifier("genotype-view-threshold-help")
            }
            TextField("Alleles", text: Binding(
                get: { viewModel.displayState.matrixRowFilterText },
                set: { viewModel.setMatrixRowFilterText($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.regular)
            TextField("Samples", text: Binding(
                get: { viewModel.displayState.matrixSampleFilterText },
                set: { viewModel.setMatrixSampleFilterText($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.regular)
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    viewModel.matrixMinimumReadsDraft.configuration.label
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 6) {
                    TextField(
                    viewModel.matrixMinimumReadsDraft.configuration.label,
                    text: Binding(
                        get: {
                            viewModel.matrixMinimumReadsDraft.draftText
                        },
                        set: {
                            viewModel.updateMatrixMinimumReadsDraft($0)
                        }
                    )
                )
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .frame(minWidth: 88, idealWidth: 112)
                .focused($focusedNumericFilter, equals: .minimumReads)
                .onSubmit {
                    viewModel.commitMatrixMinimumReadsDraft()
                }
                .onExitCommand {
                    viewModel.restoreMatrixMinimumReadsDraft()
                }
                .accessibilityIdentifier(
                    viewModel.matrixMinimumReadsDraft.configuration
                        .fieldAccessibilityIdentifier
                )
                .accessibilityLabel(
                    viewModel.matrixMinimumReadsDraft.accessibility.label
                )
                .accessibilityValue(
                    viewModel.matrixMinimumReadsDraft.accessibility.value
                )
                .accessibilityHint(
                    viewModel.matrixMinimumReadsDraft.accessibility
                        .validationDescription
                        ?? viewModel.matrixMinimumReadsDraft.accessibility.bounds
                )
                GenotypeNumericFilterStepper(
                    value: viewModel.matrixMinimumReadsDraft.stepperValue,
                    configuration:
                        viewModel.matrixMinimumReadsDraft.configuration,
                    accessibility:
                        viewModel.matrixMinimumReadsDraft.accessibility,
                    onChange: {
                        viewModel.setMatrixMinimumReadsFromStepper(Int($0))
                    }
                )
                .labelsHidden()
                .controlSize(.regular)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    viewModel.matrixMinimumPercentDraft.configuration.label
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 6) {
                    TextField(
                    viewModel.matrixMinimumPercentDraft.configuration.label,
                    text: Binding(
                        get: {
                            viewModel.matrixMinimumPercentDraft.draftText
                        },
                        set: {
                            viewModel.updateMatrixMinimumPercentDraft($0)
                        }
                    )
                )
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .frame(minWidth: 88, idealWidth: 112)
                .focused($focusedNumericFilter, equals: .minimumPercent)
                .onSubmit {
                    viewModel.commitMatrixMinimumPercentDraft()
                }
                .onExitCommand {
                    viewModel.restoreMatrixMinimumPercentDraft()
                }
                .accessibilityIdentifier(
                    viewModel.matrixMinimumPercentDraft.configuration
                        .fieldAccessibilityIdentifier
                )
                .accessibilityLabel(
                    viewModel.matrixMinimumPercentDraft.accessibility.label
                )
                .accessibilityValue(
                    viewModel.matrixMinimumPercentDraft.accessibility.value
                )
                .accessibilityHint(
                    viewModel.matrixMinimumPercentDraft.accessibility
                        .validationDescription
                        ?? viewModel.matrixMinimumPercentDraft.accessibility
                            .bounds
                )
                Text("%")
                    .foregroundStyle(.secondary)
                GenotypeNumericFilterStepper(
                    value: viewModel.matrixMinimumPercentDraft.stepperValue,
                    configuration:
                        viewModel.matrixMinimumPercentDraft.configuration,
                    accessibility:
                        viewModel.matrixMinimumPercentDraft.accessibility,
                    onChange: {
                        viewModel.setMatrixMinimumPercentFromStepper($0)
                    }
                )
                .labelsHidden()
                .controlSize(.regular)
                }
            }
            // Prevalence is its own control, never folded into
            // Min percent, which is always a per-sample read fraction.
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    viewModel.matrixMinimumPrevalencePercentDraft.configuration.label
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 6) {
                    TextField(
                    viewModel.matrixMinimumPrevalencePercentDraft.configuration.label,
                    text: Binding(
                        get: {
                            viewModel.matrixMinimumPrevalencePercentDraft.draftText
                        },
                        set: {
                            viewModel.updateMatrixMinimumPrevalencePercentDraft($0)
                        }
                    )
                )
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .frame(minWidth: 88, idealWidth: 112)
                .focused($focusedNumericFilter, equals: .minimumPrevalencePercent)
                .onSubmit {
                    viewModel.commitMatrixMinimumPrevalencePercentDraft()
                }
                .onExitCommand {
                    viewModel.restoreMatrixMinimumPrevalencePercentDraft()
                }
                .accessibilityIdentifier(
                    viewModel.matrixMinimumPrevalencePercentDraft.configuration
                        .fieldAccessibilityIdentifier
                )
                .accessibilityLabel(
                    viewModel.matrixMinimumPrevalencePercentDraft.accessibility.label
                )
                .accessibilityValue(
                    viewModel.matrixMinimumPrevalencePercentDraft.accessibility.value
                )
                .accessibilityHint(
                    viewModel.matrixMinimumPrevalencePercentDraft.accessibility
                        .validationDescription
                        ?? viewModel.matrixMinimumPrevalencePercentDraft.accessibility
                            .bounds
                )
                Text("%")
                    .foregroundStyle(.secondary)
                GenotypeNumericFilterStepper(
                    value: viewModel.matrixMinimumPrevalencePercentDraft.stepperValue,
                    configuration:
                        viewModel.matrixMinimumPrevalencePercentDraft.configuration,
                    accessibility:
                        viewModel.matrixMinimumPrevalencePercentDraft.accessibility,
                    onChange: {
                        viewModel.setMatrixMinimumPrevalencePercentFromStepper($0)
                    }
                )
                .labelsHidden()
                .controlSize(.regular)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Percent Basis")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                Picker("Percent Basis", selection: Binding(
                    get: { viewModel.displayState.matrixPercentDenominator },
                    set: { viewModel.setMatrixPercentDenominator($0) }
                )) {
                    ForEach(ONTGenotypeSupportDenominator.allCases, id: \.self) { denominator in
                        Text(denominator.displayName).tag(denominator)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.regular)
                .font(typography.font(for: .body))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Percent Basis")
                .accessibilityHint("Choose the denominator used by the minimum percent display filter. Source Locus divides by the sample's unique reads at the allele's own source locus.")
                .accessibilityIdentifier("genotype-view-percent-basis")
            }
        }
        .help(filterAndThresholdHelp)
        .accessibilityHint(filterAndThresholdHelp)
    }

    private var matrixVisibilityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Selected Rows and Columns")
                    .font(typography.font(for: .body))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .help(matrixVisibilityHelp)
                    .accessibilityLabel("About matrix visibility")
                    .accessibilityHint(matrixVisibilityHelp)
                    .accessibilityIdentifier("genotype-view-visibility-guidance")
            }
            Text(viewModel.matrixVisibilityScopeSummary)
                .font(typography.font(for: .body))
                .accessibilityIdentifier("genotype-view-visibility-scope")
            Text(viewModel.matrixVisibilityStatus)
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("genotype-view-visibility-status")
            HStack(spacing: 8) {
                Menu("Rows…") {
                    Button("Hide Selected Rows") {
                        viewModel.hideSelectedMatrixRows()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canHideSelectedRows)
                    .accessibilityIdentifier("genotype-view-hide-selected-rows")
                    Button("Show Only Selected Rows") {
                        viewModel.showOnlySelectedMatrixRows()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canShowOnlySelectedRows)
                    .accessibilityIdentifier("genotype-view-show-only-selected-rows")
                    Divider()
                    Button("Show All Rows") {
                        viewModel.showAllMatrixRows()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canShowAllRows)
                    .accessibilityIdentifier("genotype-view-show-all-rows")
                }
                .accessibilityIdentifier("genotype-view-row-visibility-menu")

                Menu("Columns…") {
                    Button("Hide Selected Columns") {
                        viewModel.hideSelectedMatrixColumns()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canHideSelectedColumns)
                    .accessibilityIdentifier("genotype-view-hide-selected-columns")
                    Button("Show Only Selected Columns") {
                        viewModel.showOnlySelectedMatrixColumns()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canShowOnlySelectedColumns)
                    .accessibilityIdentifier("genotype-view-show-only-selected-columns")
                    Divider()
                    Button("Show All Columns") {
                        viewModel.showAllMatrixColumns()
                    }
                    .disabled(!viewModel.matrixVisibilityCapability.canShowAllColumns)
                    .accessibilityIdentifier("genotype-view-show-all-columns")
                }
                .accessibilityIdentifier("genotype-view-column-visibility-menu")
            }
            .controlSize(.regular)

            Button {
                viewModel.resetMatrixVisibility()
            } label: {
                Label("Reset Visibility", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .disabled(!viewModel.canResetMatrixVisibility)
            .accessibilityIdentifier("genotype-view-reset-visibility")
        }
        .help(matrixVisibilityHelp)
        .accessibilityHint(matrixVisibilityHelp)
        .accessibilityIdentifier("genotype-view-visibility-group")
    }

    private var diagnosticAlleleControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Diagnostic alleles only", isOn: Binding(
                get: { viewModel.displayState.diagnosticAllelesOnly },
                set: { viewModel.setDiagnosticAllelesOnly($0) }
            ))
            .accessibilityIdentifier("genotype-display-diagnostic-alleles-only")
            Text(viewModel.displayState.diagnosticAllelesOnly ? "Showing diagnostic evidence" : "Showing all observed alleles")
                .help("Diagnostic alleles come from all active haplotype definitions, including unresolved calls. This filters Haplotype Calls evidence and Genotype Matrix without changing assignments.")
                .font(typography.font(for: .body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Cell Color", selection: Binding(
                get: { viewModel.displayState.cellColorMode },
                set: { viewModel.setCellColorMode($0) }
            )) {
                ForEach(GenotypeResultCellColorMode.allCases.filter { $0 != .haplotype || viewModel.hasHaplotypingResult }, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.regular)
            .font(typography.font(for: .body))
            if viewModel.displayState.cellColorMode == .haplotype {
                Text("Shared support: gray · Unmatched: neutral")
                    .help("Colors identify support for displayed haplotype calls using the active definitions. Inspect a cell for its supporting haplotypes.")
                    .font(typography.font(for: .body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("genotype-display-haplotype-color-legend")
            }
        }
    }

    @ViewBuilder
    private var highlightControls: some View {
        if let target = viewModel.genotypeResultSelection?.highlightTarget {
            VStack(alignment: .leading, spacing: 8) {
                Text("Selected Highlight")
                    .font(typography.font(for: .body))
                    .foregroundStyle(.secondary)

                valueRow(label: "Target", value: target.sample.map { "\(target.locus) / \($0)" } ?? target.locus)
                    .font(typography.font(for: .body))

                Picker("Target Scope", selection: $viewModel.genotypeHighlightScope) {
                    if target.sample != nil {
                        Text("Cell").tag(GenotypeResultHighlightScope.selectedCell)
                    }
                    Text("Row").tag(GenotypeResultHighlightScope.selectedRow)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.regular)

                Picker("Color Target", selection: Binding(
                    get: { viewModel.genotypeHighlightChannel },
                    set: { viewModel.setGenotypeHighlightChannel($0) }
                )) {
                    ForEach(GenotypeResultHighlightChannel.allCases, id: \.self) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.regular)

                HStack(spacing: 10) {
                    ContinuousColorWell(
                        color: viewModel.activeGenotypeHighlightNSColor,
                        onChange: { viewModel.setGenotypeHighlightColor($0) }
                    )
                    .frame(width: 44, height: 24)
                    Text(viewModel.genotypeHighlightChannel == .fill ? "Cell Fill" : "Outer Border")
                        .font(typography.font(for: .body))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        viewModel.clearGenotypeHighlight(.fill)
                    } label: {
                        Label("Clear Fill", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.regular)

                    Button {
                        viewModel.clearGenotypeHighlight(.border)
                    } label: {
                        Label("Clear Border", systemImage: "square.dashed")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.regular)
                }

                Button {
                    viewModel.revertGenotypeHighlightToDefault()
                } label: {
                    Label("Revert to Default", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
            }
        }
    }

    private func valueRow(label: String, value: String) -> some View {
        InspectorKeyValueRow(
            label,
            value: value,
            font: typography.font(for: .body)
        )
    }

    private var locusOrderHelp: String {
        "Changes row order only. Commas separate groups; / joins loci. Unlisted loci appear afterward. Included loci and haplotype calls stay unchanged."
    }

    private var thresholdHelp: String {
        "Display filters do not change genotype calls. Re-run the analysis to change calling thresholds."
    }

    private var matrixFilterHelp: String {
        "Search and support filters affect only the visible matrix. Zero disables a numeric filter; genotype calls are unchanged. "
            + "Min percent is each cell's share of that sample's reads, for known and candidate alleles alike. "
            + "Seen in at least N% of animals is a separate filter on how many samples show the allele."
    }

    private var filterAndThresholdHelp: String {
        "\(matrixFilterHelp) \(thresholdHelp)"
    }

    private var matrixVisibilityHelp: String {
        "Select allele row markers or sample column headers to change visibility. Visibility actions use the selection; search and support filters apply to the visible matrix."
    }
}

private struct ContinuousColorWell: NSViewRepresentable {
    var color: NSColor
    var onChange: (NSColor) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let colorWell = NSColorWell(frame: .zero)
        colorWell.isContinuous = true
        colorWell.color = color
        colorWell.target = context.coordinator
        colorWell.action = #selector(Coordinator.colorChanged(_:))
        return colorWell
    }

    func updateNSView(_ colorWell: NSColorWell, context: Context) {
        context.coordinator.onChange = onChange
        if colorWell.color != color {
            colorWell.color = color
        }
    }

    final class Coordinator: NSObject {
        var onChange: (NSColor) -> Void

        init(onChange: @escaping (NSColor) -> Void) {
            self.onChange = onChange
        }

        @MainActor @objc func colorChanged(_ sender: NSColorWell) {
            onChange(sender.color)
        }
    }
}
