import Foundation

/// Renders a discriminating-sites report as the TSV a designer reads and the
/// JSON another tool consumes.
public enum DiscriminatingSitesReportFormatter {
    public static let siteColumns = [
        "alignment_column",
        "template_position",
        "target_base",
        "exclusions_differing",
        "exclusions_matching",
        "exclusions_no_call",
        "exclusion_bases",
        "exclusion_names",
        "dissenting_targets",
    ]

    public static let windowColumns = [
        "start_template_position",
        "end_template_position",
        "start_alignment_column",
        "end_alignment_column",
        "site_count",
        "template_positions",
    ]

    /// The per-site table. Names are semicolon-joined so the file stays a
    /// well-formed TSV.
    public static func siteTSV(for report: DiscriminatingSitesAnalysis.Report) -> String {
        var lines = [siteColumns.joined(separator: "\t")]
        for site in report.sites {
            lines.append([
                String(site.column),
                site.templatePosition.map(String.init) ?? "",
                site.targetBase,
                String(site.exclusionDifferenceCount),
                String(site.exclusionMatchCount),
                String(site.exclusionNoCallCount),
                site.exclusionBases,
                site.exclusionDifferences.map { "\($0.name):\($0.base)" }.joined(separator: ";"),
                site.dissentingTargets.map { "\($0.name):\($0.base)" }.joined(separator: ";"),
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func windowTSV(for report: DiscriminatingSitesAnalysis.Report) -> String {
        var lines = [windowColumns.joined(separator: "\t")]
        for window in report.windows {
            lines.append([
                window.startTemplatePosition.map(String.init) ?? "",
                window.endTemplatePosition.map(String.init) ?? "",
                String(window.startColumn),
                String(window.endColumn),
                String(window.siteCount),
                window.templatePositions.map(String.init).joined(separator: ";"),
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func json(for report: DiscriminatingSitesAnalysis.Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    /// The one-screen summary the CLI prints and the Inspector header shows.
    public static func summaryLines(for report: DiscriminatingSitesAnalysis.Report) -> [String] {
        var lines = [
            "Targets: \(report.targetNames.count) (template \(report.templateName))",
            "Exclusions: \(report.exclusionNames.count)",
            "Discriminating columns: \(report.siteCount)",
        ]
        if report.windows.isEmpty {
            lines.append("Candidate windows (\(report.options.windowLength) bp): none")
        } else {
            lines.append("Candidate windows (\(report.options.windowLength) bp): \(report.windows.count)")
            for window in report.windows.prefix(5) {
                let start = window.startTemplatePosition.map(String.init) ?? "-"
                let end = window.endTemplatePosition.map(String.init) ?? "-"
                lines.append("  \(start)-\(end): \(window.siteCount) sites")
            }
        }
        return lines
    }
}
