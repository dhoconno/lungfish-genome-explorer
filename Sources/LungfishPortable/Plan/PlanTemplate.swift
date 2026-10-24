// PlanTemplate.swift - The plan of one recipe with no sample value, and the pure fill that makes one sample's plan (CHTC C4 lane F)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One input file a template's steps read, named by the path its entry will hold, with no SHA-256 and no size.
package struct PlanInputSlot: Sendable, Equatable {
    /// Such as `inputs/R1.fastq.gz`. Its suffix is the one `PlanTemplate.fastqSuffix(of:)` gives the slot's files.
    package var relativePath: String

    package init(relativePath: String) {
        self.relativePath = relativePath
    }
}

/// The SHA-256 and size one input file of a sample pins.
package struct PlanInputFile: Sendable, Equatable {
    /// Lowercase hexadecimal SHA-256 of the file's bytes.
    package var sha256: String
    package var size: Int64

    package init(sha256: String, size: Int64) {
        self.sha256 = sha256
        self.size = size
    }
}

/// What one sample gives a template (V5): its name, its files' names, its sample-sheet labels and each input's SHA-256
/// and size. It holds no parameter, so a fill cannot change a step, a tool, a setting or a deadline, and it has no
/// field for any value the plan does not carry.
package struct PlanSampleFill: Sendable, Equatable {
    package var sampleName: String
    /// Each input's file name, R1 then R2, or the one file.
    package var originalFilenames: [String]
    /// The sample sheet's labels for the sample, which the adopt takes from the plan.
    package var sampleSheet: [PlanKeyValue]
    /// Each input's SHA-256 and size, in the order of `originalFilenames`.
    package var inputs: [PlanInputFile]

    package init(sampleName: String, originalFilenames: [String], sampleSheet: [PlanKeyValue] = [], inputs: [PlanInputFile]) {
        self.sampleName = sampleName
        self.originalFilenames = originalFilenames
        self.sampleSheet = sampleSheet
        self.inputs = inputs
    }
}

/// Why a template cannot take a sample, naming the field. The Mac and a Linux caller show these same words.
package struct PlanFillRefusal: Error, Equatable, Sendable {
    package var field: String
    package var reason: String

    package init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }
}

/// The plan of one recipe for every sample of one input shape (V5, ARCH-fill): every `ExecutionPlan` field but
/// `sample`, with one slot per input in place of the input entries, and the platform. The Mac plans it once with the
/// recipe engine. Every work file uses the stem `sample`, so the plans of two samples differ only in `sample` and in
/// the input entries' SHA-256 and size, and `fill(_:)` sets those and nothing else.
package struct PlanTemplate: Sendable, Equatable {
    package var schemaVersion: Int
    /// The executor, recipe and database entries in plan order. The fill puts the input entries before the first
    /// database entry, where the Mac's emitter puts them.
    package var entries: [PlanEntry]
    /// One slot per input, R1 then R2, or the one file.
    package var inputs: [PlanInputSlot]
    package var executor: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var tools: [PlanToolPin]
    package var recipe: PlanRecipeIdentity?
    /// The platform the import names for every sample. It is a setting, not a sample value.
    package var platform: String?
    package var storage: PlanStorageSettings
    package var clumping: PlanClumpingChoice
    package var graceSeconds: Double
    package var steps: [PlanStep]

    package init(
        schemaVersion: Int = ExecutionPlan.currentSchemaVersion,
        entries: [PlanEntry],
        inputs: [PlanInputSlot],
        executor: PlanExecutorBuild,
        imageManifest: PlanImageManifestPin,
        tools: [PlanToolPin],
        recipe: PlanRecipeIdentity?,
        platform: String?,
        storage: PlanStorageSettings,
        clumping: PlanClumpingChoice,
        graceSeconds: Double,
        steps: [PlanStep]
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.inputs = inputs
        self.executor = executor
        self.imageManifest = imageManifest
        self.tools = tools
        self.recipe = recipe
        self.platform = platform
        self.storage = storage
        self.clumping = clumping
        self.graceSeconds = graceSeconds
        self.steps = steps
    }
}

extension PlanTemplate {
    /// The FASTQ suffix of a file name, kept so a tool sees the compression it expects. The Mac's emitter names each
    /// slot with it and the fill checks each sample's file names with it, so the Mac and a Linux caller apply one rule.
    package static func fastqSuffix(of name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".fastq.gz", ".fq.gz", ".fastq.bgz", ".fastq", ".fq", ".gz"] where lower.hasSuffix(suffix) {
            return suffix
        }
        return ".fastq"
    }

    /// The plan of one sample. It reads no file, no clock, no environment and no host fact. It refuses a sample whose
    /// number of inputs or file suffixes the template does not hold, and then checks the plan by the decoder's rules,
    /// whose `PlanDecodeError` it passes on as it is.
    package func fill(_ sample: PlanSampleFill) throws -> ExecutionPlan {
        let files = inputs.count == 1 ? "1 input file" : "\(inputs.count) input files"
        guard sample.inputs.count == inputs.count else {
            throw PlanFillRefusal(field: "entries", reason: "This template reads \(files), and the sample gives \(sample.inputs.count).")
        }
        guard sample.originalFilenames.count == inputs.count else {
            throw PlanFillRefusal(
                field: "sample.originalFilenames",
                reason: "This template reads \(files), and the sample names \(sample.originalFilenames.count)."
            )
        }
        for (slot, name) in zip(inputs, sample.originalFilenames) {
            let expected = Self.fastqSuffix(of: slot.relativePath)
            let given = Self.fastqSuffix(of: name)
            guard given == expected else {
                throw PlanFillRefusal(
                    field: "sample.originalFilenames",
                    reason: "The file \(name) takes the suffix \(given), and this template's input \(slot.relativePath) takes \(expected). A sample whose files take another suffix needs a template of its own."
                )
            }
        }
        var originalSizeBytes: Int64 = 0
        for file in sample.inputs {
            let (sum, overflow) = originalSizeBytes.addingReportingOverflow(file.size)
            guard !overflow else {
                throw PlanFillRefusal(field: "sample.originalSizeBytes", reason: "The sample's input sizes add up to more than a plan can state.")
            }
            originalSizeBytes = sum
        }
        var planEntries = entries
        planEntries.insert(
            contentsOf: zip(inputs, sample.inputs).map {
                PlanEntry(role: .input, relativePath: $0.relativePath, sha256: $1.sha256, size: $1.size)
            },
            at: entries.firstIndex { $0.role == .database } ?? entries.count
        )
        let plan = ExecutionPlan(
            schemaVersion: schemaVersion, entries: planEntries, executor: executor, imageManifest: imageManifest,
            tools: tools, recipe: recipe,
            sample: PlanSampleValues(
                sampleName: sample.sampleName, originalFilenames: sample.originalFilenames,
                originalSizeBytes: originalSizeBytes, platform: platform, sampleSheet: sample.sampleSheet
            ),
            storage: storage, clumping: clumping, graceSeconds: graceSeconds, steps: steps
        )
        try plan.validate()
        return plan
    }
}
