// OperationCenter+QuitList.swift - What a quit of LGE would end
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension OperationCenter {
    /// The operations a quit would end, which the quit alert lists.
    public var quitListItems: [Item] {
        activeItems
    }
}
