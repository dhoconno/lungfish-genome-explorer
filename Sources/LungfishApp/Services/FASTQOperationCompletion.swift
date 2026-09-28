import Foundation
import LungfishKit

/// Finishes a FASTQ operation's Operations-panel row with the bundles and
/// folders it produced.
///
/// The Operations panel enables a row's Results button and its Reveal Output
/// Files menu item only from the URLs recorded at completion. Every FASTQ
/// launch path (derivative bundles such as fastp trimming, grouped results
/// such as demultiplexing, assembly and mapping analyses) finishes here so a
/// completed run can never look like it produced nothing.
@MainActor
enum FASTQOperationCompletion {
    /// The URLs a finished execution published, in order, without duplicates.
    static func outputURLs(for result: FASTQOperationExecutionResult) -> [URL] {
        uniqued(result.importedURLs + [result.groupedContainerURL].compactMap { $0 })
    }

    @discardableResult
    static func complete(
        id: UUID,
        detail: String,
        result: FASTQOperationExecutionResult,
        center: OperationCenter = .shared
    ) -> Bool {
        complete(id: id, detail: detail, outputURLs: outputURLs(for: result), center: center)
    }

    @discardableResult
    static func complete(
        id: UUID,
        detail: String,
        outputURLs: [URL],
        center: OperationCenter = .shared
    ) -> Bool {
        center.complete(id: id, detail: detail, outputURLs: uniqued(outputURLs))
    }

    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
