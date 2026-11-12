import Foundation
import LungfishWorkflow

extension PrimerDesignCommand {
    /// The same explanations and warnings the app shows on each saved target of a scheme analysis, one
    /// `[severity] <target label>: <message>` line each. The varVAMP and Olivar commands both print them, so a
    /// warning the adapter recorded (an amplicon outside the requested size range, for one) reaches the person
    /// at the command line as it does on the result card.
    static func advisoryLines(analysisURL: URL) -> [String] {
        let url = analysisURL.appendingPathComponent(PrimerSchemeResultsDocument.storedRelativePath)
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(PrimerSchemeResultsDocument.self, from: data) else { return [] }
        return document.results.flatMap(\.targets).flatMap { target in
            document.schemeAdvisories(for: target).map { advisory in
                "[\(advisory.severity.rawValue)] \(target.label): \(advisory.message)"
            }
        }
    }
}
