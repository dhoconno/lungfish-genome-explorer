// ReadStyleSection.swift - Mapped reads style inspector section
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

@Observable
@MainActor
public final class ReadStyleSectionViewModel {
    public var readHeight: Double = 10
    public var showMismatches: Bool = true
    public var stackByStrand: Bool = true
    public var forwardReadColor: Color = Color(red: 0.21, green: 0.55, blue: 0.92)
    public var reverseReadColor: Color = Color(red: 0.86, green: 0.42, blue: 0.32)
}

public struct ReadStyleSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel
    @State private var isExpanded = true

    public init(viewModel: ReadStyleSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("BAM/CRAM rendering is coming soon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("These controls are preview-only until mapped read loading is implemented.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Read Height")
                        Spacer()
                        Text("\(Int(viewModel.readHeight)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $viewModel.readHeight, in: 6...20, step: 1)

                    Toggle("Show Mismatches", isOn: $viewModel.showMismatches)
                    Toggle("Stack by Strand", isOn: $viewModel.stackByStrand)

                    HStack {
                        Text("Forward")
                        Spacer()
                        ColorPicker("", selection: $viewModel.forwardReadColor, supportsOpacity: false)
                            .labelsHidden()
                    }

                    HStack {
                        Text("Reverse")
                        Spacer()
                        ColorPicker("", selection: $viewModel.reverseReadColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                .disabled(true)
            }
            .padding(.top, 8)
        } label: {
            Text("Read Style")
                .font(.headline)
        }
    }
}

