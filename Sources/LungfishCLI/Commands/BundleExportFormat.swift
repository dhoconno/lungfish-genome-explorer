// BundleExportFormat.swift - The export formats bundle export accepts
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// `CaseIterable` so the option's help lists every accepted value.
enum BundleExportFormat: String, ExpressibleByArgument, CaseIterable {
    case container
}
