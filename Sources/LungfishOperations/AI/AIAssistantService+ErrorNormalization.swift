// AIAssistantService+ErrorNormalization.swift - Turns any error from an AI provider call into an AIProviderError
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension AIAssistantService {

    func normalizeProviderError(_ error: Error) -> AIProviderError {
        if let providerError = error as? AIProviderError {
            return providerError
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .networkError("AI request timed out.")
            case .notConnectedToInternet:
                return .networkError("No internet connection.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .networkError("Unable to reach AI provider host (\(urlError.code.rawValue)).")
            case .networkConnectionLost:
                return .networkError("Network connection was lost.")
            default:
                return .networkError("Network error (\(urlError.code.rawValue)): \(urlError.localizedDescription)")
            }
        }
        return .networkError(error.localizedDescription)
    }
}
