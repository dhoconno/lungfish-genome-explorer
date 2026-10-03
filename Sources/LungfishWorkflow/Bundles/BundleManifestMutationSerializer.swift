// BundleManifestMutationSerializer.swift - Serializes manifest read-modify-write cycles per bundle path
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

/// Serializes async work per bundle path so concurrent callers touching the
/// SAME bundle never interleave a manifest read-modify-write.
///
/// Before the `Task.detached` hop was added to `attachAnnotationTrack`
/// (round-2 review), this class was `@MainActor`, so every call --
/// regardless of which bundle it targeted -- was implicitly serialized
/// against every other. Moving the whole body off-main restored the
/// off-main property this class's doc comment requires, but incidentally
/// dropped that implicit serialization: two independent call sites (e.g.
/// the Import Center action and the sidebar-drop handler) attaching to the
/// same `bundleURL` at the same time could each independently
/// `BundleManifest.load` -> `.addingAnnotationTrack` -> `.save`, with the
/// second writer's `save` silently discarding the first writer's track
/// entry (last write wins).
///
/// This actor restores per-bundle serialization -- but ONLY per bundle
/// path, not globally -- so attaches to two different bundles still run
/// fully concurrently off-main, preserving the performance intent of the
/// `Task.detached` change. Each bundle path's queue is a chain of
/// `Task<Void, Never>`s: a new caller for a path awaits the previous tail
/// (if any) before running its own work, then installs itself as the new
/// tail. A monotonically increasing generation number per key lets a
/// caller tell whether it is still the newest entry once its work
/// finishes, so the dictionary entry can be cleared instead of growing
/// without bound across the app's lifetime.
actor BundleManifestMutationSerializer {
    static let shared = BundleManifestMutationSerializer()

    private var tails: [String: (generation: Int, task: Task<Void, Never>)] = [:]

    /// Internal (not private) so tests can construct isolated instances instead of
    /// sharing the app-wide `.shared` singleton across test cases.
    init() {}

    /// Runs `work` after any already-queued work for `bundleURL` has
    /// finished, and queues any later callers for the same `bundleURL`
    /// behind this one. Callers for different bundle URLs never block each
    /// other.
    ///
    /// **Not reentrant for the same bundle.** `work` for a given `bundleURL` must
    /// never itself call `run(bundleURL:)` again for that same (or a path-aliased)
    /// `bundleURL` before returning -- the reentrant call would enqueue itself behind
    /// its own still-running caller's tail and deadlock waiting on itself. This is a
    /// documentation constraint, not an enforced one: no reentrancy guard/detection
    /// is implemented here (EXTRA-1). Callers are responsible for ensuring their
    /// `work` closures do not recursively route back through this serializer for the
    /// same bundle.
    func run<T: Sendable>(
        bundleURL: URL,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        // Resolve symlinks (not just standardize) before hashing the key, so two
        // URLs that are path-aliases of the same physical bundle (e.g. one path
        // through a symlinked project directory, one through its resolved target)
        // serialize against the same queue instead of silently running concurrently
        // against what is actually one bundle on disk (EXTRA-1).
        let key = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let previousEntry = tails[key]
        let generation = (previousEntry?.generation ?? 0) + 1

        // `resultTask` both (a) awaits the PREVIOUS caller's own resultTask
        // -- i.e. waits for that caller's `work` to have actually finished,
        // not merely for it to have been scheduled -- and (b) runs this
        // caller's `work`. Storing this exact task (erased to `Void, Never`
        // via `waiterTask`) as the new tail is what makes a third caller
        // correctly wait for BOTH of the first two to finish, in order.
        let resultTask = Task<T, Error> {
            await previousEntry?.task.value
            return try await work()
        }
        let waiterTask = Task<Void, Never> {
            _ = try? await resultTask.value
        }
        tails[key] = (generation, waiterTask)

        defer {
            // Clear our slot only if nothing newer has queued behind us
            // since we installed it -- otherwise leave the later caller's
            // entry alone.
            if tails[key]?.generation == generation {
                tails.removeValue(forKey: key)
            }
        }

        return try await resultTask.value
    }
}
