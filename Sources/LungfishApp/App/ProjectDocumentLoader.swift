// ProjectDocumentLoader.swift - Builds loaded documents from the sequences stored in a project
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DocumentManager")

@MainActor
enum ProjectDocumentLoader {
    static func catalogDocuments(_ summaries: [SequenceSummary], projectURL: URL) -> [LoadedDocument] {
        summaries.map { summary in
            let document = LoadedDocument(url: projectURL.appendingPathComponent(summary.name), type: .lungfishProject)
            document.projectSequenceID = summary.id
            return document
        }
    }

    static func loadSequences(from project: ProjectFile) throws -> [LoadedDocument] {
        let sequenceSummaries = try project.listSequences()
        logger.info("ProjectDocumentLoader: Found \(sequenceSummaries.count) sequences")
        var projectDocuments: [LoadedDocument] = []

        for summary in sequenceSummaries {
            let content = try project.getSequenceContent(id: summary.id)
            let alphabet: SequenceAlphabet = summary.alphabet == "dna" ? .dna :
                summary.alphabet == "rna" ? .rna : .protein
            let sequence = try Sequence(
                id: summary.id,
                name: summary.name,
                alphabet: alphabet,
                bases: content
            )

            let document = LoadedDocument(
                url: project.url.appendingPathComponent(summary.name),
                type: .lungfishProject
            )
            document.sequences = [sequence]
            document.annotations = try project.getAnnotations(for: summary.id).map { stored in
                SequenceAnnotation(
                    id: stored.id,
                    type: AnnotationType(rawValue: stored.type) ?? .region,
                    name: stored.name,
                    intervals: [AnnotationInterval(
                        start: stored.startPosition,
                        end: stored.endPosition
                    )],
                    strand: stored.strand == "+" ? .forward : (stored.strand == "-" ? .reverse : .unknown),
                    qualifiers: (stored.qualifiers ?? [:]).mapValues { AnnotationQualifier($0) }
                )
            }
            projectDocuments.append(document)
            logger.debug("ProjectDocumentLoader: Loaded sequence '\(summary.name, privacy: .public)'")
        }

        return projectDocuments
    }
}
