import AppKit
import SwiftUI
import LungfishCore
import LungfishIO

@inline(__always)
func isSupportedMHCCandidateDocumentSchemaVersion(_ schemaVersion: Int) -> Bool {
    (1 ... 4).contains(schemaVersion)
}

public enum GenotypeMatrixPaletteTarget: String, CaseIterable, Identifiable {
    case fill
    case text
    case border

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fill: return "Fill"
        case .text: return "Text"
        case .border: return "Border"
        }
    }
}

@Observable
@MainActor
public final class GenotypeResultDisplaySectionViewModel {
    public var displayState = GenotypeResultDisplayState()
    public var isAvailable = false
    public var visibleRowCount = 0
    public var totalRowCount = 0
    public var hiddenCellCount = 0
    public var hasHaplotypingResult = false
    public var isGenotypeOnlyResult = false
    public var showsViewportAndLayoutControls: Bool { !isGenotypeOnlyResult }
    public var isExpanded = true
    public var genotypeResultSelection: GenotypeResultSelectionState?
    public var genotypeHighlightColor: Color = .blue
    public var genotypeBorderColor: Color = .blue
    public var genotypeHighlightScope: GenotypeResultHighlightScope = .selectedCell
    public var genotypeHighlightChannel: GenotypeResultHighlightChannel = .fill
    public var matrixFillColor: Color = Color(nsColor: NSColor.systemYellow)
    public var matrixTextColor: Color = Color(nsColor: NSColor.labelColor)
    public var matrixBorderColor: Color = Color(nsColor: NSColor.systemOrange)
    public var matrixIsBold = false
    public var matrixIsItalic = false
    public var matrixCommentText = ""
    public var matrixPaletteTarget: GenotypeMatrixPaletteTarget = .fill
    public var supportedCellMinimumReads = 1
    public var mhcCandidateControlsAvailable = false
    public var mhcCandidateIntegrityWarnings: [String] = []
    public var mhcCandidatePersistenceWarning: String?
    public private(set) var matrixReviewCapability = GenotypeMatrixReviewCapability.evaluate(
        selection: [],
        evidence: .init(),
        reviews: [],
        comments: [],
        isWritable: false
    )

    public var onDisplayStateChanged: ((GenotypeResultDisplayState) -> Void)?
    public var onGenotypeHighlightRequested: ((GenotypeResultHighlightRequest) -> Void)?
    public var onMatrixStyleRequested: ((GenotypeMatrixStyleRequest) -> Void)?
    public var onMatrixReviewRequested: ((GenotypeMatrixReviewRequest) -> Void)?
    public var onMatrixCommentRequested: ((GenotypeMatrixCommentEditRequest) -> Void)?
    public var onMatrixCommentEditRequested: ((GenotypeMatrixCommentEditRequest) -> Void)? {
        get { onMatrixCommentRequested }
        set { onMatrixCommentRequested = newValue }
    }
    public var onSupportSelectionPreviewChanged: ((Int) -> Void)?
    public var onShowOnlySelectedMatrixRowsRequested: (() -> Void)?
    public var onShowOnlySelectedMatrixColumnsRequested: (() -> Void)?
    public var onClearMatrixSelectionFilterRequested: (() -> Void)?

    @ObservationIgnored
    private var isUpdatingFromSelection = false

    public init() {}

    public func update(
        isAvailable: Bool,
        state: GenotypeResultDisplayState = GenotypeResultDisplayState(),
        hasHaplotypingResult: Bool = false,
        isGenotypeOnlyResult: Bool = false
    ) {
        self.isAvailable = isAvailable
        self.hasHaplotypingResult = hasHaplotypingResult
        self.isGenotypeOnlyResult = isGenotypeOnlyResult
        setNormalizedDisplayState(state)
        updateSelection(nil)
    }

    public func updateSummary(visibleRows: Int, totalRows: Int, hiddenCells: Int) {
        visibleRowCount = visibleRows
        totalRowCount = totalRows
        hiddenCellCount = hiddenCells
    }

