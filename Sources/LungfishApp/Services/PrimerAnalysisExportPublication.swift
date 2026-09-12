import Foundation
import LungfishKit

/// Publication and terminal Operations state must share one actor turn. Otherwise
/// a cancellation accepted after rename can hide an already published result.
@MainActor
enum PrimerAnalysisExportPublication {
  static func commit(stagedURL: URL, destinationURL: URL, center: OperationCenter,
                     operationID: UUID, validate: () throws -> Void) throws {
    try Task.checkCancellation()
    guard center.items.first(where: { $0.id == operationID })?.state == .running else {
      throw CancellationError()
    }
    try validate()
    guard center.items.first(where: { $0.id == operationID })?.state == .running else {
      throw CancellationError()
    }
    try PrimerAnalysisSelectionExportService.publishExclusively(stagedURL: stagedURL, destinationURL: destinationURL)
    center.complete(id: operationID, detail: "Saved in the project's Analyses folder.", outputURLs: [destinationURL])
  }
}
