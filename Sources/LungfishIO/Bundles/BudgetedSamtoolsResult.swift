// BudgetedSamtoolsResult.swift - Outcome of a record-budgeted samtools run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Darwin
import LungfishCore
import os.log

struct BudgetedSamtoolsResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let terminatedForBudget: Bool
    let retainedRecordCount: Int
}
