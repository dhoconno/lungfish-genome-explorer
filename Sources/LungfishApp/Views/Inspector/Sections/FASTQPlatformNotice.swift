// FASTQPlatformNotice.swift - Inspector notice for a FASTQ bundle whose recorded platform the reads contradict
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

/// Shown in the FASTQ metadata section when a bundle imported before platform
/// inference records a platform its reads contradict. Nothing changes until a
/// person chooses. Both buttons run `lungfish-cli fastq platform`, so the
/// choice is recorded and the notice does not return.
struct FASTQPlatformNotice: View {
    let check: PlatformLabelCheck
    let onUseSuggested: () -> Void
    let onKeep: () -> Void

    /// The notice text, also its accessibility label.
    static func message(for check: PlatformLabelCheck) -> String {
        let recorded = check.recordedReadClass?.displayName ?? check.recordedPlatform?.displayName ?? "no platform"
        return "Recorded as \(recorded). \(check.reasons.joined(separator: " ")) Analyses that used this bundle chose tools for the recorded read type."
    }

    static func keepTitle(for check: PlatformLabelCheck) -> String {
        "Keep \(check.recordedPlatform?.displayName ?? "Recorded")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(Self.message(for: check))
                    .font(LungfishInspectorStyle.controlFont)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.lungfishOrangeFallback)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                if let suggested = check.suggestedPlatform {
                    Button("Use \(suggested.displayName)", action: onUseSuggested)
                        .accessibilityHint("Records \(suggested.displayName) with lungfish-cli fastq platform --set")
                }
                Button(Self.keepTitle(for: check), action: onKeep)
                    .accessibilityHint("Keeps the recorded platform and stops this notice")
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.lungfishOrangeFallback.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("fastq-platform-notice")
    }
}
