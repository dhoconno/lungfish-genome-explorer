// FastqPrimerRemovalEngine.swift - The engines fastq primer-remove accepts
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum FastqPrimerRemovalEngine: String, ExpressibleByArgument {
    case bbduk
    case cutadaptLinked = "cutadapt-linked"
}