    public func updateDisplayState(_ state: GenotypeResultDisplayState) {
        setNormalizedDisplayState(state)
    }

    public func clear() {
        isAvailable = false
        displayState = GenotypeResultDisplayState()
        visibleRowCount = 0
        totalRowCount = 0
        hiddenCellCount = 0
        hasHaplotypingResult = false
        mhcCandidateControlsAvailable = false
        mhcCandidateIntegrityWarnings = []
        mhcCandidatePersistenceWarning = nil
        isGenotypeOnlyResult = false
        matrixReviewCapability = Self.emptyMatrixReviewCapability
        updateSelection(nil)
    }

    public var mhcCandidateDisplaySettings: ONTMHCCandidateDisplaySettings {
        displayState.mhcCandidateDisplaySettings ?? .default
    }

    public func updateMHCCandidatePresentation(from result: ONTGenotypeResultBundleData) {
        let isFullLengthMHCResult = result.manifest.kind == "full-length-ont-mhc-genotype"
        let declaration = result.manifest.mhcCandidateArtifacts
        mhcCandidateControlsAvailable = isFullLengthMHCResult
            && declaration.map { (1 ... 2).contains($0.schemaVersion) } == true
            && declaration?.candidateJSON != nil
            && declaration?.candidateFASTA != nil
            && result.mhcCandidates.map { isSupportedMHCCandidateDocumentSchemaVersion($0.schemaVersion) } == true
        mhcCandidateIntegrityWarnings = isFullLengthMHCResult
            ? result.integrityWarnings.map(Self.integrityWarningText)
            : []
        if !mhcCandidateControlsAvailable {
            displayState.mhcCandidateDisplaySettings = nil
        }
        if !isFullLengthMHCResult {
            mhcCandidatePersistenceWarning = nil
        }
    }

    public func setMHCCandidateVisibility(
        showKnown: Bool? = nil,
        showSharedCandidates: Bool? = nil,
        showSingletonCandidates: Bool? = nil
    ) {
        guard mhcCandidateControlsAvailable else { return }
        var settings = mhcCandidateDisplaySettings
        if let showKnown { settings.showKnown = showKnown }
        if let showSharedCandidates { settings.showSharedCandidates = showSharedCandidates }
        if let showSingletonCandidates { settings.showSingletonCandidates = showSingletonCandidates }
        displayState.mhcCandidateDisplaySettings = settings
        notifyStateChanged()
    }

    public func setMHCCandidateTint(
        _ color: AnnotationColor,
        category: ONTMHCCandidateTintCategory
    ) {
        guard mhcCandidateControlsAvailable else { return }
        var settings = mhcCandidateDisplaySettings
        settings.tints[category] = color
        displayState.mhcCandidateDisplaySettings = settings
        notifyStateChanged()
    }

    public func resetMHCCandidateTint(_ category: ONTMHCCandidateTintCategory) {
        guard let color = ONTMHCCandidateDisplaySettings.defaultTints[category] else { return }
        setMHCCandidateTint(color, category: category)
    }

    public func resetAllMHCCandidateTints() {
        guard mhcCandidateControlsAvailable else { return }
        var settings = mhcCandidateDisplaySettings
        settings.tints = ONTMHCCandidateDisplaySettings.defaultTints
        displayState.mhcCandidateDisplaySettings = settings
        notifyStateChanged()
    }

    public func updateMHCCandidatePersistenceWarning(_ warning: String?) {
        mhcCandidatePersistenceWarning = warning
    }

    func setLayout(_ layout: GenotypeResultPanelLayout) {
        displayState.layout = layout
        setNormalizedDisplayState(displayState)
        notifyStateChanged()
    }

    func setViewportLens(_ lens: GenotypeResultViewportLens) {
        displayState.viewportLens = lens
        setNormalizedDisplayState(displayState)
        notifyStateChanged()
    }

