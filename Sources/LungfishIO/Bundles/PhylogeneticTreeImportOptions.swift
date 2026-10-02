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

    public init(
        name: String? = nil,
        argv: [String]? = nil,
        command: String? = nil,
        sourceFormat: String? = nil,
        toolName: String = "lungfish import tree",
        toolVersion: String = PhylogeneticTreeBundleImporter.toolVersion
    ) {
        self.name = name
        self.argv = argv
        self.command = command
        self.sourceFormat = sourceFormat
        self.toolName = toolName
        self.toolVersion = toolVersion
    }
}
