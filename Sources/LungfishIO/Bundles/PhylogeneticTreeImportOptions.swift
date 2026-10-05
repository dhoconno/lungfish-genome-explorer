import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct PhylogeneticTreeImportOptions: Sendable, Equatable {
    public let name: String?
    public let argv: [String]?
    public let command: String?
    public let sourceFormat: String?
    public let toolName: String
    public let toolVersion: String
    /// Labels for the "/"-joined support values in internal node labels, in IQ-TREE's order.
    public let supportLabels: [String]?
    /// Written to the manifest, for example "substitutions per site".
    public let branchLengthUnit: String?
    public let inference: PhylogeneticTreeInferenceSummary?
    /// Raw tip label to final label, applied to tips before the bundle is written. Every key
    /// must name a tip in the tree. Tips without an entry keep their label.
    public let tipLabelMap: [String: String]?

    public init(
        name: String? = nil,
        argv: [String]? = nil,
        command: String? = nil,
        sourceFormat: String? = nil,
        toolName: String = "lungfish import tree",
        toolVersion: String = PhylogeneticTreeBundleImporter.toolVersion,
        supportLabels: [String]? = nil,
        branchLengthUnit: String? = nil,
        inference: PhylogeneticTreeInferenceSummary? = nil,
        tipLabelMap: [String: String]? = nil
    ) {
        self.name = name
        self.argv = argv
        self.command = command
        self.sourceFormat = sourceFormat
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.supportLabels = supportLabels
        self.branchLengthUnit = branchLengthUnit
        self.inference = inference
        self.tipLabelMap = tipLabelMap
    }
}