    public func setSummaryViewMode(_ mode: GenotypeSummaryViewMode) {
        displayState.viewportLens = .summary
        displayState.summaryViewMode = mode
        setNormalizedDisplayState(displayState)
        notifyStateChanged()
    }

    private func setNormalizedDisplayState(_ state: GenotypeResultDisplayState) {
        displayState = state.normalized(forGenotypeOnlyResult: isGenotypeOnlyResult)
    }

    func toggleHaplotypeGenotypeSummaryView() {
        setSummaryViewMode(displayState.summaryViewMode == .matrix ? .outline : .matrix)
    }

    func setHideLowSupport(_ enabled: Bool) {
        displayState.hideLowSupport = enabled
        notifyStateChanged()
    }

    func setMinimumSupportPercent(_ percent: Double) {
        displayState.minimumSupportPercent = max(0, min(100, percent))
        notifyStateChanged()
    }

    func setMinimumReads(_ value: Int) {
        displayState.minimumReads = max(0, value)
        notifyStateChanged()
    }

    func setMatrixMinimumReads(_ value: Int) {
        displayState.matrixMinimumReads = max(0, value)
        notifyStateChanged()
    }

    func setMatrixMinimumPercent(_ value: Double) {
        displayState.matrixMinimumPercent = max(0, min(100, value))
        notifyStateChanged()
    }

    func setMatrixPercentDenominator(_ denominator: ONTGenotypeSupportDenominator) {
        displayState.matrixPercentDenominator = denominator
        notifyStateChanged()
    }

    func setMatrixRowFilterText(_ value: String) {
        displayState.matrixRowFilterText = value
        notifyStateChanged()
    }

    func setMatrixSampleFilterText(_ value: String) {
        displayState.matrixSampleFilterText = value
        notifyStateChanged()
    }

    func showOnlySelectedMatrixRows() {
        onShowOnlySelectedMatrixRowsRequested?()
    }

    func showOnlySelectedMatrixColumns() {
        onShowOnlySelectedMatrixColumnsRequested?()
    }

    func clearMatrixSelectionFilter() {
        onClearMatrixSelectionFilterRequested?()
    }

    func setSupportDenominator(_ denominator: ONTGenotypeSupportDenominator) {
        displayState.supportDenominator = denominator
        notifyStateChanged()
    }

    func setCellColorMode(_ mode: GenotypeResultCellColorMode) {
        displayState.cellColorMode = mode
        notifyStateChanged()
    }

    func setHideFilteredHighlights(_ enabled: Bool) {
        displayState.hideFilteredHighlights = enabled
        notifyStateChanged()
    }

    public func setShowsAncillaryLoci(_ enabled: Bool) {
        displayState.showsAncillaryLoci = enabled
        notifyStateChanged()
    }

    public func setIncludedLoci(_ loci: Set<String>?) {
        displayState.includedLoci = loci
        notifyStateChanged()
    }

    public func updateSelection(_ selection: GenotypeResultSelectionState?) {
        isUpdatingFromSelection = true
        defer { isUpdatingFromSelection = false }

        genotypeResultSelection = selection
        genotypeHighlightColor = selection?.highlightStyle.fillColor.map(Self.swiftUIColor) ?? .blue
        genotypeBorderColor = selection?.highlightStyle.borderColor.map(Self.swiftUIColor) ?? .blue
        genotypeHighlightScope = selection?.highlightTarget?.sample == nil ? .selectedRow : .selectedCell
        genotypeHighlightChannel = selection?.highlightStyle.fillColor == nil && selection?.highlightStyle.borderColor != nil
            ? .border
            : .fill
    }

    public func updateMatrixReviewCapability(_ capability: GenotypeMatrixReviewCapabilityState) {
        matrixReviewCapability = capability
    }

    func setGenotypeHighlightChannel(_ channel: GenotypeResultHighlightChannel) {
        genotypeHighlightChannel = channel
    }

