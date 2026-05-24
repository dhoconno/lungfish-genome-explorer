import AppKit
import SwiftUI
import LungfishCore
import LungfishIO

@Observable
@MainActor
final class GenotypeResultDisplaySectionViewModel {
    var displayState = GenotypeResultDisplayState()
    var isAvailable = false
    var visibleRowCount = 0
    var totalRowCount = 0
    var hiddenCellCount = 0
    var isExpanded = true
    var genotypeResultSelection: GenotypeResultSelectionState?
    var genotypeHighlightColor: Color = .blue
    var genotypeBorderColor: Color = .blue
    var genotypeHighlightScope: GenotypeResultHighlightScope = .selectedCell
    var genotypeHighlightChannel: GenotypeResultHighlightChannel = .fill

    var onDisplayStateChanged: ((GenotypeResultDisplayState) -> Void)?
    var onGenotypeHighlightRequested: ((GenotypeResultHighlightRequest) -> Void)?

    @ObservationIgnored
    private var isUpdatingFromSelection = false

    func update(isAvailable: Bool, state: GenotypeResultDisplayState = GenotypeResultDisplayState()) {
        self.isAvailable = isAvailable
        self.displayState = state
        updateSelection(nil)
    }

    func updateSummary(visibleRows: Int, totalRows: Int, hiddenCells: Int) {
        visibleRowCount = visibleRows
        totalRowCount = totalRows
        hiddenCellCount = hiddenCells
    }

    func updateDisplayState(_ state: GenotypeResultDisplayState) {
        displayState = state
    }

    func clear() {
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

    func setSummaryViewMode(_ mode: GenotypeSummaryViewMode) {
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

    func setShowsAncillaryLoci(_ enabled: Bool) {
        displayState.showsAncillaryLoci = enabled
        notifyStateChanged()
    }

    func updateSelection(_ selection: GenotypeResultSelectionState?) {
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

struct GenotypeResultDisplaySection: View {
    @Bindable var viewModel: GenotypeResultDisplaySectionViewModel

    var body: some View {
        if viewModel.isAvailable {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    Divider()
                    viewControls
                    layoutControls
                    supportControls
                    colorControls
                    highlightControls
                    Text("Filtering and colors are viewport aids. They do not change genotype calls or write analyst annotations to the bundle.")
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

    private var supportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.displayState.hideLowSupport },
                set: { viewModel.setHideLowSupport($0) }
            )) {
                Text("Hide Low Support")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minimum")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Minimum", value: Binding(
                        get: { viewModel.displayState.minimumSupportPercent },
                        set: { viewModel.setMinimumSupportPercent($0) }
                    ), format: .number.precision(.fractionLength(1)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 58)
                    .disabled(!viewModel.displayState.hideLowSupport)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    Text("%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { viewModel.displayState.minimumSupportPercent },
                        set: { viewModel.setMinimumSupportPercent($0) }
                    ),
                    in: 0...100,
                    step: 0.1
                )
                .disabled(!viewModel.displayState.hideLowSupport)
                .controlSize(.small)
            }

            Toggle(isOn: Binding(
                get: { viewModel.displayState.hideFilteredHighlights },
                set: { viewModel.setHideFilteredHighlights($0) }
            )) {
                Text("Hide Filtered Highlights")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!viewModel.displayState.hideLowSupport)

            Picker("Denominator", selection: Binding(
                get: { viewModel.displayState.supportDenominator },
                set: { viewModel.setSupportDenominator($0) }
            )) {
                ForEach(ONTGenotypeSupportDenominator.allCases, id: \.self) { denominator in
                    Text(denominator.displayName).tag(denominator)
                }
            }
            .pickerStyle(.menu)
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
