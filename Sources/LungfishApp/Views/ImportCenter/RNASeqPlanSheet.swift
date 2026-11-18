// RNASeqPlanSheet.swift - The two sheets that write a plan for RNA-seq counts on a Linux machine (Phase 5.4 lane EX-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One view serves both commands, `rnaseq quant --write-plan` (bulk) and `rnaseq solo-plan` (10x). The fields show the
// commands' own defaults, the 10x section says where the barcode list comes from, and nothing here computes a number.

import AppKit
import LungfishWorkflow
import SwiftUI

/// The panels of the plan sheets. Each opens on the sheet and answers on the main actor.
@MainActor
enum RNASeqPlanPanels {
    static func chooseNewFolder(completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.message = "Name a new folder for the plan. Nothing is imported and nothing is submitted."
        panel.prompt = "Choose"
        panel.nameFieldStringValue = "lungfish-plan"
        panel.canCreateDirectories = true
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.url : nil) }
        } else {
            panel.begin { completion($0 == .OK ? panel.url : nil) }
        }
    }

    static func chooseBundles(completion: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.message = "Choose the FASTQ bundles to plan, one sample each"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.urls : []) }
        } else {
            panel.begin { completion($0 == .OK ? panel.urls : []) }
        }
    }
}

/// A labelled text field with a line of help below it.
struct RNASeqPlanTextRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let help: String?
    let identifier: String
    var fieldWidth: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
                if let fieldWidth {
                    TextField(placeholder, text: $text).frame(width: fieldWidth).accessibilityIdentifier(identifier)
                    Spacer()
                } else {
                    TextField(placeholder, text: $text).accessibilityIdentifier(identifier)
                }
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, RNASeqImportLayout.labelWidth + 8)
            }
        }
    }
}