    func setGenotypeHighlightColor(_ color: NSColor) {
        guard let annotationColor = Self.annotationColor(from: color) else { return }
        let swiftUIColor = Self.swiftUIColor(from: annotationColor)
        switch genotypeHighlightChannel {
        case .fill:
            genotypeHighlightColor = swiftUIColor
        case .border:
            genotypeBorderColor = swiftUIColor
        }
        guard !isUpdatingFromSelection else { return }
        applyGenotypeHighlight(channel: genotypeHighlightChannel, annotationColor: annotationColor)
    }

    func clearGenotypeHighlight(_ channel: GenotypeResultHighlightChannel) {
        applyGenotypeHighlight(channel: channel, annotationColor: nil)
    }

    func revertGenotypeHighlightToDefault() {
        clearGenotypeHighlight(.fill)
        clearGenotypeHighlight(.border)
    }

    var selectedMatrixTargets: [GenotypeAnnotationSidecar.MatrixTarget] {
        genotypeResultSelection?.matrixTargets ?? []
    }

    var hasMatrixSelection: Bool {
        !selectedMatrixTargets.isEmpty
    }

    var canUseSupportedCellThreshold: Bool {
        selectedMatrixTargets.contains { target in
            switch target {
            case .row, .column:
                return true
            case .cell:
                return false
            }
        }
    }

    func setMatrixFillColor(_ color: NSColor) {
        matrixFillColor = Self.swiftUIColor(from: Self.annotationColor(from: color) ?? AnnotationColor(red: 1, green: 0.8, blue: 0, alpha: 1))
        applyMatrixStyle(.fillColor(Self.annotationColor(from: color)))
    }

    func setMatrixTextColor(_ color: NSColor) {
        matrixTextColor = Self.swiftUIColor(from: Self.annotationColor(from: color) ?? AnnotationColor(red: 0, green: 0, blue: 0, alpha: 1))
        applyMatrixStyle(.textColor(Self.annotationColor(from: color)))
    }

