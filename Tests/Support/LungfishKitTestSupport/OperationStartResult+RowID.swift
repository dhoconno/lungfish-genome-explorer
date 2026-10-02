// OperationStartResult+RowID.swift - The Operations panel row a begin call inserted
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension OperationStartResult {
    /// The ID of the Operations panel row `begin` inserted, whether the
    /// operation started or a bundle lock refused it.
    ///
    /// A test that only needs to find the row, to complete or fail it or to
    /// read the "Bundle is busy" row of a refusal, reads this instead of
    /// switching on the result. Operation code never does. It switches on the
    /// result and launches nothing on `.refused`.
    public var rowID: UUID {
        switch self {
        case .started(let id):
            return id
        case .refused(let refusal):
            return refusal.id
        }
    }
}
