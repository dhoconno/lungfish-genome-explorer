import AppKit
import SwiftUI
import LungfishCore
import LungfishIO

@Observable
@MainActor
public final class GenotypeResultDisplaySectionViewModel {
    public var displayState = GenotypeResultDisplayState()
    public var isAvailable = false
    public var visibleRowCount = 0
    public var totalRowCount = 0
    public var hiddenCellCount = 0
    public var isExpanded = true
    public var genotypeResultSelection: GenotypeResultSelectionState?
    public var genotypeHighlightColor: Color = .blue
    public var genotypeBorderColor: Color = .blue
    public var genotypeHighlightScope: GenotypeResultHighlightScope = .selectedCell
    public var genotypeHighlightChannel: GenotypeResultHighlightChannel = .fill

    public var onDisplayStateChanged: ((GenotypeResultDisplayState) -> Void)?
    public var onGenotypeHighlightRequested: ((GenotypeResultHighlightRequest) -> Void)?

    @ObservationIgnored
    private var isUpdatingFromSelection = false

    public init() {}

    public func update(isAvailable: Bool, state: GenotypeResultDisplayState = GenotypeResultDisplayState()) {
        self.isAvailable = isAvailable
        self.displayState = state
        updateSelection(nil)
    }

    public func updateSummary(visibleRows: Int, totalRows: Int, hiddenCells: Int) {
        visibleRowCount = visibleRows
        totalRowCount = totalRows
        hiddenCellCount = hiddenCells
    }

    public func updateDisplayState(_ state: GenotypeResultDisplayState) {
        displayState = state
    }

    public func clear() {
        isAvailable = false
        displayState = GenotypeResultDisplayState()
        visibleRowCount = 0
        totalRowCount = 0
        hiddenCellCount = 0
        updateSelection(nil)
    }

    func setLayout(_ layout: GenotypeResultPanelLayout) {
        displayState.layout = layout
        notifyStateChanged()
    }

    func setViewportLens(_ lens: GenotypeResultViewportLens) {
        displayState.viewportLens = lens
        notifyStateChanged()
    }

    public func setSummaryViewMode(_ mode: GenotypeSummaryViewMode) {
        displayState.viewportLens = .summary
        displayState.summaryViewMode = mode
        notifyStateChanged()
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

    private func notifyStateChanged() {
        onDisplayStateChanged?(displayState)
    }

    private static func swiftUIColor(from annotationColor: AnnotationColor) -> Color {
        Color(
            red: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            opacity: annotationColor.alpha
        )
    }

    private static func nsColor(from color: Color) -> NSColor {
        if let cgColor = color.cgColor {
            return NSColor(cgColor: cgColor) ?? .systemBlue
        }
        return NSColor(color)
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
                    Divider()
                    viewControls
                    layoutControls
                    thresholdGuidance
                    colorControls
                    highlightControls
                    Text("Viewport colors are display aids. They do not change genotype calls or write analyst annotations to the bundle.")
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
