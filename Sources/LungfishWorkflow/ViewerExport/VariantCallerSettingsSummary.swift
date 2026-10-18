// VariantCallerSettingsSummary.swift - The caller-settings column of the variant table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The caller-settings column's text. Uses the parameters recorded with the call, without inventing defaults for
/// imported tracks. A value type, so the table export leaf writes the column the drawer shows.
package enum VariantCallerSettingsSummary {
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
