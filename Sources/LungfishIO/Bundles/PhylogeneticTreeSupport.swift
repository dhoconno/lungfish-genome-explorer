import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct PhylogeneticTreeSupport: Codable, Sendable, Equatable {
    public let rawValue: String
    public let interpretation: String

    public init(rawValue: String, interpretation: String) {
        self.rawValue = rawValue
        self.interpretation = interpretation
    }
}

/// One typed branch support value split from a node label such as "99.9/100".
///
/// `label` is one of the support labels recorded in the tree manifest, for example
/// "SH-aLRT", "aBayes" or "UFBoot". `rawValue` keeps the text exactly as the tree file wrote it.
public struct PhylogeneticTreeSupportValue: Codable, Sendable, Equatable {
    public let label: String
    public let rawValue: String
    public let value: Double

    public init(label: String, rawValue: String, value: Double) {
        self.label = label
        self.rawValue = rawValue
        self.value = value
    }
}

/// The support labels IQ-TREE can write, in the order IQ-TREE joins them with "/".
public enum PhylogeneticTreeSupportLabel {
    public static let shALRT = "SH-aLRT"
    public static let aBayes = "aBayes"
    public static let ufBoot = "UFBoot"
}