struct RNASeqPlanSheet: View {
    @Bindable var model: RNASeqPlanSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Text(model.introduction)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rnaseq-plan-introduction")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    RNASeqPlanTextRow(
                        title: "Reference set:", placeholder: "Id of the set", text: $model.setID,
                        help: model.kind == .tenX ? RNASeqPlanWords.tenXSetHelp : "The id of a reference set under the storage root.",
                        identifier: "rnaseq-plan-set"
                    )
                    if model.kind == .bulk { bulkRows } else { tenXRows }
                    RNASeqPlanTextRow(
                        title: "Staging folder:", placeholder: "/path/on/the/linux/machine", text: $model.stagingFolder,
                        help: "The absolute path of the folder on the Linux machine that holds the image, the executor, the index and the reads.",
                        identifier: "rnaseq-plan-staging"
                    )
                    RNASeqImportChooserRow(
                        title: "Plan folder:", help: "The new folder the plan is written to. It must not exist.",
                        value: model.planFolder, identifier: "rnaseq-plan-folder",
                        choose: { RNASeqPlanPanels.chooseNewFolder { if let url = $0 { model.planFolder = url } } },
                        clear: { model.planFolder = nil }
                    )
                    filesDisclosure
                    requestRows
                }
                .padding(.trailing, 8)
            }
            .frame(maxHeight: 440)
            .disabled(model.phase == .running)
            footer
        }
        .padding(20)
        .frame(width: 640)
    }

    // MARK: - Bulk

    @ViewBuilder
    private var bulkRows: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Reads:").frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
            Picker("Reads", selection: $model.reads) {
                Text("FASTQ bundles").tag(RNASeqPlanSheetModel.ReadsSource.bundles)
                Text("Reads in the staging folder").tag(RNASeqPlanSheetModel.ReadsSource.staged)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 360)
            .accessibilityIdentifier("rnaseq-plan-reads")
            Spacer()
        }
        if model.reads == .bundles {
            HStack(alignment: .firstTextBaseline) {
                Text("FASTQ bundles:").frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
                Text(bundlesSummary)
                    .foregroundStyle(model.bundles.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .accessibilityIdentifier("rnaseq-plan-bundles-value")
                Spacer()
                Button("Choose\u{2026}") { RNASeqPlanPanels.chooseBundles { if !$0.isEmpty { model.bundles = $0 } } }
                    .accessibilityIdentifier("rnaseq-plan-bundles-choose")
            }
        } else {
            stagedRows(sampleSheetHelp: RNASeqPlanWords.bulkSampleSheetHelp)
        }
        HStack(alignment: .firstTextBaseline) {
            Text("Chain:").frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
            Picker("Chain", selection: $model.chain) {
                Text("salmon (the default)").tag(String?.none)
                ForEach(RNASeqPlanSheetModel.chains.dropFirst(), id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 280)
            .accessibilityIdentifier("rnaseq-plan-chain")
            Spacer()
        }
    }

    private var bundlesSummary: String {
        let names = model.bundles.map(\.lastPathComponent)
        guard !names.isEmpty else { return "None" }
        return names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
    }

    // MARK: - 10x

    @ViewBuilder
    private var tenXRows: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Preset:").frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
            Picker("Preset", selection: $model.preset) {
                ForEach(SoloPlanPreset.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 240)
            .accessibilityIdentifier("rnaseq-plan-preset")
            Spacer()
        }
        Text(model.presetWords)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, RNASeqImportLayout.labelWidth + 8)
            .accessibilityIdentifier("rnaseq-plan-preset-words")
        stagedRows(sampleSheetHelp: RNASeqPlanWords.tenXSampleSheetHelp)
        RNASeqImportChooserRow(
            title: "Barcode list:", help: model.barcodeListWords, value: model.barcodeList, identifier: "rnaseq-plan-barcode-list",
            choose: { RNASeqImportPanels.choose(message: "Choose the preset's whole 10x barcode list", directories: false) { if let url = $0 { model.barcodeList = url } } },
            clear: { model.barcodeList = nil }
        )
        HStack(alignment: .firstTextBaseline) {
            Text("10x filter:").frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
            Picker("10x filter", selection: $model.tenXFilter) {
                Text("None").tag(String?.none)
                ForEach(RNASeqPlanSheetModel.tenXFilters, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 200)
            .accessibilityIdentifier("rnaseq-plan-tenx-filter")
            Spacer()
        }
        Text(RNASeqPlanWords.tenXFilterHelp)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, RNASeqImportLayout.labelWidth + 8)
        RNASeqPlanTextRow(
            title: "Expected cells:", placeholder: String(RNASeqPlanSheetModel.defaultExpectedCells), text: $model.expectedCells,
            help: "The expected cells of STARsolo's EmptyDrops_CR cell filter (default: \(RNASeqPlanSheetModel.defaultExpectedCells)).",
            identifier: "rnaseq-plan-expected-cells", fieldWidth: 100
        )
    }

    @ViewBuilder
    private func stagedRows(sampleSheetHelp: String) -> some View {
        RNASeqImportChooserRow(
            title: "Staged reads list:", help: RNASeqPlanWords.stagedReadsHelp, value: model.stagedReads, identifier: "rnaseq-plan-staged",
            choose: { RNASeqImportPanels.choose(message: "Choose the list of the staged reads", directories: false) { if let url = $0 { model.stagedReads = url } } },
            clear: { model.stagedReads = nil }
        )
        RNASeqImportChooserRow(
            title: "Sample sheet:", help: sampleSheetHelp, value: model.sampleSheet, identifier: "rnaseq-plan-samplesheet",
            choose: { RNASeqImportPanels.choose(message: "Choose the sample sheet", directories: false) { if let url = $0 { model.sampleSheet = url } } },
            clear: { model.sampleSheet = nil }
        )
    }

    // MARK: - The files and the request values

    private var filesDisclosure: some View {
        DisclosureGroup("Executor and image") {
            VStack(alignment: .leading, spacing: 8) {
                Text(RNASeqPlanWords.appFilesLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                RNASeqImportChooserRow(
                    title: "Executor manifest:", help: nil, value: model.executorManifest, identifier: "rnaseq-plan-executor",
                    choose: { RNASeqImportPanels.choose(message: "Choose the manifest.json beside the executor", directories: false) { if let url = $0 { model.executorManifest = url } } },
                    clear: { model.executorManifest = nil }
                )
                RNASeqImportChooserRow(
                    title: "Image:", help: nil, value: model.image, identifier: "rnaseq-plan-image",
                    choose: { RNASeqImportPanels.choose(message: "Choose the image.json of the container image", directories: false) { if let url = $0 { model.image = url } } },
                    clear: { model.image = nil }
                )
                RNASeqImportChooserRow(
                    title: "Image tool manifest:", help: nil, value: model.imageToolManifest, identifier: "rnaseq-plan-image-tools",
                    choose: { RNASeqImportPanels.choose(message: "Choose the tool manifest that image.json pins", directories: false) { if let url = $0 { model.imageToolManifest = url } } },
                    clear: { model.imageToolManifest = nil }
                )
            }
            .padding(.top, 4)
        }
    }

    private var requestRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            RNASeqPlanTextRow(
                title: "CPUs a job asks for:", placeholder: String(RNASeqPlanSheetModel.defaultRequestCPUs), text: $model.requestCPUs,
                help: model.kind == .bulk
                    ? "Also the threads of salmon and STAR (default: \(RNASeqPlanSheetModel.defaultRequestCPUs))."
                    : "Also STAR's threads (default: \(RNASeqPlanSheetModel.defaultRequestCPUs)).",
                identifier: "rnaseq-plan-cpus", fieldWidth: 100
            )
            RNASeqPlanTextRow(
                title: "Memory (MiB):", placeholder: "the command's own figure", text: $model.requestMemoryMiB,
                help: "Memory each job asks for. Leave it empty to let the command size it, which it can do for some sets only.",
                identifier: "rnaseq-plan-memory", fieldWidth: 180
            )
            RNASeqPlanTextRow(
                title: "Disk (GiB):", placeholder: "the command's own figure", text: $model.requestDiskGiB,
                help: "Disk each job asks for. Leave it empty to let the command size it.",
                identifier: "rnaseq-plan-disk", fieldWidth: 180
            )
            RNASeqPlanTextRow(
                title: "Job requirements:", placeholder: "HTCondor requirements expression", text: $model.jobRequirements,
                help: "The machines the jobs may run on, as one HTCondor requirements expression. Optional.",
                identifier: "rnaseq-plan-requirements"
            )
        }
    }

    // MARK: - The footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.failure {
                Text(failure)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("rnaseq-plan-failure")
                Text("Change what the message names, then choose Check or Write Plan again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = model.note {
                Text(note).foregroundStyle(.secondary).accessibilityIdentifier("rnaseq-plan-note")
            }
            if model.phase == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working. The Operations panel shows the command.").foregroundStyle(.secondary)
                }
            } else if let missing = model.missingChoice {
                Text(missing).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("rnaseq-plan-missing")
            } else {
                Text(RNASeqPlanWords.checkLine).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(model.phase == .running ? "Cancel Plan" : "Cancel") { model.cancelClicked() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("rnaseq-plan-cancel")
                Button("Check") { model.checkClicked() }
                    .disabled(!model.canRun)
                    .accessibilityIdentifier("rnaseq-plan-check")
                Button("Write Plan") { model.writeClicked() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRun)
                    .accessibilityIdentifier("rnaseq-plan-write")
            }
        }
    }
}
