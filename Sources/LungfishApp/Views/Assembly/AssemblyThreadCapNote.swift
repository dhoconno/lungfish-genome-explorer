// AssemblyThreadCapNote.swift - The line under the assembly dialog's Threads row that names MEGAHIT's thread cap
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishWorkflow

/// UX word W2 of Phase 2.13 lane 13.19, shown under the Threads row of the assembly dialog.
///
/// It shows only where the host caps MEGAHIT's threads (Apple silicon) and the chosen tool is MEGAHIT. The number in
/// it is ``AssemblyExecutionHost/megahitThreadCap``, the value the command builder and the run record read too.
struct AssemblyThreadCapNote: View {
    let tool: AssemblyTool
    var host: AssemblyExecutionHost = .current

    var body: some View {
        if let text = Self.text(tool: tool, host: host) {
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
                .accessibilityIdentifier("assembly-thread-cap-note")
        }
    }

    /// The note, or `nil` when `tool` is not MEGAHIT or `host` does not cap it.
    nonisolated static func text(tool: AssemblyTool, host: AssemblyExecutionHost = .current) -> String? {
        guard tool == .megahit, host.capsMegahitThreads else { return nil }
        let cap = AssemblyExecutionHost.megahitThreadCap
        let threads = cap == 1 ? "1 thread" : "\(cap) threads"
        return "On Apple silicon MEGAHIT runs on at most \(threads), because more threads can crash it."
    }
}
