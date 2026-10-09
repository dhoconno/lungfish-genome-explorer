import AppKit
import LungfishCore
import LungfishIO

/// Value-semantic sizing for one sample's fixed manual-haplotype header band.
///
/// Widths are measured from the complete rendered assignment strings. The
/// editor already bounds an individual label to 128 Unicode scalars, so this
/// presentation helper deliberately adds no second truncation ceiling.
struct GenotypeManualHaplotypeColumnMeasurement: Equatable {
    static func requiredWidth(
        values: [String],
        sampleTitle: String,
        retainedReadTitle: String?,
        font: NSFont,
        headerFont: NSFont,
        inset: CGFloat = 6
    ) -> CGFloat {
        let assignmentWidth = values.reduce(CGFloat.zero) { widest, value in
            max(
                widest,
                (value as NSString).size(
                    withAttributes: [.font: font]
                ).width
            )
        } + inset * 2
        let headerTextWidth = [sampleTitle, retainedReadTitle]
            .compactMap { $0 }
            .reduce(CGFloat.zero) { widest, value in
                max(
                    widest,
                    (value as NSString).size(
                        withAttributes: [.font: headerFont]
                    ).width
                )
            }
        // Ordinary sample headers reserve leading space for their selection
        // indicator in addition to the normal text inset.
        let headerWidth = headerTextWidth + max(inset * 2, 24)
        return ceil(max(assignmentWidth, headerWidth))
    }
}