    func setMatrixBorderColor(_ color: NSColor) {
        matrixBorderColor = Self.swiftUIColor(from: Self.annotationColor(from: color) ?? AnnotationColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        applyMatrixStyle(.borderColor(Self.annotationColor(from: color)))
    }

    public var matrixQuickPaletteColors: [AnnotationColor] {
        matrixGenericQuickPaletteColors
    }

    public var matrixMCMQuickPaletteColors: [AnnotationColor] {
        HaplotypeColorToken.canonicalBudde2010Tokens.map(\.fillColor)
    }

    public var matrixGenericQuickPaletteColors: [AnnotationColor] {
        HaplotypeColorToken.genericOptimizedAnnotationPalette
    }

    public func applyMatrixPaletteColor(_ color: AnnotationColor) {
        switch matrixPaletteTarget {
        case .fill:
            setMatrixFillColor(Self.nsColor(from: color))
        case .text:
            setMatrixTextColor(Self.nsColor(from: color))
        case .border:
            setMatrixBorderColor(Self.nsColor(from: color))
        }
    }

    func setMatrixBold(_ enabled: Bool) {
        matrixIsBold = enabled
        applyMatrixStyle(.isBold(enabled))
    }

    func setMatrixItalic(_ enabled: Bool) {
        matrixIsItalic = enabled
        applyMatrixStyle(.isItalic(enabled))
    }

    func clearMatrixStyle() {
        applyMatrixStyle(.clear)
    }

    func addMatrixComment() {
        let body = matrixCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, hasMatrixSelection else { return }
        onMatrixCommentRequested?(GenotypeMatrixCommentEditRequest(
            targets: selectedMatrixTargets,
            intent: .upsert(body: body)
        ))
        matrixCommentText = ""
    }

    func setSupportedCellMinimumReads(_ minimumReads: Int) {
        supportedCellMinimumReads = max(0, minimumReads)
        onSupportSelectionPreviewChanged?(supportedCellMinimumReads)
    }

    var activeGenotypeHighlightNSColor: NSColor {
        switch genotypeHighlightChannel {
        case .fill:
            return Self.nsColor(from: genotypeHighlightColor)
        case .border:
            return Self.nsColor(from: genotypeBorderColor)
        }
    }

    private func applyGenotypeHighlight(
        channel: GenotypeResultHighlightChannel,
        annotationColor: AnnotationColor?
    ) {
        guard let target = genotypeResultSelection?.highlightTarget else { return }
        onGenotypeHighlightRequested?(
            GenotypeResultHighlightRequest(
                target: target,
                scope: genotypeHighlightScope,
                channel: channel,
                color: annotationColor
            )
        )
    }

    private func applyMatrixStyle(_ field: GenotypeMatrixStyleField) {
        guard hasMatrixSelection else { return }
        onMatrixStyleRequested?(
            GenotypeMatrixStyleRequest(
                targets: selectedMatrixTargets,
                field: field,
                minimumReads: canUseSupportedCellThreshold ? max(0, supportedCellMinimumReads) : nil
            )
        )
    }

    func notifyStateChanged() {
        onDisplayStateChanged?(displayState)
    }

    private static var emptyMatrixReviewCapability: GenotypeMatrixReviewCapabilityState {
        GenotypeMatrixReviewCapability.evaluate(
            selection: [],
            evidence: .init(),
            reviews: [],
            comments: [],
            isWritable: false
        )
    }

    private static func integrityWarningText(_ warning: ONTGenotypeIntegrityWarning) -> String {
        let location = warning.path.map { " (\($0))" } ?? ""
        return "\(warning.code.rawValue): \(warning.detail)\(location)"
    }

    private static func swiftUIColor(from annotationColor: AnnotationColor) -> Color {
        Color(
            red: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            opacity: annotationColor.alpha
        )
    }

    static func nsColor(from color: Color) -> NSColor {
        if let cgColor = color.cgColor {
            return NSColor(cgColor: cgColor) ?? .systemBlue
        }
        return NSColor(color)
    }

    static func nsColor(from annotationColor: AnnotationColor) -> NSColor {
        NSColor(
            srgbRed: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            alpha: annotationColor.alpha
        )
    }

    private static func annotationColor(from color: NSColor) -> AnnotationColor? {
        guard let rgbColor = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else {
            return nil
        }
        return AnnotationColor(
            red: rgbColor.redComponent,
            green: rgbColor.greenComponent,
            blue: rgbColor.blueComponent,
            alpha: rgbColor.alphaComponent
        )
    }
}

public struct GenotypeResultDisplaySection: View {
    @Bindable var viewModel: GenotypeResultDisplaySectionViewModel

    public init(viewModel: GenotypeResultDisplaySectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.isAvailable {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    if viewModel.mhcCandidateControlsAvailable
                        || !viewModel.mhcCandidateIntegrityWarnings.isEmpty
                        || viewModel.mhcCandidatePersistenceWarning != nil {
                        GenotypeCandidateEvidenceSection(viewModel: viewModel)
                    }
                    if viewModel.hasHaplotypingResult {
                        haplotypeGenotypeToggle
                    }
                    Divider()
                    if viewModel.showsViewportAndLayoutControls {
                        viewControls
                        layoutControls
                    }
                    thresholdGuidance
                    matrixFilterControls
                    colorControls
                    highlightControls
                    Text("Visual filters do not change genotype calls.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Label("Genotype Display", systemImage: "tablecells")
                    .font(.headline)
            }
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
        .controlSize(.small)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Rows", value: "\(viewModel.visibleRowCount) of \(viewModel.totalRowCount)")
            LabeledContent("Hidden Cells", value: "\(viewModel.hiddenCellCount)")
        }
        .font(.callout)
    }

