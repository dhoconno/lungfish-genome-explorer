import SwiftUI
import LungfishIO
import LungfishKit

/// Integrity warnings shown in the Inspector, such as the Genotype Display
/// section's duplicate-row warning (D5b) and the full-length candidate
/// section's artifact warnings. Each line is the warning's plain detail and
/// the file it names. The warning's code is the line's help text, so the
/// sentence a user reads never starts with a code.
struct GenotypeResultIntegrityWarningList: View {
    static let accessibilityIdentifier = "genotype-result-integrity-warning"

    let warnings: [ONTGenotypeIntegrityWarning]
    var accessibilityPrefix = "Genotype result warning"
    private let typography = ContentTypographyModel.shared

    var body: some View {
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
            let line = Self.line(for: warning)
            Label(line, systemImage: "exclamationmark.triangle")
                .font(typography.font(for: .body))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .help(warning.code.rawValue)
                .accessibilityLabel("\(accessibilityPrefix). \(line)")
                .accessibilityIdentifier(Self.accessibilityIdentifier)
        }
    }

    /// One warning as a user reads it, the detail and then the file it names.
    nonisolated static func line(for warning: ONTGenotypeIntegrityWarning) -> String {
        warning.detail + (warning.path.map { " (\($0))" } ?? "")
    }
}

/// The Genotype Display section's row summary. Rows and Hidden Cells follow
/// Content Text Size, and the result's integrity warnings follow them.
struct GenotypeResultDisplaySummary: View {
    let viewModel: GenotypeResultDisplaySectionViewModel
    private let typography = ContentTypographyModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Rows", value: "\(viewModel.visibleRowCount) of \(viewModel.totalRowCount)")
            LabeledContent("Hidden Cells", value: "\(viewModel.hiddenCellCount)")
            GenotypeResultIntegrityWarningList(warnings: viewModel.resultIntegrityWarnings)
        }
        .font(typography.font(for: .body))
    }
}
