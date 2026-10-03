// DependencyReconcilerError.swift - Errors thrown by the dependency reconciler
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import CryptoKit
import LungfishCore
import os
import os.log

public enum DependencyReconcilerError: Error, LocalizedError, Equatable {
    case alreadyApplying

    public var errorDescription: String? {
        switch self {
        case .alreadyApplying:
            return "A tool update is already running. Wait for it to finish before starting another."
        }
    }
}
