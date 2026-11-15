// PlanPipeline.swift - The parts schema 2 adds to a plan: the pipeline, the reference and barcode list identities, the
// output policy and the instrument (Phase 5.3 lane EX-TOOL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The identity of the chain a schema 2 plan runs, in the words of the RNA-seq result's manifest, so the adopt fills the
/// result's `route`, `modality` and `referenceSet` from the plan (docs/formats/executor-plan.md, The pipeline).
package struct PlanPipeline: Codable, Sendable, Equatable {
    package var id: String
    /// The chain's own version, a whole number the plan writer raises when it changes a step, a tool or an argv rule.
    package var version: Int
    package var preset: PlanPipelinePreset
    /// Absent for a plan that makes no counts, such as an index build.
    package var modality: PlanPipelineModality?
    /// Absent for a plan that makes no counts.
    package var route: PlanPipelineRoute?
    /// The one set every `reference` entry names.
    package var referenceSet: PlanPipelineReferenceSet
    /// Each choice the chain offers. Each key of `route.settings` has one entry here with the same id and value.
    package var settings: [PlanPipelineSetting]

    package init(
        id: String, version: Int, preset: PlanPipelinePreset, modality: PlanPipelineModality?, route: PlanPipelineRoute?,
        referenceSet: PlanPipelineReferenceSet, settings: [PlanPipelineSetting]
    ) {
        self.id = id
        self.version = version
        self.preset = preset
        self.modality = modality
        self.route = route
        self.referenceSet = referenceSet
        self.settings = settings
    }
}

/// The preset the person chose, with the name the person read.
package struct PlanPipelinePreset: Codable, Sendable, Equatable {
    package var id: String
    package var name: String

    package init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The result's `modality`.
package enum PlanPipelineModality: String, Codable, Sendable, CaseIterable {
    case bulk
    case singleCell = "single-cell"
}

/// The result's `route`, key for key: the counting tool, its version and, as text, every setting that changes counts.
package struct PlanPipelineRoute: Codable, Sendable, Equatable {
    package var id: String
    package var tool: String
    package var toolVersion: String
    package var settings: [String: String]

    package init(id: String, tool: String, toolVersion: String, settings: [String: String]) {
        self.id = id
        self.tool = tool
        self.toolVersion = toolVersion
        self.settings = settings
    }
}

/// The result's `referenceSet`.
package struct PlanPipelineReferenceSet: Codable, Sendable, Equatable {
    package enum Layout: String, Codable, Sendable, CaseIterable {
        case lge
        case deposit
    }

    package var id: String
    package var layout: Layout

    package init(id: String, layout: Layout) {
        self.id = id
        self.layout = layout
    }
}

/// One choice of the chain, with the source that set it: `option`, `default` or, for the duplicates line of reads
/// that the import deduplicated, `recipe`.
package struct PlanPipelineSetting: Codable, Sendable, Equatable {
    package var id: String
    package var label: String
    package var value: String
    package var source: ImportSettingSource

    package init(id: String, label: String, value: String, source: ImportSettingSource) {
        self.id = id
        self.label = label
        self.value = value
        self.source = source
    }
}

/// What happens to one output of a schema 2 step when the job ends.
package enum PlanOutputPolicy: String, Codable, Sendable, CaseIterable {
    /// The job returns the file to the Mac at its plan path, for the adopt.
    case home
    /// The job keeps the file in the group's staging folder, where a later plan pins it as a `reference` entry.
    case staged
    /// The file goes with the job's scratch folder. The record states its digests as evidence of what ran.
    case stays
}

/// The identity a `reference` entry carries: the set, the file's path in it and, for an index file, the index.
package struct PlanReferenceIdentity: Codable, Sendable, Equatable {
    package var setID: String
    /// The path inside the set's folder, or inside the index's own folder for an index file.
    package var path: String
    package var index: PlanReferenceIndex?

    package init(setID: String, path: String, index: PlanReferenceIndex? = nil) {
        self.setID = setID
        self.path = path
        self.index = index
    }

    /// The entry's `relativePath` the identity gives, so two sets or two indexes never share a path.
    package var relativePath: String {
        if let index { return "references/\(setID)/indexes/\(index.key)/\(path)" }
        return "references/\(setID)/\(path)"
    }
}

/// The index a `reference` entry's file belongs to: its folder name and the tool that built it.
package struct PlanReferenceIndex: Codable, Sendable, Equatable {
    package var key: String
    package var tool: PlanToolPin

    package init(key: String, tool: PlanToolPin) {
        self.key = key
        self.tool = tool
    }
}

/// Where a 10x barcode list comes from.
package enum PlanBarcodeListSource: String, Codable, Sendable, CaseIterable {
    /// The list LGE ships in the tool image, which the executor copies from the manifest's `files` into the work root.
    case image
    /// A list the person gave.
    case supplied
}

/// The identity a `barcodeList` entry carries: the known list its SHA-256 matches and where the file comes from.
package struct PlanBarcodeListIdentity: Codable, Sendable, Equatable {
    package var name: String
    package var source: PlanBarcodeListSource

    package init(name: String, source: PlanBarcodeListSource) {
        self.name = name
        self.source = source
    }
}

/// The instrument the poly-G record line names. It changes no argv.
package struct PlanSampleInstrument: Codable, Sendable, Equatable {
    package var model: String
    /// True when LGE read the model from the read names, false when the person or the sample sheet gave it.
    package var inferred: Bool

    package init(model: String, inferred: Bool) {
        self.model = model
        self.inferred = inferred
    }
}
