// VariantCallerSettingsSummary.swift - The caller-settings column of the variant table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The caller-settings column's text. Uses the parameters recorded with the call, without inventing defaults for
/// imported tracks. A value type, so the table export leaf writes the column the drawer shows.
package enum VariantCallerSettingsSummary {
    /// The column's text for one variant database. The parameters recorded with the call, or else the recorded
    /// command line, or else "Not recorded", as the search index shows it, so `bundle export-annotation-table`
    /// writes the drawer's text from the database alone.
    package static func text(databaseURL: URL) -> String {
        let settings = text(
            parametersJSON: VariantDatabase.metadataValue(at: databaseURL, key: "variant_caller_parameters_json")
        )
        let command = VariantDatabase.metadataValue(at: databaseURL, key: "variant_caller_command_line")
        return settings == "Not recorded"
            ? (command.flatMap { $0.isEmpty ? nil : $0 } ?? settings) : settings
    }

    package static func text(parametersJSON: String?) -> String {
        guard let data = parametersJSON?.data(using: .utf8),
              let parameters = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "Not recorded"
        }
        let labels = [
            "minimumAlleleFrequency": "Minimum allele frequency",
            "minimumDepth": "Minimum depth", "caller": "Caller", "threads": "Threads",
            "advancedArguments": "Advanced arguments", "advancedOptions": "Advanced options",
            "extraArgs": "Extra arguments", "ignoreStrandBias": "Ignore strand bias"
        ]
        let parts = parameters.keys.sorted().compactMap { key -> String? in
            guard let value = parameters[key], !(value is NSNull) else { return nil }
            let text: String
            if let string = value as? String { text = string }
            else if let number = value as? NSNumber {
                text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            } else if let array = value as? [Any], array.isEmpty { return nil }
            else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                    let json = String(data: data, encoding: .utf8) { text = json }
            else { return nil }
            guard !text.isEmpty else { return nil }
            return "\(labels[key] ?? key): \(text)"
        }
        return parts.isEmpty ? "Not recorded" : parts.joined(separator: "; ")
    }
}
