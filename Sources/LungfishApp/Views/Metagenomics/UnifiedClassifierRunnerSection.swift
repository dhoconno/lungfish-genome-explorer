// UnifiedClassifierRunnerSection.swift - Shared shell components for classifier runners
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

struct UnifiedClassifierRunnerSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UnifiedClassifierRunnerHeader: View {
    let title: String
    let subtitle: String
    let datasetLabel: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(datasetLabel)
                .font(.caption)
                .foregroundStyle(Color.lungfishSecondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.lungfishCanvasBackground)
    }
}

struct UnifiedClassifierRunnerFooter: View {
    let statusText: String?
    let isRunEnabled: Bool
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isRunEnabled ? Color.lungfishSecondaryText : Color.lungfishOrangeFallback)
            }

            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button("Run") {
                onRun()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isRunEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.lungfishCanvasBackground)
    }
}
