import Combine
import Foundation
import LungfishIO
import LungfishWorkflow

@MainActor
final class PrimerAnalysisViewerModel: ObservableObject {
  enum State {
    case loading
    case loaded(PrimerAnalysisViewerSnapshot)
    case failed(String)
  }

  @Published private(set) var state: State = .loading

  private let loader: @Sendable (URL) async throws -> PrimerAnalysisViewerSnapshot
  private var loadGeneration: UInt64 = 0

  init(
    loader: @escaping @Sendable (URL) async throws -> PrimerAnalysisViewerSnapshot = {
      try PrimerAnalysisViewerSnapshot.load(from: $0)
    }
  ) {
    self.loader = loader
  }

  func load(from url: URL) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    state = .loading
    let loader = self.loader
    let worker = Task.detached(priority: .userInitiated) {
      try await loader(url)
    }
    do {
      let snapshot = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard generation == loadGeneration, !Task.isCancelled else { return }
      state = .loaded(snapshot)
    } catch {
      guard generation == loadGeneration, !Task.isCancelled else { return }
      state = .failed(error.localizedDescription)
    }
  }
}
