import AppKit
import LungfishCore
import SwiftUI

public struct GenotypeMatrixAnnotationSection: View {
    @Bindable var viewModel: GenotypeResultDisplaySectionViewModel

    public init(viewModel: GenotypeResultDisplaySectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Matrix Annotations")
                .font(.headline)

            if viewModel.hasMatrixSelection {
                selectedControls
            } else {
                Text("Select a matrix row, sample column, or cell to edit saved annotations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            valueRow(label: "Targets", value: "\(viewModel.selectedMatrixTargets.count)")
                .font(.caption)

            HStack(spacing: 10) {
                MatrixAnnotationColorWell(
                    color: GenotypeResultDisplaySectionViewModel.nsColor(from: viewModel.matrixFillColor),
                    onChange: { viewModel.setMatrixFillColor($0) }
                )
                .frame(width: 34, height: 22)
                Text("Fill")
                    .font(.caption)

                MatrixAnnotationColorWell(
                    color: GenotypeResultDisplaySectionViewModel.nsColor(from: viewModel.matrixTextColor),
                    onChange: { viewModel.setMatrixTextColor($0) }
                )
                .frame(width: 34, height: 22)
                Text("Text")
                    .font(.caption)
            }

            HStack(spacing: 10) {
                MatrixAnnotationColorWell(
                    color: GenotypeResultDisplaySectionViewModel.nsColor(from: viewModel.matrixBorderColor),
                    onChange: { viewModel.setMatrixBorderColor($0) }
                )
                .frame(width: 34, height: 22)
                Text("Border")
                    .font(.caption)

                Toggle("B", isOn: Binding(
                    get: { viewModel.matrixIsBold },
                    set: { viewModel.setMatrixBold($0) }
                ))
                .toggleStyle(.button)
                .controlSize(.small)

                Toggle("I", isOn: Binding(
                    get: { viewModel.matrixIsItalic },
                    set: { viewModel.setMatrixItalic($0) }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
            }

            paletteControls

            Button {
                viewModel.clearMatrixStyle()
            } label: {
                Label("Clear Style", systemImage: "eraser")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            TextField("Comment", text: $viewModel.matrixCommentText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .controlSize(.small)

            Button {
                viewModel.addMatrixComment()
            } label: {
                Label("Add Comment", systemImage: "text.bubble")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(viewModel.matrixCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if viewModel.canSelectSupportedCellsInCurrentRow {
                HStack(spacing: 8) {
                    Stepper(
                        "Supported cells: \(viewModel.supportedCellMinimumReads)",
                        value: $viewModel.supportedCellMinimumReads,
                        in: 0...100_000
                    )
                    .controlSize(.small)
                    Button {
                        viewModel.selectSupportedCellsInCurrentRow()
                    } label: {
                        Label("Select", systemImage: "scope")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            Text("Edits are saved to annotations.json and synced to current.xlsx.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var paletteControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Colors")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Palette Target", selection: $viewModel.matrixPaletteTarget) {
                ForEach(GenotypeMatrixPaletteTarget.allCases) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            paletteGrid(
                title: "mcm",
                colors: viewModel.matrixMCMQuickPaletteColors
            )
            paletteGrid(
                title: "generic",
                colors: viewModel.matrixGenericQuickPaletteColors
            )
        }
    }

    private func paletteGrid(title: String, colors: [AnnotationColor]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: 8), spacing: 4) {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    Button {
                        viewModel.applyMatrixPaletteColor(color)
                    } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(swiftUIColor(from: color))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color(nsColor: NSColor.separatorColor), lineWidth: 0.5)
                            )
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("\(title) color \(index + 1) \(color.hexString)")
                }
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

    private func swiftUIColor(from color: AnnotationColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

private struct MatrixAnnotationColorWell: NSViewRepresentable {
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
