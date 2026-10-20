// TaxTriageSerialBatchError.swift - The words of a TaxTriage batch with no sample left
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum TaxTriageSerialBatchError: Error, LocalizedError, Sendable {
    case allSamplesFailed([TaxTriageSampleFailure])

    public var errorDescription: String? {
        switch self {
        case .allSamplesFailed(let failures):
            let first = failures.first?.errorDescription ?? "No sample completed"
            return "All TaxTriage samples failed. First failure: \(first)"
        }
    }
}
