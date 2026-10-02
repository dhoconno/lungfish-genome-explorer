import CryptoKit
import Darwin
import Foundation

struct ONTGenotypeWorkbookCleanupOperations: Sendable {
    typealias RenameExclusive = @Sendable (
        Int32,
        UnsafePointer<CChar>,
        Int32,
        UnsafePointer<CChar>,
        UInt32,
        PortableExclusiveRename.RegularSourceWitness?
    ) -> PortableExclusiveRename.Outcome

    var renameExclusive: RenameExclusive
    var checkpoint: @Sendable (String) throws -> Void

    init(
        renameExclusive: @escaping RenameExclusive = {
            PortableExclusiveRename.renameatxNPReporting(
                $0,
                $1,
                $2,
                $3,
                $4,
                sourceWitness: $5
            )
        },
        checkpoint: @escaping @Sendable (String) throws -> Void = { _ in }
    ) {
        self.renameExclusive = renameExclusive
        self.checkpoint = checkpoint
    }

    static let darwin = ONTGenotypeWorkbookCleanupOperations()
}
