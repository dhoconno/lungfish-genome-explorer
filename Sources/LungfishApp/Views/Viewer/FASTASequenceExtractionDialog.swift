// FASTASequenceExtractionDialog.swift - Sequence-focused extraction sheet for FASTA-backed selections
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

@Observable
@MainActor
final class FASTASequenceExtractionDialogModel {
    let selectionCount: Int
    var destination: DialogDestination = .bundle
    var name: String

    init(selectionCount: Int, suggestedName: String) {
        self.selectionCount = selectionCount
        self.name = suggestedName
    }

    var primaryButtonTitle: String { destination.primaryButtonTitle }

    /// The words beside a destination's radio button.
    func label(for destination: DialogDestination) -> String { destination.label }
}

struct FASTASequenceExtractionDialog: View {
    @Bindable var model: FASTASequenceExtractionDialogModel

    var onCancel: () -> Void
    var onPrimary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Extract Sequence")
                    .font(.headline)
                Spacer()
                Text("\(model.selectionCount) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text("Destination:")
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(DialogDestination.allCases) { destination in
                            Button {
                                model.destination = destination
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: model.destination == destination ? "largecircle.fill.circle" : "circle")
                                    Text(destination.label)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("extraction-destination-\(destination.rawValue)")
                        }
                    }
                    Spacer()
                }

                if model.destination.showsNameField {
                    HStack {
                        Text("Name:")
                            .font(.system(size: 12))
                            .frame(width: 90, alignment: .trailing)
                        TextField("", text: $model.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .accessibilityIdentifier("extraction-bundle-name-field")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("extraction-cancel-button")
                Button(model.primaryButtonTitle, action: onPrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("extraction-extract-button")
            }
            .padding(16)
        }
        .frame(width: 420, height: 320)
        .padding(.top, 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extraction-configuration-sheet")
    }
}
