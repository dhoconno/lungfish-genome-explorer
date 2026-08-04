import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit

/// Modal sheet that surfaces a single sample's per-locus calls with
/// override controls inline. Opens when the analyst clicks a sample in
/// Outline / Matrix.
///
/// One row per (locus, slot) — typically 14 rows for an MCM bundle
/// (7 loci × H1 + H2). Each row carries the colored swatch, the call
/// label, the per-slot status, and a per-row "Override…" button that
/// pops a small inline override form.
struct GenotypeSampleDetailSheet: View {
    struct CallRow: Identifiable, Equatable {
        let locus: String
        let slot: HaplotypeSlot
        let callName: String
        let status: GenotypeHaplotypeCallStatus
        let source: GenotypeEffectiveHaplotypeValue.Source
        let observedGenotypeCount: Int
        var id: String { "\(locus)/\(slot.rawValue)" }
    }

    let sampleId: String
    let rows: [CallRow]
    let overrides: [GenotypeAnnotationSidecar.CallOverride]
    let allowedTargetsForLocus: (String) -> [String]
    var onSaveOverride: (CallRow, GenotypeOverrideSection.OverrideDraft) -> Void
    var onClearOverride: (CallRow) -> Void
    var onDismiss: () -> Void
    var typographyModel: ContentTypographyModel = .shared

    @State private var editingRowId: String?
    @State private var editingDraft = GenotypeOverrideSection.OverrideDraft()

    private var contentEmphasizedFont: Font { typographyModel.font(for: .emphasizedBody) }
    private var contentCaptionFont: Font { typographyModel.font(for: .caption) }
    private var contentMonospacedFont: Font { typographyModel.font(for: .monospaced) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            scroll
            Divider()
            footer
        }
        .frame(
            minWidth: 540,
            idealWidth: min(760, typographyModel.scaledPointSize(fromCanonicalPointSize: 540)),
            minHeight: 580,
            idealHeight: min(760, typographyModel.scaledPointSize(fromCanonicalPointSize: 580))
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sampleId)
                    .font(contentEmphasizedFont)
                    .textSelection(.enabled)
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            Text("\(rows.count) call(s) · \(rows.filter { $0.status != .called && $0.status != .notAssayed && $0.status != .specialCase }.count) need review")
                .font(contentCaptionFont)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                    if row.id != rows.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Spacer()
            Text("Overrides write to the bundle's annotations.json")
                .font(contentCaptionFont)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func rowView(_ row: CallRow) -> some View {
        let override = overrides.first(where: { $0.locus == row.locus && $0.slot == row.slot })
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    rowContent(row, override: override)
                    Spacer(minLength: 8)
                    rowActions(row, override: override)
                }
                VStack(alignment: .leading, spacing: 8) {
                    rowContent(row, override: override)
                    rowActions(row, override: override)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if editingRowId == row.id {
                GenotypeOverrideSection(
                    draft: $editingDraft,
                    originalCall: override?.originalCall ?? row.callName,
                    allowedTargets: allowedTargetsForLocus(row.locus),
                    onSave: { draft in
                        onSaveOverride(row, draft)
                        editingRowId = nil
                    },
                    onCancel: {
                        editingRowId = nil
                    }
                )
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(editingRowId == row.id ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func rowContent(
        _ row: CallRow,
        override: GenotypeAnnotationSidecar.CallOverride?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            swatch(forName: row.callName, status: row.status)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.locus)
                        .font(contentEmphasizedFont)
                    Text(row.slot.displayName)
                        .font(contentCaptionFont.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(displayedCall(row: row, override: override))
                        .font(contentMonospacedFont)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let override {
                        Text("(was \(override.originalCall))")
                            .font(contentCaptionFont.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    statusChip(row.status)
                }
            }
        }
    }

    private func rowActions(
        _ row: CallRow,
        override: GenotypeAnnotationSidecar.CallOverride?
    ) -> some View {
        HStack(spacing: 8) {
            if let override {
                Button {
                    onClearOverride(row)
                } label: {
                    Label("Clear", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Revert to the pipeline call (\(override.originalCall))")
            }
            Button(editingRowId == row.id ? "Hide" : (override == nil ? "Override\u{2026}" : "Edit\u{2026}")) {
                if editingRowId == row.id {
                    editingRowId = nil
                } else {
                    editingRowId = row.id
                    if let override {
                        editingDraft = GenotypeOverrideSection.OverrideDraft(
                            target: override.overrideCall,
                            reason: override.reasonTag,
                            rationale: override.rationale
                        )
                    } else {
                        editingDraft = GenotypeOverrideSection.OverrideDraft()
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private func swatch(forName name: String, status: GenotypeHaplotypeCallStatus) -> some View {
        let isError = name == GenotypeHaplotypeOverrideTargets.unresolved
            || (status != .called && status != .notAssayed && status != .specialCase)
        let token = HaplotypeColorToken.assigned(forName: name)
        let fillColor: Color = isError
            ? Color(nsColor: .controlBackgroundColor)
            : Color(red: token.fillColor.red,
                    green: token.fillColor.green,
                    blue: token.fillColor.blue)
        return ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)
            if isError {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .lungfishDanger), lineWidth: 1.5)
                Text(errorSymbol(name))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(nsColor: .lungfishDanger))
            }
        }
        .frame(width: 22, height: 22)
    }

    private func errorSymbol(_ label: String) -> String {
        if label == GenotypeHaplotypeOverrideTargets.unresolved { return "?" }
        if label.contains("TMH") { return "T" }
        if label.contains("TMG") { return "G" }
        if label.contains("NO HAP") { return "?" }
        return "!"
    }

    private func displayedCall(row: CallRow, override: GenotypeAnnotationSidecar.CallOverride?) -> String {
        if let override { return override.overrideCall }
        return row.callName
    }

    @ViewBuilder
    private func statusChip(_ status: GenotypeHaplotypeCallStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .called:             return ("called", Color.secondary)
            case .notAssayed:         return ("not assayed", Color(nsColor: .systemOrange))
            case .specialCase:        return ("special", Color(nsColor: .systemOrange))
            case .noHaplotype:        return ("no haplotype", Color(nsColor: .lungfishDanger))
            case .tooManyHaplotypes:  return ("too many haplotypes", Color(nsColor: .lungfishDanger))
            case .tooManyGenotypes:   return ("too many genotypes", Color(nsColor: .lungfishDanger))
            }
        }()
        Text(label)
            .font(contentCaptionFont)
            .foregroundStyle(color)
    }

    var testingContentTypographyPointSizes: (body: CGFloat, caption: CGFloat) {
        (
            typographyModel.resolvedNSFont(for: .body).pointSize,
            typographyModel.resolvedNSFont(for: .caption).pointSize
        )
    }
}
