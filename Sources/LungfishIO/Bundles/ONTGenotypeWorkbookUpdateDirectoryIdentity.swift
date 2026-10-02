import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeWorkbookUpdateDirectoryIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64

    public init(path: String, device: UInt64, inode: UInt64) {
        self.path = path
        self.device = device
        self.inode = inode
    }
}
