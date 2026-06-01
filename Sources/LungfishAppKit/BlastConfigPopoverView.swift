// BlastConfigPopoverView.swift - Popover for configuring BLAST verification
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// A compact SwiftUI view shown in an NSPopover when the user selects
/// "BLAST Matching Reads..." from a taxon's context menu.
///
/// ## Layout
///
/// ```
/// +---------------------------------------+
/// | Verify "E. coli" via NCBI BLAST       |
/// |                                       |
/// | Reads to submit:  [===|===] 20        |
/// |                                       |
/// | Submits a sample of classified reads  |
/// | to NCBI BLAST for verification.       |
/// |                                       |
/// |                        [Run BLAST]    |
/// +---------------------------------------+
/// ```
///
/// The slider range is 1...50, clamped to the number of available clade reads.
/// When the user clicks "Run BLAST", the ``onRun`` callback fires with the
/// selected read count.
public struct BlastConfigPopoverView: View {

    /// The taxon name for the title label.
    let taxonName: String

    /// The number of reads in this taxon's clade (used to cap the slider).
    let readsClade: Int

    /// Callback fired when the user clicks "Run BLAST".
    let onRun: (Int) -> Void

    /// The selected number of reads to submit.
    @State private var readCount: Double = 20

    public init(taxonName: String, readsClade: Int, onRun: @escaping (Int) -> Void) {
        self.taxonName = taxonName
        self.readsClade = readsClade
        self.onRun = onRun
    }

    /// Maximum slider value, capped to available reads.
    private var maxReads: Int {
        min(50, max(1, readsClade))
    }

    /// Whether the slider should be shown (needs at least 2 distinct values).
    private var showsSlider: Bool {
        maxReads >= 2
    }

    /// Whether the "Run BLAST" button should be enabled.
    private var canRun: Bool {
        readsClade >= 1
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verify \"\(taxonName)\" via NCBI BLAST")
                .font(.headline)
                .lineLimit(2)

            if showsSlider {
                HStack {
                    Text("Reads to submit:")
                        .font(.subheadline)
                    Slider(
                        value: $readCount,
                        in: 1...Double(maxReads),
                        step: 1
                    )
                    .frame(minWidth: 80)
                    Text("\(Int(readCount))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .frame(minWidth: 24, alignment: .trailing)
                }
            } else {
                Text("Reads to submit: \(maxReads)")
                    .font(.subheadline)
            }

            Text("Submits a sample of classified reads to NCBI BLAST for independent verification.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Run BLAST") {
                    onRun(Int(readCount))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            readCount = min(Double(min(20, maxReads)), Double(maxReads))
        }
    }
}
