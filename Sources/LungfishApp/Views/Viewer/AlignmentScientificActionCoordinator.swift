import Foundation
import LungfishCore
import LungfishWorkflow
import LungfishKit
import LungfishIO

private func defaultDestination(
    capability: AlignmentOutputCapability,
    outputBaseName: String
) throws -> AlignmentReadExtractionPublicationDestination {
    switch capability {
    case .projectDerivedRoot(let root):
        let name = ExtractionBundleNaming.sanitizeFilename(outputBaseName)
        let finalURL = root.appendingPathComponent("alignment-read-extractions", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString).lungfishfastq", isDirectory: true)
        return .bundle(finalURL)
    case .userSelectedDestination:
        throw AlignmentScientificActionError.destinationUnavailable("Choose an output destination before extracting reads.")
    }
}

/// Resolves where a read extraction on immutable alignment evidence publishes,
/// before its row begins. `lungfish-cli extract reads` stages and publishes the
/// reads (ViewerViewController+MappingOperationBegin.swift, Phase 2.10 A51).
@MainActor
final class AlignmentScientificActionCoordinator {
    typealias DestinationResolver = (AlignmentOutputCapability, String) throws -> AlignmentReadExtractionPublicationDestination

    private let destinationResolver: DestinationResolver

    init(
        destinationResolver: @escaping DestinationResolver = defaultDestination
    ) {
        self.destinationResolver = destinationResolver
    }

    /// Resolves a final destination before either scientific validation gate.
    /// User-selected destinations are delegated to the AppKit composition root.
    func resolveDestination(
        for capability: AlignmentOutputCapability,
        outputBaseName: String
    ) throws -> AlignmentReadExtractionPublicationDestination {
        try destinationResolver(capability, outputBaseName)
    }

    /// Resolves destinations that require user interaction before any
    /// Operation Center row or scientific subprocess is started.
    func resolveDestination(
        for capability: AlignmentOutputCapability,
        outputBaseName: String,
        userDestinationChooser: (String) async -> URL?
    ) async throws -> AlignmentReadExtractionPublicationDestination {
        switch capability {
        case .projectDerivedRoot:
            return try destinationResolver(capability, outputBaseName)
        case .userSelectedDestination:
            guard let chosenURL = await userDestinationChooser(outputBaseName) else {
                throw AlignmentScientificActionError.destinationCancelled(
                    "Alignment read extraction was cancelled before launch."
                )
            }
            return .bundle(normalizedBundleURL(chosenURL))
        }
    }

    private func normalizedBundleURL(_ url: URL) -> URL {
        let normalized = url.standardizedFileURL
        guard normalized.pathExtension.lowercased() != FASTQBundle.directoryExtension else {
            if normalized.pathExtension == FASTQBundle.directoryExtension {
                return normalized
            }
            return normalized.deletingPathExtension()
                .appendingPathExtension(FASTQBundle.directoryExtension)
        }
        guard normalized.pathExtension.isEmpty else {
            return normalized.deletingPathExtension()
                .appendingPathExtension(FASTQBundle.directoryExtension)
        }
        return normalized.appendingPathExtension(FASTQBundle.directoryExtension)
    }
}

enum AlignmentScientificActionError: LocalizedError, Sendable, Equatable {
    case emptySelection
    case contextUnavailable
    case destinationUnavailable(String)
    case destinationCancelled(String)
    var errorDescription: String? {
        switch self {
        case .emptySelection: return "Select at least one read."
        case .contextUnavailable: return "Alignment evidence is unavailable."
        case .destinationUnavailable(let message), .destinationCancelled(let message): return message
        }
    }
}
