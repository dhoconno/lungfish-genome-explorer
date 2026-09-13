// ProvenanceSection.swift - Generic Inspector provenance browser
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishGenotypeUI
import LungfishKit
import SwiftUI

struct ProvenanceSection: View {
    @Bindable var viewModel: ProvenanceInspectorViewModel
    let usesGenotypePresentation: Bool

    @State private var isRunSummaryExpanded = true
    @State private var isWarningsExpanded = true
    @State private var isLineageExpanded = true
    @State private var isFilesExpanded = true
    @State private var isOptionsExpanded = false
    @State private var isRuntimeExpanded = false
    @State private var isRawJSONExpanded = false

    init(
        viewModel: ProvenanceInspectorViewModel,
        usesGenotypePresentation: Bool = false,
        detailsInitiallyExpanded: Bool = false
    ) {
        self.viewModel = viewModel
        self.usesGenotypePresentation = usesGenotypePresentation
        _isOptionsExpanded = State(initialValue: detailsInitiallyExpanded)
        _isRuntimeExpanded = State(initialValue: detailsInitiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if viewModel.sources.count > 1 {
                Picker("Source", selection: Binding(
                    get: { viewModel.selectedSourceID },
                    set: { viewModel.selectSource(id: $0) }
                )) {
                    ForEach(viewModel.sources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .font(LungfishInspectorStyle.controlFont)
                .accessibilityIdentifier("provenance-source-picker")
            }

            if shouldShowSearch {
                TextField("Filter provenance", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(LungfishInspectorStyle.controlFont)
                    .accessibilityIdentifier("provenance-filter-field")
            }

            DisclosureGroup("Run Summary", isExpanded: $isRunSummaryExpanded) {
                runSummaryContent
                    .padding(.top, 4)
            }
            .font(LungfishInspectorStyle.controlFont.weight(.semibold))
            .accessibilityIdentifier("provenance-run-summary")

            if !viewModel.warnings.isEmpty {
                DisclosureGroup("Warnings", isExpanded: $isWarningsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.warnings) { warning in
                            warningRow(warning)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(LungfishInspectorStyle.controlFont.weight(.semibold))
                .accessibilityIdentifier("provenance-warnings")
            }

            DisclosureGroup("Lineage", isExpanded: $isLineageExpanded) {
                lineageContent
                    .padding(.top, 4)
            }
            .font(LungfishInspectorStyle.controlFont.weight(.semibold))
            .accessibilityIdentifier("provenance-step-list")

            DisclosureGroup("Files & Outputs", isExpanded: $isFilesExpanded) {
                filesContent
                    .padding(.top, 4)
            }
            .font(LungfishInspectorStyle.controlFont.weight(.semibold))
            .accessibilityIdentifier("provenance-files")

            DisclosureGroup("Invocation & Options", isExpanded: $isOptionsExpanded) {
                optionsContent
                    .padding(.top, 4)
            }
            .font(LungfishInspectorStyle.controlFont.weight(.semibold))
            .accessibilityIdentifier("provenance-options")

            DisclosureGroup("Runtime", isExpanded: $isRuntimeExpanded) {
                runtimeContent
                    .padding(.top, 4)
            }
            .font(LungfishInspectorStyle.controlFont.weight(.semibold))
            .accessibilityIdentifier("provenance-runtime")

            DisclosureGroup("Raw JSON", isExpanded: $isRawJSONExpanded) {
                rawJSONContent
                    .padding(.top, 4)
            }
            .font(LungfishInspectorStyle.controlFont.weight(.semibold))
            .accessibilityIdentifier("provenance-raw-json")
        }
        .accessibilityIdentifier("provenance-root")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if usesGenotypePresentation {
                Text("Provenance")
                    .font(LungfishInspectorStyle.sectionTitleFont)
                    .fixedSize(horizontal: true, vertical: false)
                headerActions
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Provenance")
                        .font(LungfishInspectorStyle.sectionTitleFont)
                    Spacer()
                    headerActions
                }
            }

            statusLabel

            if viewModel.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading provenance...")
                        .font(LungfishInspectorStyle.controlFont)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("provenance-loading-indicator")
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        let label = Label(viewModel.summary.statusLabel, systemImage: statusSymbol)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(statusForegroundStyle)
        if usesGenotypePresentation {
            label.fixedSize(horizontal: false, vertical: true)
        } else {
            label
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                copyToPasteboard(viewModel.copyableText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .font(LungfishInspectorStyle.controlFont)
            .help("Copy provenance text")
            .accessibilityLabel("Copy provenance text")
            .accessibilityHint("Copies every displayed provenance record as text.")
            .disabled(viewModel.isLoading || viewModel.copyableText.isEmpty)
            .accessibilityIdentifier("provenance-copy-text")
            Menu {
                ForEach(ProvenanceExportMenuModel.items, id: \.format) { item in
                    Button(item.title) {
                        viewModel.export(format: item.format)
                    }
                    .disabled(viewModel.resolvedEnvelope == nil)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.button)
            .font(LungfishInspectorStyle.controlFont)
            .disabled(viewModel.resolvedEnvelope == nil)
            .accessibilityIdentifier("provenance-export-menu")
        }
    }

    private var runSummaryContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryRow("Workflow", value: viewModel.summary.workflowName)
            if !viewModel.summary.workflowVersion.isEmpty {
                summaryRow("Workflow Version", value: viewModel.summary.workflowVersion)
            }
            if !viewModel.summary.toolName.isEmpty {
                summaryRow("Tool", value: toolLabel)
            }
            if let createdAt = viewModel.summary.createdAt {
                summaryRow("Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let exitStatus = viewModel.summary.exitStatus {
                summaryRow("Exit Status", value: "\(exitStatus)")
            }
            if let wallTime = viewModel.summary.wallTimeSeconds {
                summaryRow("Wall Time", value: formatDuration(wallTime))
            }
            summaryRow("Steps", value: "\(viewModel.summary.stepCount)")
            summaryRow("Inputs", value: "\(viewModel.summary.inputCount)")
            summaryRow("Outputs", value: "\(viewModel.summary.outputCount)")
            if viewModel.summary.signatureCount > 0 {
                summaryRow("Signatures", value: "\(viewModel.summary.signatureCount)")
            }
            if let sidecarPath = viewModel.summary.sidecarPath {
                summaryRow("Sidecar", value: sidecarPath)
            }
        }
    }

    private var lineageContent: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if viewModel.lineageRuns.isEmpty {
                emptyMessage("No workflow steps are available.")
            } else {
                ForEach(viewModel.lineageRuns) { run in
                    if runMatchesSearch(run) {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(run.steps) { step in
                                    if stepMatchesSearch(step) {
                                        stepDisclosure(step)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.title)
                                    .font(LungfishInspectorStyle.controlFont)
                                lineageSubtitle(run.subtitle)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func lineageSubtitle(_ subtitle: String) -> some View {
        let text = Text(subtitle)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.secondary)
        if usesGenotypePresentation {
            text.fixedSize(horizontal: false, vertical: true)
        } else {
            text.lineLimit(2)
        }
    }

    private var filesContent: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if filteredFiles.isEmpty {
                emptyMessage("No file descriptors are available.")
            } else {
                ForEach(filteredFiles) { row in
                    fileRow(row)
                }
            }
        }
    }

    private var optionsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if filteredOptions.isEmpty {
                emptyMessage("No explicit or resolved option values are available.")
            } else {
                ForEach(filteredOptions) { row in
                    summaryRow("\(row.name) (\(row.kind))", value: row.value)
                }
            }
        }
    }

    private var runtimeContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if filteredRuntimeRows.isEmpty {
                emptyMessage("No runtime identity fields are available.")
            } else {
                ForEach(filteredRuntimeRows) { row in
                    summaryRow(row.label, value: row.value)
                }
            }
        }
    }

    private var rawJSONContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.rawJSON.isEmpty {
                emptyMessage("No raw provenance JSON is available.")
            } else {
                HStack {
                    Spacer()
                    Button {
                        copyToPasteboard(viewModel.rawJSON)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .font(LungfishInspectorStyle.controlFont)
                    .accessibilityIdentifier("provenance-copy-json")
                }

                SelectableWrappingText(
                    viewModel.rawJSON,
                    font: ContentTypographyModel.shared.resolvedNSFont(for: .monospaced),
                    maximumNumberOfLines: 80,
                    accessibilityIdentifier: "provenance-raw-json-text"
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func warningRow(_ warning: ProvenanceWarningRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(warning.title)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.primary)
            Text(warning.message)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func stepDisclosure(_ step: ProvenanceLineageStep) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if !step.command.isEmpty {
                    summaryRow("Command", value: step.command)
                }
                if !step.inputPaths.isEmpty {
                    pathList("Inputs", step.inputPaths)
                }
                if !step.outputPaths.isEmpty {
                    pathList("Outputs", step.outputPaths)
                }
                if let exitStatus = step.exitStatus {
                    summaryRow("Exit Status", value: "\(exitStatus)")
                }
                if let wallTime = step.wallTimeSeconds {
                    summaryRow("Wall Time", value: formatDuration(wallTime))
                }
                if let stderr = step.stderr {
                    summaryRow("stderr", value: stderr.isEmpty ? "(empty)" : stderr)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(step.ordinal).")
                    .font(LungfishInspectorStyle.controlFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.toolName)
                        .font(LungfishInspectorStyle.controlFont)
                    if !step.toolVersion.isEmpty {
                        Text(step.toolVersion)
                            .font(LungfishInspectorStyle.controlFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func fileRow(_ row: ProvenanceFileRow) -> some View {
        Group {
            if usesGenotypePresentation {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.role)
                        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    filePathText(row)
                    Text(fileMetadataSummary(for: row))
                        .font(LungfishInspectorStyle.controlFont)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    fileChecksumText(row)
                }
            } else {
                legacyFileRow(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legacyFileRow(_ row: ProvenanceFileRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.role)
                    .font(LungfishInspectorStyle.controlFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
                filePathText(row)
            }
            Text(fileMetadataSummary(for: row))
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.tertiary)
            .padding(.leading, 68)

            fileChecksumText(row)
                .padding(.leading, 68)
        }
    }

    private func filePathText(_ row: ProvenanceFileRow) -> some View {
        Text(row.displayPath)
            .font(LungfishInspectorStyle.controlFont)
            .lineLimit(usesGenotypePresentation ? nil : 2)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: usesGenotypePresentation)
            .textSelection(.enabled)
            .accessibilityIdentifier("provenance-file-path")
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.path)
    }

    @ViewBuilder
    private func fileChecksumText(_ row: ProvenanceFileRow) -> some View {
        if let checksum = row.checksumSHA256, !checksum.isEmpty {
            Text("sha256 \(checksum)")
                .font(LungfishInspectorStyle.controlFont.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(usesGenotypePresentation ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: usesGenotypePresentation)
                .textSelection(.enabled)
                .accessibilityIdentifier("provenance-file-checksum")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fileMetadataSummary(for row: ProvenanceFileRow) -> String {
        var parts = [row.fileSizeLabel]
        if let format = row.format, !format.isEmpty {
            parts.append("Format: \(format)")
        }
        return parts.joined(separator: " | ")
    }

    private func pathList(_ label: String, _ paths: [String]) -> some View {
        summaryRow(label, value: paths.joined(separator: "\n"), accessibilityIdentifier: "provenance-path-list-value")
    }

    private func summaryRow(
        _ label: String,
        value: String,
        accessibilityIdentifier: String = "provenance-summary-value"
    ) -> some View {
        Group {
            if usesGenotypePresentation {
                GenotypeInspectorValueRow(
                    label,
                    value: value,
                    font: LungfishInspectorStyle.controlFont,
                    valueAccessibilityIdentifier: accessibilityIdentifier
                )
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Text(label)
                        .font(LungfishInspectorStyle.controlFont)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .trailing)
                    summaryValueText(value, accessibilityIdentifier: accessibilityIdentifier)
                }
            }
        }
    }

    private func summaryValueText(
        _ value: String,
        accessibilityIdentifier: String
    ) -> some View {
        Text(value)
            .font(LungfishInspectorStyle.controlFont)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier(accessibilityIdentifier)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldShowSearch: Bool {
        viewModel.summary.stepCount > 6
            || viewModel.fileRows.count > 8
            || viewModel.optionRows.count > 8
    }

    private var normalizedSearch: String {
        viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredFiles: [ProvenanceFileRow] {
        guard !normalizedSearch.isEmpty else { return viewModel.fileRows }
        return viewModel.fileRows.filter {
            matchesSearch($0.role)
                || matchesSearch($0.path)
                || matchesSearch($0.format ?? "")
                || matchesSearch($0.checksumSHA256 ?? "")
                || matchesSearch($0.searchText)
        }
    }

    private var filteredOptions: [ProvenanceOptionRow] {
        guard !normalizedSearch.isEmpty else { return viewModel.optionRows }
        return viewModel.optionRows.filter {
            matchesSearch($0.kind) || matchesSearch($0.name) || matchesSearch($0.value)
        }
    }

    private var filteredRuntimeRows: [ProvenanceRuntimeRow] {
        guard !normalizedSearch.isEmpty else { return viewModel.runtimeRows }
        return viewModel.runtimeRows.filter {
            matchesSearch($0.label) || matchesSearch($0.value)
        }
    }

    private var toolLabel: String {
        guard !viewModel.summary.toolVersion.isEmpty else {
            return viewModel.summary.toolName
        }
        return "\(viewModel.summary.toolName) \(viewModel.summary.toolVersion)"
    }

    private var statusSymbol: String {
        switch viewModel.audit.status {
        case .present:
            return "checkmark.seal"
        case .missing, .invalid, .incomplete, .stale:
            return "exclamationmark.triangle"
        case .legacy:
            return "clock.arrow.circlepath"
        case .notRequired:
            return "info.circle"
        }
    }

    private var statusForegroundStyle: HierarchicalShapeStyle {
        viewModel.audit.isBlocking ? .primary : .secondary
    }

    private func runMatchesSearch(_ run: ProvenanceLineageRun) -> Bool {
        guard !normalizedSearch.isEmpty else { return true }
        return matchesSearch(run.title)
            || matchesSearch(run.subtitle)
            || run.steps.contains(where: stepMatchesSearch)
    }

    private func stepMatchesSearch(_ step: ProvenanceLineageStep) -> Bool {
        guard !normalizedSearch.isEmpty else { return true }
        return matchesSearch(step.toolName)
            || matchesSearch(step.toolVersion)
            || matchesSearch(step.command)
            || step.inputPaths.contains(where: matchesSearch)
            || step.outputPaths.contains(where: matchesSearch)
            || matchesSearch(step.stderr ?? "")
    }

    private func matchesSearch(_ value: String) -> Bool {
        guard !normalizedSearch.isEmpty else { return true }
        return value.localizedCaseInsensitiveContains(normalizedSearch)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        LungfishFormatters.formatDuration(seconds)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
