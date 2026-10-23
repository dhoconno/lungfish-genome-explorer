// PlanEntry.swift - One file a plan pins in its folder, by role, relative path, SHA-256 and size (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The role of a file the plan pins. The image's tool manifest is not an entry: the plan pins it as
/// `ExecutionPlan.imageManifest` with no path, and the executor reads it from the image (SWIFT ruling Q-K4-1).
package enum PlanEntryRole: String, Codable, Sendable, CaseIterable {
    case recipe
    case database
    case input
    case executor
}

/// The identity a database index file carries beside its digest (C1 lane L5): the fields of the engine's own
/// `RecipeDatabaseRecord`, so the plan states what the in-process record states (BIO review fix 5 of K4 part A).
package struct PlanDatabaseIdentity: Codable, Sendable, Equatable {
    package var id: String
    package var version: String
    /// The index format the file's header or the lock gives, as text, or `unknown`.
    package var format: String
    /// The k-mer length and minimizer window the index header gives, the parameters of a scrub that passes neither.
    package var kmerLength: Int?
    package var windowSize: Int?
    /// Whether the bundled lock pins the file's SHA-256 and size, so the Mac checked it before the plan was written.
    package var lockPinned: Bool?
    /// The source and tool version the index was built from, from the lock or the install record.
    package var buildSourceSHA256: String?
    package var buildSourceSizeBytes: Int64?
    package var buildToolVersion: String?

    package init(
        id: String, version: String, format: String, kmerLength: Int? = nil, windowSize: Int? = nil,
        lockPinned: Bool? = nil, buildSourceSHA256: String? = nil, buildSourceSizeBytes: Int64? = nil,
        buildToolVersion: String? = nil
    ) {
        self.id = id
        self.version = version
        self.format = format
        self.kmerLength = kmerLength
        self.windowSize = windowSize
        self.lockPinned = lockPinned
        self.buildSourceSHA256 = buildSourceSHA256
        self.buildSourceSizeBytes = buildSourceSizeBytes
        self.buildToolVersion = buildToolVersion
    }
}

/// A file in the plan's folder. `PlanResourceResolver` resolves `relativePath` under the folder that holds the plan
/// file and refuses it when the size or SHA-256 differs.
package struct PlanEntry: Codable, Sendable, Equatable {
    package var role: PlanEntryRole
    package var relativePath: String
    /// Lowercase hexadecimal SHA-256 of the file's bytes.
    package var sha256: String
    package var size: Int64
    /// Present for a `database` entry only.
    package var database: PlanDatabaseIdentity?

    package init(role: PlanEntryRole, relativePath: String, sha256: String, size: Int64, database: PlanDatabaseIdentity? = nil) {
        self.role = role
        self.relativePath = relativePath
        self.sha256 = sha256
        self.size = size
        self.database = database
    }
}

/// The SHA-256 and size of the image's tool manifest, with no path (SWIFT ruling Q-K4-1).
package struct PlanImageManifestPin: Codable, Sendable, Equatable {
    package var sha256: String
    package var size: Int64

    package init(sha256: String, size: Int64) {
        self.sha256 = sha256
        self.size = size
    }
}

/// A tool the plan runs, as the image's tool manifest lists it. The executor refuses a step whose pin the manifest does
/// not list with the same three values.
package struct PlanToolPin: Codable, Sendable, Equatable, Hashable {
    /// The manifest's id, the program name such as `clumpify.sh`, `reformat.sh`, `bgzip`, `pigz` or `seqkit`.
    package var id: String
    package var version: String
    package var build: String

    package init(id: String, version: String, build: String) {
        self.id = id
        self.version = version
        self.build = build
    }
}
