// OperationReporting+Shared.swift - Lets `.shared` name the production reporter where a parameter takes any reporter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishKit

extension OperationReporting where Self == OperationCenter {
    /// `OperationCenter.shared`, reachable as `.shared` where a parameter takes
    /// `any OperationReporting` (finding R4). A service that moved from an
    /// `OperationCenter` parameter to a reporter parameter keeps its existing
    /// `operationCenter: .shared` call sites compiling. `OperationCenter.shared`
    /// still resolves to the class's own member.
    static var shared: OperationCenter { OperationCenter.shared }
}
