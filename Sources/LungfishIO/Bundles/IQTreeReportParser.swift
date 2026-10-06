import Foundation

/// The model and likelihood fields read from an IQ-TREE `.iqtree` report. Every field is
/// optional because a report from a fixed-model run has no ModelFinder section.
public struct IQTreeReportFields: Sendable, Equatable {
    public var bestFitModel: String?
    public var modelSelectionCriterion: String?
    public var substitutionModel: String?
    public var logLikelihood: Double?
    public var logLikelihoodStandardError: Double?
    public var freeParameters: Int?

    public init(
        bestFitModel: String? = nil,
        modelSelectionCriterion: String? = nil,
        substitutionModel: String? = nil,
        logLikelihood: Double? = nil,
        logLikelihoodStandardError: Double? = nil,
        freeParameters: Int? = nil
    ) {
        self.bestFitModel = bestFitModel
        self.modelSelectionCriterion = modelSelectionCriterion
        self.substitutionModel = substitutionModel
        self.logLikelihood = logLikelihood
        self.logLikelihoodStandardError = logLikelihoodStandardError
        self.freeParameters = freeParameters
    }
}

/// Reads the summary lines of an IQ-TREE 2 or 3 report (`<prefix>.iqtree`).
///
/// The lines it reads look like this.
///
///     Best-fit model according to BIC: TIM2+ASC
///     Model of substitution: TIM2+F+ASC
///     Log-likelihood of the tree: -173.4941 (s.e. 7.9018)
///     Number of free parameters (#branches + #model parameters): 15
///
/// The first match of each line wins, so the maximum-likelihood tree section is read before
/// any consensus tree section further down.
public enum IQTreeReportParser {
    public static func parse(_ text: String) -> IQTreeReportFields {
        var fields = IQTreeReportFields()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if fields.bestFitModel == nil, let rest = value(after: "Best-fit model according to ", in: line) {
                if let colon = rest.firstIndex(of: ":") {
                    let criterion = rest[..<colon].trimmingCharacters(in: .whitespaces)
                    let model = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !model.isEmpty {
                        fields.bestFitModel = model
                        fields.modelSelectionCriterion = criterion.isEmpty ? nil : criterion
                    }
                }
            } else if fields.substitutionModel == nil, let rest = value(after: "Model of substitution:", in: line) {
                let model = rest.trimmingCharacters(in: .whitespaces)
                fields.substitutionModel = model.isEmpty ? nil : model
            } else if fields.logLikelihood == nil, let rest = value(after: "Log-likelihood of the tree:", in: line) {
                let (logLikelihood, standardError) = likelihood(from: rest)
                fields.logLikelihood = logLikelihood
                fields.logLikelihoodStandardError = standardError
            } else if fields.freeParameters == nil, line.hasPrefix("Number of free parameters"),
                      let colon = line.lastIndex(of: ":") {
                fields.freeParameters = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return fields
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// Parses "-173.4941 (s.e. 7.9018)".
    private static func likelihood(from text: String) -> (Double?, Double?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let valueText = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        var standardError: Double?
        if let open = trimmed.range(of: "(s.e."), let close = trimmed[open.upperBound...].firstIndex(of: ")") {
            standardError = Double(trimmed[open.upperBound..<close].trimmingCharacters(in: .whitespaces))
        }
        return (Double(valueText), standardError)
    }
}
