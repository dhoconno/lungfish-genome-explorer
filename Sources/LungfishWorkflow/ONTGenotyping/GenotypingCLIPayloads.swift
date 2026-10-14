// GenotypingCLIPayloads.swift - The documents the genotyping commands print
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

package struct ONTGenotypingCLIPayload: Decodable {
    package let mappingBAMPath: String
    package let mappingBAIPath: String
    package let retainedBAMPath: String
    package let retainedBAIPath: String
    package let reportCSVPath: String
    package let sampleSummaryCSVPath: String
    package let statsJSONPath: String
    package let workbookPath: String
    package let provenancePath: String
    package let outputDirectory: String
    package let referenceFASTAPath: String
    package let sourceReferenceBundlePath: String?

    package var mappingBAMURL: URL { URL(fileURLWithPath: mappingBAMPath).standardizedFileURL }
    package var mappingBAIURL: URL { URL(fileURLWithPath: mappingBAIPath).standardizedFileURL }
    package var retainedBAMURL: URL { URL(fileURLWithPath: retainedBAMPath).standardizedFileURL }
    package var retainedBAIURL: URL { URL(fileURLWithPath: retainedBAIPath).standardizedFileURL }
    package var reportCSVURL: URL { URL(fileURLWithPath: reportCSVPath).standardizedFileURL }
    package var sampleSummaryCSVURL: URL { URL(fileURLWithPath: sampleSummaryCSVPath).standardizedFileURL }
    package var statsJSONURL: URL { URL(fileURLWithPath: statsJSONPath).standardizedFileURL }
    package var workbookURL: URL { URL(fileURLWithPath: workbookPath).standardizedFileURL }
    package var provenanceURL: URL { URL(fileURLWithPath: provenancePath).standardizedFileURL }
}

package struct FullLengthONTMHCGenotypingCLIPayload: Decodable {
    package let outputDirectory: String
    package let reportCSVPath: String
    package let sampleSummaryCSVPath: String
    package let statsJSONPath: String
    package let workbookPath: String
    package let primaryWorkbookPath: String?
    package let haplotypeAnalysisPath: String?
    package let unmatchedClustersFASTAPath: String
    package let cdnaClustersFASTAPath: String
    package let provenancePath: String
    package let referenceFASTAPath: String

    package var outputDirectoryURL: URL { URL(fileURLWithPath: outputDirectory).standardizedFileURL }
    package var reportCSVURL: URL { URL(fileURLWithPath: reportCSVPath).standardizedFileURL }
    package var sampleSummaryCSVURL: URL { URL(fileURLWithPath: sampleSummaryCSVPath).standardizedFileURL }
    package var statsJSONURL: URL { URL(fileURLWithPath: statsJSONPath).standardizedFileURL }
    package var workbookURL: URL { URL(fileURLWithPath: workbookPath).standardizedFileURL }
    package var primaryWorkbookURL: URL? { primaryWorkbookPath.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    package var haplotypeAnalysisURL: URL? { haplotypeAnalysisPath.map { URL(fileURLWithPath: $0).standardizedFileURL } }
    package var unmatchedClustersFASTAURL: URL { URL(fileURLWithPath: unmatchedClustersFASTAPath).standardizedFileURL }
    package var cdnaClustersFASTAURL: URL { URL(fileURLWithPath: cdnaClustersFASTAPath).standardizedFileURL }
    package var provenanceURL: URL { URL(fileURLWithPath: provenancePath).standardizedFileURL }
}
