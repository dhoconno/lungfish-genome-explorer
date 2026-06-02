import LungfishKit
import LungfishTwelveSUI
import SwiftUI

/// Inspector view-model holding the currently-selected 12S row's detail.
///
/// Fed by `ViewerViewController+TwelveS` from the leaf VC's
/// `onSelectedRowDetailChanged` callback. Empty by default and on multi/no
/// selection, in which case the section renders a placeholder.
@Observable
@MainActor
final class TwelveSDetailSectionViewModel {
    private(set) var payload: TwelveSDetailPayload?

    /// Whether the 12S viewport is the active result (controls tab availability).
    var isAvailable = false

    var hasDetail: Bool { payload != nil }

    let placeholderText = "Select a single match to view details."

    var title: String {
        switch payload?.kind {
        case let .target(detail): return detail.scientificName
        case let .unresolved(detail): return detail.sequenceID
        case nil: return "Detail"
        }
    }

    /// Reference sequences for the selected target species (empty otherwise).
    var referenceSequences: [TwelveSReferenceSequence] {
        if case let .target(detail) = payload?.kind { return detail.referenceSequences }
        return []
    }

    func apply(_ payload: TwelveSDetailPayload?) {
        self.payload = payload
    }

    func clear() {
        payload = nil
    }

    /// Resets availability and clears any detail (called when the 12S viewport closes).
    func reset() {
        isAvailable = false
        payload = nil
    }
}

struct TwelveSDetailSection: View {
    @Bindable var viewModel: TwelveSDetailSectionViewModel
    @State private var isReferenceExpanded = false
    private let pasteboard: PasteboardWriting = DefaultPasteboard()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("12S Detail", systemImage: "list.bullet.rectangle")
                .font(.headline)
            Divider()
            switch viewModel.payload?.kind {
            case let .target(detail):
                targetDetail(detail)
            case let .unresolved(detail):
                unresolvedDetail(detail)
            case nil:
                Text(viewModel.placeholderText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func targetDetail(_ detail: TwelveSDetailPayload.TargetDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.scientificName)
                .font(.title3.weight(.semibold))
            LabeledContent("Exact Reads", value: "\(detail.totalExactReads)")
            LabeledContent(
                "Reference Targets",
                value: "\(detail.referenceTargetCount)"
            )

            if !detail.sampleEvidence.isEmpty {
                Divider()
                DisclosureGroup("Sample Evidence (\(detail.sampleEvidence.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(detail.sampleEvidence, id: \.sampleID) { row in
                            HStack {
                                Text(row.displayName)
                                Spacer()
                                Text("\(row.exactReads) reads (\(Self.percent(row.percentOfSampleExactReads)))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            Divider()
            DisclosureGroup("Alternate Exact Matches (\(detail.alternateTexts.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    if detail.alternateTexts.isEmpty {
                        Text("No alternate exact species labels recorded.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(detail.alternateTexts, id: \.self) { text in
                            Text(text)
                                .font(.callout)
                        }
                    }
                }
                .padding(.top, 4)
            }

            Divider()
            referenceSequences(detail.referenceSequences)
        }
    }

    @ViewBuilder
    private func referenceSequences(_ sequences: [TwelveSReferenceSequence]) -> some View {
        DisclosureGroup("Reference Sequences (\(sequences.count))", isExpanded: $isReferenceExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if sequences.isEmpty {
                    Text("No reference sequences available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        pasteboard.setString(TwelveSCopyFormatting.referenceFASTA(sequences))
                    } label: {
                        Label("Copy All as FASTA", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)

                    ForEach(sequences, id: \.targetID) { seq in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(seq.targetID)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Button {
                                    pasteboard.setString(seq.sequence)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Copy this sequence")
                            }
                            Text(seq.sequence)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func unresolvedDetail(_ detail: TwelveSDetailPayload.UnresolvedDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.sequenceID)
                .font(.title3.weight(.semibold))
            LabeledContent("Reads", value: "\(detail.readCount)")
            LabeledContent("Chimera", value: detail.chimeraStatusName)

            Divider()
            Text("Sequence")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(detail.sequence)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            if !detail.sampleEvidence.isEmpty {
                Divider()
                DisclosureGroup("Sample Counts (\(detail.sampleEvidence.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(detail.sampleEvidence, id: \.sampleID) { row in
                            HStack {
                                Text(row.displayName)
                                Spacer()
                                Text("\(row.exactReads) reads")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}
