// DemultiplexEngine.swift - The tool that splits reads by barcode
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

public enum DemultiplexEngine: String, Codable, Sendable, CaseIterable {
    case cutadapt
    case exactBareBarcode = "exact-bare"
}
