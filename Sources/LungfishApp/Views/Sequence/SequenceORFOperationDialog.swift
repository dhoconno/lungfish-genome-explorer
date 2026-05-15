// SequenceORFOperationDialog.swift - Shared operations dialog for ORF annotation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Observation
import SwiftUI
import LungfishCore

@MainActor
@Observable
final class SequenceORFOperationDialogState {
    static let toolID = "find-orfs"

    let bundleURL: URL
    let sequenceName: String
    let range: Range<Int>
    let datasetLabel: String
    var selectedToolID = SequenceORFOperationDialogState.toolID
    var selectedFrames: Set<String>
    var codonTableID: Int
    var trackName: String
    var trackID: String
    var minimumORFLengthText: String
    var includePartialORFs: Bool
    var allowAlternativeStarts: Bool

    init(
        bundleURL: URL,
        sequenceName: String,
        range: Range<Int>,
        defaultTrackName: String,
        defaultTrackID: String,
        defaultFrames: [String] = ReadingFrame.allCases.map(\.rawValue),
        defaultCodonTableID: Int = CodonTable.standard.id,
        defaultMinimumORFLength: Int = 100,
        includePartialORFs: Bool = false,
        allowAlternativeStarts: Bool = false
    ) {
        self.bundleURL = bundleURL
        self.sequenceName = sequenceName
        self.range = range
        self.datasetLabel = "\(sequenceName):\(range.lowerBound + 1)-\(range.upperBound)"
        self.selectedFrames = Set(defaultFrames)
        self.codonTableID = defaultCodonTableID
        self.trackName = defaultTrackName
        self.trackID = defaultTrackID
        self.minimumORFLengthText = String(defaultMinimumORFLength)
        self.includePartialORFs = includePartialORFs
        self.allowAlternativeStarts = allowAlternativeStarts
    }

    var sidebarItems: [DatasetOperationToolSidebarItem] {
        [
            DatasetOperationToolSidebarItem(
                id: Self.toolID,
                title: "Find ORFs",
                subtitle: "Add ORF annotations with translated products.",
                availability: .available
            )
        ]
    }

    var selectedFrameList: [String] {
        ReadingFrame.allCases.map(\.rawValue).filter { selectedFrames.contains($0) }
    }

    var selectedCodonTable: CodonTable {
        CodonTable.table(id: codonTableID) ?? .standard
    }

