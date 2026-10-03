@preconcurrency import Foundation
import CryptoKit
import Darwin

/// Injectable filesystem operations. The live implementation intentionally uses
/// only paths supplied by the installer so failed source builds never touch a
/// prior published overlay.
public struct ManagedToolSourceFileSystem: Sendable {
    public var createDirectory: @Sendable (URL) throws -> Void
    public var copyItem: @Sendable (URL, URL) throws -> Void
    public var moveItem: @Sendable (URL, URL) throws -> Void
    public var removeItem: @Sendable (URL) throws -> Void
    public var fileExists: @Sendable (URL) -> Bool
    public var isExecutable: @Sendable (URL) -> Bool
    public var contents: @Sendable (URL) throws -> [URL]

    public init(
        createDirectory: @escaping @Sendable (URL) throws -> Void,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void,
        moveItem: @escaping @Sendable (URL, URL) throws -> Void,
        removeItem: @escaping @Sendable (URL) throws -> Void,
        fileExists: @escaping @Sendable (URL) -> Bool,
        isExecutable: @escaping @Sendable (URL) -> Bool,
        contents: @escaping @Sendable (URL) throws -> [URL]
    ) {
        self.createDirectory = createDirectory
        self.copyItem = copyItem
        self.moveItem = moveItem
        self.removeItem = removeItem
        self.fileExists = fileExists
        self.isExecutable = isExecutable
        self.contents = contents
    }

    public static let live = ManagedToolSourceFileSystem(
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
        copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
        moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) },
        contents: { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
    )
}
