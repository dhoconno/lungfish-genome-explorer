// TaxTriageRowsPage.swift - One page of TaxTriage taxonomy rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

public struct TaxTriageRowsPage: Sendable {
    public let rows: [TaxTriageTaxonomyRow]
    public let totalMatchingRows: Int

    public init(rows: [TaxTriageTaxonomyRow], totalMatchingRows: Int) {
        self.rows = rows
        self.totalMatchingRows = totalMatchingRows
    }
}
