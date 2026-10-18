// GenotypeManualDefinitionsExport.swift - The manual haplotype definitions export the genotype viewer and its leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The manual haplotype definitions export (Phase 2.12 lane 12.35, ARCH ruling 1.1 row A14, BIO answer to Q-A3).
///
/// The open genotype store can hold assignments that its saved sidecar lacks, since a store over a bundle it cannot
/// write keeps an edit in memory only. So the viewer writes the store's assignments to the selection file of ARCH
/// ruling 1.3, and `genotype export-manual-definitions` reads them from there, never from the bundle. The viewer and
/// the leaf build the payload with ``currentAssignments(_:)`` and ``payload(currentAssignments:)``.
public enum GenotypeManualDefinitionsExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1, row A14).
    public static let commandPath = ["genotype", "export-manual-definitions"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish genotype export-manual-definitions"
    /// The field of a selection's edited values that holds one assignment, encoded as JSON with sorted keys.
    public static let assignmentField = "manualHaplotypeAssignment"

    /// The leaf's invocation, with absolute standardized paths. The begin helper passes its `arguments()` to the
    /// runner and to the row's command, and the leaf records its `canonicalArgv()`.
    public static func invocation(
        bundleURL: URL,
        selectionURL: URL,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: bundleURL.standardizedFileURL.path,
            selection: selectionURL.standardizedFileURL.path,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The selection file of the store's raw assignments, in the sidecar's order. Each assignment is one identity,
    /// its position counted from 1, with its edited values under ``assignmentField``. The index that picks the
    /// current assignments reads the order, so the identities keep it.
    public static func selection(assignments: [ManualHaplotypeAssignment]) throws -> ViewerExportSelection {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var identities: [String] = []
        var editedValues: [String: [String: String]] = [:]
        for (offset, assignment) in assignments.enumerated() {
            let identity = String(offset + 1)
            identities.append(identity)
            editedValues[identity] = [assignmentField: String(decoding: try encoder.encode(assignment), as: UTF8.self)]
        }
        return ViewerExportSelection(identities: identities, editedValues: editedValues)
    }

    /// The raw assignments a selection file holds, in its identities' order.
    public static func assignments(from selection: ViewerExportSelection) throws -> [ManualHaplotypeAssignment] {
        try selection.identities.map { identity in
            guard let json = selection.editedValues[identity]?[assignmentField] else {
                throw SelectionError.missingAssignment(identity)
            }
            return try JSONDecoder().decode(ManualHaplotypeAssignment.self, from: Data(json.utf8))
        }
    }

    /// The assignments the export writes, the current one for each assignment key.
    public static func currentAssignments(_ assignments: [ManualHaplotypeAssignment]) -> [ManualHaplotypeAssignment] {
        GenotypeManualHaplotypeAssignmentIndex(assignments: assignments).currentAssignments
    }

    /// The bytes of the export, the current assignments as JSON pretty printed with sorted keys.
    public static func payload(currentAssignments: [ManualHaplotypeAssignment]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(currentAssignments)
    }

    public enum SelectionError: Error, LocalizedError, Equatable {
        case missingAssignment(String)

        public var errorDescription: String? {
            switch self {
            case .missingAssignment(let identity):
                return "The selection names assignment \(identity) but holds no \(GenotypeManualDefinitionsExport.assignmentField) for it."
            }
        }
    }
}
