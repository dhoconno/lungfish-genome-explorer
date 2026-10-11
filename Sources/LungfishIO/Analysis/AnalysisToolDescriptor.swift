// AnalysisToolDescriptor.swift - Plain data describing one analysis kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How the tools behind an analysis kind are provisioned.
///
/// The managed tool and pipeline ids are entries of the managed tool lock. The registry
/// holds them as data only. Workflow checks them against the lock.
public enum AnalysisToolProvisioning: Sendable, Hashable {
    /// A lock `tools[].id` or `packTools[].id`, for example `bbtools` for the `bbmap` analysis.
    case managedTool(ManagedToolID)
    /// A lock `pipelines[].id`, for example `nf-core-viralrecon` for the `viralrecon` analysis.
    case lockedPipeline(String)
    /// Runs from a container image.
    case container
    /// Results are imported from outside and nothing is run.
    case importedResult
    /// Implemented inside the app.
    case builtIn
}

/// Everything the app knows about one analysis kind as plain data.
public struct AnalysisToolDescriptor: Sendable, Hashable {
    public let id: AnalysisToolID
    /// Human-readable name. The `build-db` word and the classify output stem are the fields below.
    public let displayName: String
    /// True when imported results use `{id}-{sampleName}` directory naming.
    public let acceptsImportedSampleNames: Bool
    /// The sidebar SF Symbol name, or nil when the sidebar falls back to its generic circle.
    public let sidebarSymbolName: String?
    /// The short sidebar badge of a classifier batch, or nil when the kind has none.
    public let classifierBatchBadge: String?
    /// The word `lungfish-cli build-db` takes for this kind, or nil when the CLI builds no database for it.
    ///
    /// Today it is the display name in lowercase. Holding it as data keeps a new display name from
    /// changing the command line the app launches.
    public let buildDatabaseToken: String?
    /// The stem of the name a classify run gives its output, or nil when the kind has none.
    ///
    /// Today it is the title of the FASTQ operation tool in lowercase. Holding it as data keeps a new
    /// title from renaming the folders a project already holds.
    public let outputStem: String?
    /// The managed tools this kind's pipeline launches and records as steps, by lock id. Empty for a kind that
    /// imports results, runs a container or runs only built-in code. A reader can check that a record of the kind
    /// names each of them. The ids are entries of the managed tool lock and Workflow checks them against the lock
    /// and its version probe table, as it does for `provisioning`.
    ///
    /// A kind provisioned with one managed tool lists it, unless the initializer is given another list. The tools
    /// a pipeline records beside it (samtools beside a mapper, Bracken beside Kraken2) are listed in the registry.
    /// A tool that runs only in some runs (bbmerge in an Illumina genotyping run that finds unmerged pairs) is
    /// listed, so the list says what the kind may run. No order is promised.
    public let runsTools: [ManagedToolID]
    public let provisioning: AnalysisToolProvisioning

    public init(
        id: AnalysisToolID,
        displayName: String,
        acceptsImportedSampleNames: Bool = false,
        sidebarSymbolName: String?,
        classifierBatchBadge: String? = nil,
        buildDatabaseToken: String? = nil,
        outputStem: String? = nil,
        runsTools: [ManagedToolID]? = nil,
        provisioning: AnalysisToolProvisioning
    ) {
        self.id = id
        self.displayName = displayName
        self.acceptsImportedSampleNames = acceptsImportedSampleNames
        self.sidebarSymbolName = sidebarSymbolName
        self.classifierBatchBadge = classifierBatchBadge
        self.buildDatabaseToken = buildDatabaseToken
        self.outputStem = outputStem
        if let runsTools {
            self.runsTools = runsTools
        } else if case .managedTool(let tool) = provisioning {
            self.runsTools = [tool]
        } else {
            self.runsTools = []
        }
        self.provisioning = provisioning
    }
}
