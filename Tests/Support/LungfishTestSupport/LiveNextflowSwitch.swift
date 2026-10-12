// LiveNextflowSwitch.swift - Whether a live Nextflow class runs, decided from an environment dictionary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner direction O5 (Phase 2.9). A test that can drive the real Nextflow keeps two classes. The
// stand-in class is the default and the fallback and stays in the tier it runs in. The live class,
// named ...LiveConformanceTests so the conformance tier selects it by the term "Conformance", runs
// its body only when a switch names the managed root it may use. Availability alone would start
// Docker work and NCBI downloads in every conformance run on a Mac that has every tool, and a
// switch alone would fail a Mac without Docker where a skip is wanted. So a live class asks this
// switch first, and LiveNextflowRun.begin then gates each precondition through ToolAvailability.
//
// The decision reads no process state. A unit test passes a dictionary and never calls setenv.

import Foundation

/// The switch of a live Nextflow class.
public enum LiveNextflowSwitch {
    /// Names a managed root. Setting it turns the live classes on and says which root they use.
    public static let liveRootVariable = "LUNGFISH_LIVE_NEXTFLOW_ROOT"

    /// The managed root of the whole run. A live class uses it only under `LUNGFISH_REQUIRE_TOOLS=1`
    /// with no live root, as the real-Nextflow cancel test takes its root.
    public static let storageRootVariable = "LUNGFISH_STORAGE_ROOT"

    /// `1` turns a skip into a failure everywhere (`ToolAvailability.requireTools`).
    public static let requireToolsVariable = "LUNGFISH_REQUIRE_TOOLS"

    /// The folder of released demo archives, as `DemoProjectProvenanceSweepTests` reads it.
    public static let archiveFolderVariable = "LUNGFISH_DEMO_ARCHIVE_DIR"

    /// What a skipped live class tells the person reading the test log.
    public static let offReason =
        "Set \(liveRootVariable) to a managed root, or set \(requireToolsVariable)=1 with "
        + "\(storageRootVariable) naming one, to run the live Nextflow classes."

    /// Which variable named the root.
    public enum Source: String, Equatable, Sendable {
        case liveRootVariable
        case requireToolsStorageRoot

        /// The variable that named the root, for messages.
        public var variable: String {
            switch self {
            case .liveRootVariable: LiveNextflowSwitch.liveRootVariable
            case .requireToolsStorageRoot: LiveNextflowSwitch.storageRootVariable
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Run the live class against `root`.
        case run(root: URL, source: Source)
        /// No switch is set. The live class skips and the stand-in class carries the test.
        case skip(reason: String)
        /// A switch is set and cannot be honoured. The live class fails, whatever the require flag says.
        case misconfigured(reason: String)
    }

    /// Decides from `environment` alone.
    ///
    /// - `LUNGFISH_LIVE_NEXTFLOW_ROOT` set to an absolute path runs the live class against that root.
    ///   A relative path is a misconfiguration, since the root goes on to the CLI as
    ///   `LUNGFISH_STORAGE_ROOT` and a relative path would mean another folder there.
    /// - Without it, `LUNGFISH_REQUIRE_TOOLS=1` runs the live class against `LUNGFISH_STORAGE_ROOT`.
    ///   With the flag and no absolute storage root there is no root to run against, which is a
    ///   misconfiguration and never a quiet pass.
    /// - Anything else skips. An empty or blank value counts as not set.
    public static func decide(environment: [String: String]) -> Decision {
        let liveRoot = value(of: liveRootVariable, in: environment)
        let storageRoot = value(of: storageRootVariable, in: environment)
        let requireTools = environment[requireToolsVariable] == "1"

        if let liveRoot {
            guard liveRoot.hasPrefix("/") else {
                return .misconfigured(
                    reason: "\(liveRootVariable) must be an absolute path to a managed root, not \"\(liveRoot)\"."
                )
            }
            return .run(root: rootURL(liveRoot), source: .liveRootVariable)
        }
        guard requireTools else {
            return .skip(reason: offReason)
        }
        guard let storageRoot, storageRoot.hasPrefix("/") else {
            let found = storageRoot.map { "\"\($0)\", which is not an absolute path" } ?? "not set"
            return .misconfigured(
                reason: "\(requireToolsVariable)=1 runs a live class against the managed root in "
                    + "\(storageRootVariable), which is \(found). Set \(storageRootVariable) or "
                    + "\(liveRootVariable) to the managed root."
            )
        }
        return .run(root: rootURL(storageRoot), source: .requireToolsStorageRoot)
    }

    private static func value(of key: String, in environment: [String: String]) -> String? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func rootURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
