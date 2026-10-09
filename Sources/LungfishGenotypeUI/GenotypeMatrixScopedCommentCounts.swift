import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeMatrixScopedCommentCounts: Equatable, Sendable {
    let alleleRow: Int
    let sampleColumn: Int
    let cell: Int

    static let zero = GenotypeMatrixScopedCommentCounts(
        alleleRow: 0,
        sampleColumn: 0,
        cell: 0
    )

    var total: Int {
        alleleRow + sampleColumn + cell
    }
}