    var minimumORFLength: Int? {
        Int(minimumORFLengthText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isRunEnabled: Bool {
        validationMessage == nil
    }

    var readinessText: String {
        validationMessage ?? "Ready"
    }

    func selectTool(named id: String) {
        guard id == Self.toolID else { return }
        selectedToolID = id
    }

    func setFrame(_ frame: ReadingFrame, enabled: Bool) {
        if enabled {
            selectedFrames.insert(frame.rawValue)
        } else {
            selectedFrames.remove(frame.rawValue)
        }
    }

    func makeRequest() -> SequenceAnnotationOperationRequest? {
        guard isRunEnabled, let minimumORFLength else { return nil }
        let cleanedTrackID = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        return SequenceAnnotationOperationRequest(
            operation: .orf,
            bundleURL: bundleURL,
            sequenceName: sequenceName,
            start: range.lowerBound,
            end: range.upperBound,
            frames: selectedFrameList,
            codonTableID: selectedCodonTable.id,
            trackID: cleanedTrackID.isEmpty ? nil : cleanedTrackID,
            trackName: trackName.trimmingCharacters(in: .whitespacesAndNewlines),
            minimumORFLength: minimumORFLength,
            includePartialORFs: includePartialORFs,
            allowAlternativeStarts: allowAlternativeStarts
        )
    }

    private var validationMessage: String? {
        if selectedFrameList.isEmpty {
            return "Select at least one reading frame."
        }
        if trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a track name."
        }
        let cleanedTrackID = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTrackID.isEmpty && !Self.isValidTrackID(cleanedTrackID) {
            return "Use only letters, numbers, underscores, and hyphens for the track ID."
        }
        guard let minimumORFLength, minimumORFLength > 0 else {
            return "Enter a positive minimum ORF length."
        }
        return nil
    }

    static func isValidTrackID(_ trackID: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return !trackID.isEmpty && trackID.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

struct SequenceORFOperationDialog: View {
    @Bindable var state: SequenceORFOperationDialogState
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        DatasetOperationsDialog(
            title: "FIND ORFS",
            subtitle: "Create an annotation track for open reading frames.",
            datasetLabel: state.datasetLabel,
            tools: state.sidebarItems,
            selectedToolID: state.selectedToolID,
            statusText: state.readinessText,
            isRunEnabled: state.isRunEnabled,
            primaryActionTitle: "Run",
            accessibilityNamespace: "sequence-orf-operation",
            onSelectTool: state.selectTool(named:),
            onCancel: onCancel,
            onRun: onRun
        ) {
            SequenceORFOperationPane(state: state)
        }
    }
}

private struct SequenceORFOperationPane: View {
    private static let readingFrameColumnWidth: CGFloat = 88
    private static let readingFrameColumnSpacing: CGFloat = 32
    private static let readingFrameRowSpacing: CGFloat = 8

    @Bindable var state: SequenceORFOperationDialogState

    var body: some View {
        Form {
            Section("Reading Frames") {
                VStack(alignment: .leading, spacing: Self.readingFrameRowSpacing) {
                    readingFrameRow(Array(ReadingFrame.allCases.prefix(3)))
                    readingFrameRow(Array(ReadingFrame.allCases.suffix(3)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sequence-orf-frame-options")
            }

            Section("Translation") {
                Picker("Codon table", selection: $state.codonTableID) {
                    ForEach(CodonTable.allTables, id: \.id) { table in
                        Text("\(table.id) - \(table.name)").tag(table.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("sequence-orf-codon-table-picker")

                TextField("Minimum ORF length", text: $state.minimumORFLengthText)
                    .accessibilityIdentifier("sequence-orf-min-length-field")
            }

            Section("Output") {
                TextField("Track name", text: $state.trackName)
                    .accessibilityIdentifier("sequence-orf-track-name-field")
                TextField("Track ID", text: $state.trackID)
                    .accessibilityIdentifier("sequence-orf-track-id-field")
            }

            Section("Options") {
                Toggle("Include partial ORFs", isOn: $state.includePartialORFs)
                    .accessibilityIdentifier("sequence-orf-include-partial-checkbox")
                Toggle("Allow alternative starts", isOn: $state.allowAlternativeStarts)
                    .accessibilityIdentifier("sequence-orf-alt-starts-checkbox")
            }
        }
        .formStyle(.grouped)
    }

    private func readingFrameRow(_ frames: [ReadingFrame]) -> some View {
        HStack(alignment: .center, spacing: Self.readingFrameColumnSpacing) {
            ForEach(frames, id: \.rawValue) { frame in
                frameToggle(frame)
                    .frame(width: Self.readingFrameColumnWidth, alignment: .leading)
            }
        }
    }

    private func frameToggle(_ frame: ReadingFrame) -> some View {
        Toggle(
            frame.rawValue,
            isOn: Binding(
                get: { state.selectedFrames.contains(frame.rawValue) },
                set: { state.setFrame(frame, enabled: $0) }
            )
        )
        .accessibilityIdentifier("sequence-orf-frame-\(frame.rawValue)-checkbox")
    }
}

@MainActor
struct SequenceORFOperationDialogPresenter {
    static func present(
        from window: NSWindow,
        state: SequenceORFOperationDialogState,
        onRun: @escaping (SequenceAnnotationOperationRequest) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = "Find ORFs"
        panel.isReleasedWhenClosed = false

        let dialog = SequenceORFOperationDialog(
            state: state,
            onCancel: {
                window.endSheet(panel)
                onCancel?()
            },
            onRun: {
                guard let request = state.makeRequest() else { return }
                window.endSheet(panel)
                onRun(request)
            }
        )

        panel.contentViewController = NSHostingController(rootView: dialog)
        panel.setContentSize(NSSize(width: 920, height: 620))
        window.beginSheet(panel)
    }
}