    private var viewControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Viewport")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Viewport", selection: Binding(
                get: { viewModel.displayState.viewportLens },
                set: { viewModel.setViewportLens($0) }
            )) {
                ForEach(GenotypeResultViewportLens.allCases, id: \.self) { lens in
                    Label(lens.displayName, systemImage: lens.inspectorSystemImage)
                        .tag(lens)
                }
            }
            .pickerStyle(.radioGroup)
            .controlSize(.small)
            .labelsHidden()
        }
    }

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Panel Layout")
                .font(.caption)
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
            .controlSize(.small)
            .labelsHidden()
        }
    }

    private var thresholdGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Haplotype thresholds")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Thresholds are fixed by the genotyping run. Re-run miSeq amplicon MHC genotyping to change min reads or percent thresholds.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var matrixFilterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Matrix Filters")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Rows: locus, genotype, or sample", text: Binding(
                get: { viewModel.displayState.matrixRowFilterText },
                set: { viewModel.setMatrixRowFilterText($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            TextField("Samples", text: Binding(
                get: { viewModel.displayState.matrixSampleFilterText },
                set: { viewModel.setMatrixSampleFilterText($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            HStack(spacing: 8) {
                Button {
                    viewModel.showOnlySelectedMatrixRows()
                } label: {
                    Label("Rows", systemImage: "line.3.horizontal.decrease.circle")
                }
                .disabled(!viewModel.hasMatrixSelection)

                Button {
                    viewModel.showOnlySelectedMatrixColumns()
                } label: {
                    Label("Columns", systemImage: "rectangle.split.3x1")
                }
                .disabled(!viewModel.hasMatrixSelection)

                Button {
                    viewModel.clearMatrixSelectionFilter()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            Stepper(
                "Min reads: \(viewModel.displayState.matrixMinimumReads)",
                value: Binding(
                    get: { viewModel.displayState.matrixMinimumReads },
                    set: { viewModel.setMatrixMinimumReads($0) }
                ),
                in: 0...100_000
            )
            .controlSize(.small)
            Stepper(
                "Min percent: \(viewModel.displayState.matrixMinimumPercent, specifier: "%.1f")%",
                value: Binding(
                    get: { viewModel.displayState.matrixMinimumPercent },
                    set: { viewModel.setMatrixMinimumPercent($0) }
                ),
                in: 0...100,
                step: 0.5
            )
            .controlSize(.small)
            Picker("Percent Basis", selection: Binding(
                get: { viewModel.displayState.matrixPercentDenominator },
                set: { viewModel.setMatrixPercentDenominator($0) }
            )) {
                ForEach(ONTGenotypeSupportDenominator.allCases, id: \.self) { denominator in
                    Text(denominator.displayName).tag(denominator)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cell Color")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Cell Color", selection: Binding(
                get: { viewModel.displayState.cellColorMode },
                set: { viewModel.setCellColorMode($0) }
            )) {
                ForEach(GenotypeResultCellColorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var highlightControls: some View {
        if let target = viewModel.genotypeResultSelection?.highlightTarget {
            VStack(alignment: .leading, spacing: 8) {
                Text("Selected Highlight")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                valueRow(label: "Target", value: target.sample.map { "\(target.locus) / \($0)" } ?? target.locus)
                    .font(.caption)

                Picker("Target Scope", selection: $viewModel.genotypeHighlightScope) {
                    if target.sample != nil {
                        Text("Cell").tag(GenotypeResultHighlightScope.selectedCell)
                    }
                    Text("Row").tag(GenotypeResultHighlightScope.selectedRow)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)

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
                .controlSize(.small)

                HStack(spacing: 10) {
                    ContinuousColorWell(
                        color: viewModel.activeGenotypeHighlightNSColor,
                        onChange: { viewModel.setGenotypeHighlightColor($0) }
                    )
                    .frame(width: 44, height: 24)
                    Text(viewModel.genotypeHighlightChannel == .fill ? "Cell Fill" : "Outer Border")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        viewModel.clearGenotypeHighlight(.fill)
                    } label: {
                        Label("Clear Fill", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Button {
                        viewModel.clearGenotypeHighlight(.border)
                    } label: {
                        Label("Clear Border", systemImage: "square.dashed")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }

                Button {
                    viewModel.revertGenotypeHighlightToDefault()
                } label: {
                    Label("Revert to Default", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    private func valueRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
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
