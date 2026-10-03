import Foundation
import Darwin
import LungfishCore
import LungfishIO

struct GenotypeReviewableReferenceAuthority: Sendable {
    let records: [MHCReferenceRecord]
    let descriptors: [ProvenanceFileDescriptor]
    let snapshots: [GenotypeReviewAuthorityFileSnapshot]

    func requireUnchanged() throws {
        for snapshot in snapshots {
            try snapshot.requireUnchanged()
        }
    }
}
