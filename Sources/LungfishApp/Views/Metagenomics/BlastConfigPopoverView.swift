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
/// The slider range is 5...50, clamped to the number of available clade reads.
/// When the user clicks "Run BLAST", the ``onRun`` callback fires with the
/// selected read count.
struct BlastConfigPopoverView: View {

    /// The taxon name for the title label.
    let taxonName: String

    /// The number of reads in this taxon's clade (used to cap the slider).
    let readsClade: Int

    /// Callback fired when the user clicks "Run BLAST".
    let onRun: (Int) -> Void

    /// The selected number of reads to submit.
    @State private var readCount: Double = 20

    /// Maximum slider value, capped to available reads.
    private var maxReads: Double {
        Double(min(50, max(5, readsClade)))
    }

    /// Whether the "Run BLAST" button should be enabled.
    private var canRun: Bool {
        readsClade >= 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verify \"\(taxonName)\" via NCBI BLAST")
                .font(.headline)
                .lineLimit(2)

            HStack {
                Text("Reads to submit:")
                    .font(.subheadline)
                Slider(
                    value: $readCount,
                    in: 5...maxReads,
                    step: 1
                )
                .frame(minWidth: 80)
                Text("\(Int(readCount))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .frame(minWidth: 24, alignment: .trailing)
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
            // Clamp initial value to available reads
            readCount = min(readCount, maxReads)
        }
    }
}
