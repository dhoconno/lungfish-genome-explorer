import CryptoKit
import Darwin
import Foundation

struct ONTGenotypeWorkbookRetirementFileWitness: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let sha256: String
}
