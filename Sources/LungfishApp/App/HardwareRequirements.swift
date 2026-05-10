// HardwareRequirements.swift - User-visible platform and resource requirements
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum HardwareRequirements {
    static let minimumMacOSDisplay = "Minimum macOS 26 Tahoe"
    static let cpuArchitectureDisplay = "Apple Silicon required"
    static let minimumRAMDisplay = "16 GB RAM minimum"
    static let recommendedRAMDisplay = "32 GB RAM recommended for metagenomics and assembly"
    static let recommendedDiskDisplay = "100 GB free disk recommended for tool packs, databases, and projects"

    static let aboutLines: [String] = [
        minimumMacOSDisplay,
        cpuArchitectureDisplay,
        minimumRAMDisplay,
        recommendedRAMDisplay,
        recommendedDiskDisplay,
    ]
}
