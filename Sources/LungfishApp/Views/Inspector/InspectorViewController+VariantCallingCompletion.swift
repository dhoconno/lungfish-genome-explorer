// InspectorViewController+VariantCallingCompletion.swift - How the Call Variants row ends after a good run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension InspectorViewController {
    /// Ends the row of a Call Variants run that finished. A static function so a test can end a row the way the launcher does.
    @MainActor
    @discardableResult
    static func completeVariantCallingRow(
        _ id: UUID,
        bundleURL: URL,
        result: CLIVariantCallingResult,
        center: OperationCenter = .shared
    ) -> Bool {
        center.complete(id: id, detail: variantCallingCompletionDetail(for: result))
    }
}
