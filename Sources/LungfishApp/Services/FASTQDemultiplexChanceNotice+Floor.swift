// FASTQDemultiplexChanceNotice+Floor.swift - The floor's chance line in the window
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

extension FASTQDemultiplexChanceNotice {
    /// The line under the row's name when barcodes sit within the floor's chance, which starts with the cause.
    static let floorRowPrefix = "Some barcodes could be chance matches. "

    /// The one warning a finished run's Operations row carries, with the line that starts its detail.
    struct RowNotice: Equatable {
        let message: String
        let detailPrefix: String

        func rowDetail(_ completionDetail: String) -> String {
            completionDetail
        }
    }

    static func floorNotice(for result: FASTQOperationExecutionResult) -> String? {
        nil
    }

    static func rowNotice(for result: FASTQOperationExecutionResult) -> RowNotice? {
        nil
    }
}
