import SwiftUI
import LungfishKit

/// The Genotype Display section's integrity warnings that hold for every
/// bundle type, such as the duplicate-row warning (D5b). Each line reads as
/// the full-length candidate section's coded warning lines do.
struct GenotypeResultIntegrityWarningList: View {
    let warnings: [String]
    private let typography = ContentTypographyModel.shared

    var body: some View {
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(typography.font(for: .body))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Genotype result warning: \(warning)")
        }
    }
}
