import Foundation

/// Checks advanced parameter names before a run starts.
///
/// A misspelled parameter otherwise fails several minutes into a pipeline run,
/// long after the user has left the sheet.
public enum ViralReconParameterSchema {
    public enum ValidationOutcome: Equatable, Sendable {
        case accepted
        case unknownParameter(String)
        case structural(String)
    }

    public static func validate(
        _ params: [String: String],
        knownParameters: Set<String>
    ) -> [ValidationOutcome] {
        params.keys.sorted().map { key in
            if ViralReconRunRequest.structuralAdvancedKeys.contains(key) {
                return .structural(key)
            }
            if !knownParameters.contains(key) {
                return .unknownParameter(key)
            }
            return .accepted
        }
    }

    /// Collects every parameter name declared anywhere in a Nextflow schema by
    /// walking `properties` maps wherever they appear.
    public static func loadKnownParameters(from schemaURL: URL) throws -> Set<String> {
        let data = try Data(contentsOf: schemaURL)
        let root = try JSONSerialization.jsonObject(with: data)
        var names: Set<String> = []
        collectProperties(from: root, into: &names)
        return names
    }

    private static func collectProperties(from node: Any, into names: inout Set<String>) {
        guard let object = node as? [String: Any] else {
            if let array = node as? [Any] {
                for element in array { collectProperties(from: element, into: &names) }
            }
            return
        }
        if let properties = object["properties"] as? [String: Any] {
            names.formUnion(properties.keys)
        }
        for (key, value) in object where key != "properties" {
            collectProperties(from: value, into: &names)
        }
    }
}
