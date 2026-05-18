// DialogSheets.swift - Shared SwiftUI sheet primitives
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

struct WizardSheetSize: Equatable {
    let width: CGFloat
    let height: CGFloat

    static let standard = WizardSheetSize(width: 520, height: 480)
}

struct ImportSheetSize: Equatable {
    let width: CGFloat
    let height: CGFloat

    static let standard = ImportSheetSize(width: 520, height: 480)
}

struct WizardSheet<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    let accessoryText: String?
    let size: WizardSheetSize
    let statusText: String?
    let statusColor: Color
    let cancelTitle: String
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    let onCancel: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String,
        accessoryText: String? = nil,
        size: WizardSheetSize = .standard,
        statusText: String? = nil,
        statusColor: Color = .secondary,
        cancelTitle: String = "Cancel",
        primaryTitle: String = "Run",
        isPrimaryEnabled: Bool,
        onCancel: @escaping () -> Void,
        onPrimary: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessoryText = accessoryText
        self.size = size
        self.statusText = statusText
        self.statusColor = statusColor
        self.cancelTitle = cancelTitle
        self.primaryTitle = primaryTitle
        self.isPrimaryEnabled = isPrimaryEnabled
        self.onCancel = onCancel
        self.onPrimary = onPrimary
        self.icon = icon
        self.content = content
    }

    var body: some View {
        DialogSheetFrame(
            title: title,
            subtitle: subtitle,
            accessoryText: accessoryText,
            width: size.width,
            height: size.height,
            statusText: statusText,
            statusColor: statusColor,
            cancelTitle: cancelTitle,
            primaryTitle: primaryTitle,
            isPrimaryEnabled: isPrimaryEnabled,
            onCancel: onCancel,
            onPrimary: onPrimary,
            icon: icon,
            content: content
        )
    }
}

struct ImportSheet<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    let accessoryText: String?
    let size: ImportSheetSize
    let statusText: String?
    let statusColor: Color
    let cancelTitle: String
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    let onCancel: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String,
        accessoryText: String? = nil,
        size: ImportSheetSize = .standard,
        statusText: String? = nil,
        statusColor: Color = .secondary,
        cancelTitle: String = "Cancel",
        primaryTitle: String = "Run",
        isPrimaryEnabled: Bool,
        onCancel: @escaping () -> Void,
        onPrimary: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessoryText = accessoryText
        self.size = size
        self.statusText = statusText
        self.statusColor = statusColor
        self.cancelTitle = cancelTitle
        self.primaryTitle = primaryTitle
        self.isPrimaryEnabled = isPrimaryEnabled
        self.onCancel = onCancel
        self.onPrimary = onPrimary
        self.icon = icon
        self.content = content
    }

    var body: some View {
        DialogSheetFrame(
            title: title,
            subtitle: subtitle,
            accessoryText: accessoryText,
            width: size.width,
            height: size.height,
            statusText: statusText,
            statusColor: statusColor,
            cancelTitle: cancelTitle,
            primaryTitle: primaryTitle,
            isPrimaryEnabled: isPrimaryEnabled,
            onCancel: onCancel,
            onPrimary: onPrimary,
            icon: icon,
            content: content
        )
    }
}

private struct DialogSheetFrame<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    let accessoryText: String?
    let width: CGFloat
    let height: CGFloat
    let statusText: String?
    let statusColor: Color
    let cancelTitle: String
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    let onCancel: () -> Void
    let onPrimary: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogSheetHeader(
                title: title,
                subtitle: subtitle,
                accessoryText: accessoryText,
                icon: icon
            )

            Divider()

            ScrollView {
                content()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }

            Divider()

            DialogSheetFooter(
                statusText: statusText,
                statusColor: statusColor,
                cancelTitle: cancelTitle,
                primaryTitle: primaryTitle,
                isPrimaryEnabled: isPrimaryEnabled,
                onCancel: onCancel,
                onPrimary: onPrimary
            )
        }
        .frame(width: width, height: height)
    }
}

private struct DialogSheetHeader<Icon: View>: View {
    let title: String
    let subtitle: String
    let accessoryText: String?
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 10) {
            icon()

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let accessoryText, !accessoryText.isEmpty {
                Text(accessoryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

private struct DialogSheetFooter: View {
    let statusText: String?
    let statusColor: Color
    let cancelTitle: String
    let primaryTitle: String
    let isPrimaryEnabled: Bool
    let onCancel: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        HStack {
            if let statusText, !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Spacer()

            Button(cancelTitle) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button(primaryTitle) {
                onPrimary()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isPrimaryEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
