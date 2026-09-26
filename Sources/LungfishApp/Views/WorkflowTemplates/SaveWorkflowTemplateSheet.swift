// SaveWorkflowTemplateSheet.swift - SwiftUI sheet that saves a Kraken2 analysis as a workflow template
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishKit
import LungfishWorkflow
import SwiftUI

/// Confirms the steps and settings a workflow template will pin, names it,
/// and saves it to the app-wide library.
///
/// The numbered step list is the main content: it is the user's check that
/// the chain is what they expect. Settings are read-only; a template pins
/// what the source analysis recorded.
struct SaveWorkflowTemplateSheet: View {
    let extraction: AnalysisTemplateExtractor.Extraction
    let sourceTitle: String
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?

    @State private var name: String

    init(
        extraction: AnalysisTemplateExtractor.Extraction,
        sourceTitle: String,
        onSave: ((String) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.extraction = extraction
        self.sourceTitle = sourceTitle
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: extraction.template.name)
    }

    private var template: AnalysisTemplate { extraction.template }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusText: String? {
        trimmedName.isEmpty ? "Enter a name for the template" : nil
    }

    var body: some View {
        ImportSheet(
            title: "Save as Workflow Template",
            subtitle: "LGE will repeat these steps, with these settings, on new files you choose later.",
            accessoryText: sourceTitle,
            size: ImportSheetSize(width: 560, height: 540),
            statusText: statusText,
            statusColor: .orange,
            primaryTitle: "Save",
            isPrimaryEnabled: !trimmedName.isEmpty,
            onCancel: { onCancel?() },
            onPrimary: { onSave?(trimmedName) },
            icon: {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            },
            content: {
                VStack(alignment: .leading, spacing: 14) {
                    nameSection
                    Divider()
                    WorkflowTemplateStepList(template: template)
                    Divider()
                    inputSection
                    if !template.creationWarnings.isEmpty {
                        Divider()
                        WorkflowTemplateWarningList(title: "Warnings", warnings: template.creationWarnings)
                    }
                    Text("LGE can repeat only steps it ran. Anything done to these files before import is not part of the template.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(WorkflowTemplateAccessibilityID.saveFootnote)
                }
            }
        )
        .accessibilityIdentifier(WorkflowTemplateAccessibilityID.saveSheet)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Template name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(WorkflowTemplateAccessibilityID.saveNameField)
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Each run will ask for")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(template.input.summary), one sample per run. The project, sample name and threads are chosen at run time.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if let kraken2 = template.kraken2Step {
                Text("Fixed resource: Kraken2 database \(kraken2.database.summary)")
                    .font(.system(size: 12))
                    .accessibilityIdentifier(WorkflowTemplateAccessibilityID.saveFixedResource)
            }
        }
    }
}

// MARK: - Shared subviews

/// Read-only numbered list of a template's steps with their key settings.
struct WorkflowTemplateStepList: View {
    let template: AnalysisTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(Array(template.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(step.settingsSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(WorkflowTemplateAccessibilityID.stepRow(index + 1))
            }
            Text("Settings are fixed by the template. To change one, run the analysis with the new setting and save a new template.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(WorkflowTemplateAccessibilityID.stepList)
    }
}

/// A titled list of warning lines with the shared warning styling.
struct WorkflowTemplateWarningList: View {
    let title: String
    let warnings: [String]
    var color: Color = .yellow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(color)
                        .font(.system(size: 12))
                    Text(warning)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.1)))
    }
}
