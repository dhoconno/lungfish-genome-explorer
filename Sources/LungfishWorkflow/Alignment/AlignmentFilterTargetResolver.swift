// AlignmentFilterTargetResolver.swift - Resolve bundle-centric filter targets
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum AlignmentFilterTarget: Sendable, Equatable {
    case bundle(URL)
    case mappingResult(URL)
}

public struct ResolvedAlignmentFilterTarget: Sendable, Equatable {
    public let bundleURL: URL
    public let mappingResultURL: URL?

    public init(bundleURL: URL, mappingResultURL: URL? = nil) {
        self.bundleURL = bundleURL
        self.mappingResultURL = mappingResultURL
    }
}

public enum AlignmentFilterTargetResolverError: Error, LocalizedError, Sendable, Equatable {
    case missingViewerBundle(URL)

    public var errorDescription: String? {
        switch self {
        case .missingViewerBundle(let mappingResultURL):
            return "Mapping result does not contain a viewer bundle: \(mappingResultURL.path)"
        }
    }
}

public enum AlignmentFilterTargetResolver {
    public static func resolve(_ target: AlignmentFilterTarget) throws -> ResolvedAlignmentFilterTarget {
        switch target {
        case .bundle(let bundleURL):
            return ResolvedAlignmentFilterTarget(bundleURL: bundleURL.standardizedFileURL)
        case .mappingResult(let mappingResultURL):
            let standardizedMappingResultURL = mappingResultURL.standardizedFileURL
            let result = try MappingResult.load(from: standardizedMappingResultURL)
            guard let viewerBundleURL = result.viewerBundleURL?.standardizedFileURL else {
                throw AlignmentFilterTargetResolverError.missingViewerBundle(standardizedMappingResultURL)
            }
            return ResolvedAlignmentFilterTarget(
                bundleURL: viewerBundleURL,
                mappingResultURL: standardizedMappingResultURL
            )
        }
    }
}
