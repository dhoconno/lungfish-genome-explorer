// DatabaseRegistry+PinStatus.swift - How an installed managed database compares with the lock's pin, and its update
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How the installed copy of a managed database compares with the bytes the bundled lock pins for it.
public enum ManagedDatabasePinStatus: Sendable, Equatable {
    case notInstalled
    case notPinned(installedSHA256: String)
    case matchesPin(sha256: String)
    case differsFromPin(installedSHA256: String, pinnedSHA256: String)
    /// The installed file holds the pinned build's minimizers in another order. The count is the one computed from the
    /// installed file.
    case rebuildOfPinnedBuild(installedSHA256: String, pinnedSHA256: String, minimizerCount: Int)

    /// One line for `lungfish-cli conda db info` and `db update`.
    public func summary(databaseID: String) -> String {
        switch self {
        case .notInstalled:
            return "not installed"
        case .notPinned(let installed):
            return "installed, SHA-256 \(installed). The lock pins no digest for it"
        case .matchesPin(let sha256):
            return "matches the pinned build, SHA-256 \(sha256)"
        case let .differsFromPin(installed, pinned):
            return "differs from the pinned build. The installed SHA-256 is \(installed), and the lock pins \(pinned). "
                + "`lungfish-cli conda db update \(databaseID) --yes` replaces it"
        case let .rebuildOfPinnedBuild(installed, pinned, count):
            return "holds the same \(Self.groupedCount(count)) minimizers as the pinned build in a different order, so it is a "
                + "rebuild and filters the same reads. The installed SHA-256 is \(installed), and the lock pins \(pinned). "
                + "`lungfish-cli conda db update \(databaseID) --yes` replaces it"
        }
    }

    private static func groupedCount(_ count: Int) -> String {
        count.formatted(IntegerFormatStyle<Int>().locale(Locale(identifier: "en_US")))
    }

    /// The SHA-256 of the installed file, nil when nothing is installed.
    public var installedSHA256: String? {
        switch self {
        case .notInstalled: nil
        case .notPinned(let installed): installed
        case .matchesPin(let sha256): sha256
        case .differsFromPin(let installed, _): installed
        case .rebuildOfPinnedBuild(let installed, _, _): installed
        }
    }

    /// The SHA-256 the lock pins, nil when the status does not carry it.
    public var pinnedSHA256: String? {
        switch self {
        case .notInstalled, .notPinned: nil
        case .matchesPin(let sha256): sha256
        case .differsFromPin(_, let pinned): pinned
        case .rebuildOfPinnedBuild(_, let pinned, _): pinned
        }
    }
}

extension DatabaseRegistry {
    /// Compares the installed copy of a managed database with the lock's pin. It hashes the file and never changes
    /// it, so an index that differs from the pin stays installed and usable (CHTC lane C2-RIBOPIN).
    public func pinStatus(for id: String) throws -> ManagedDatabasePinStatus {
        let resolvedID = Self.canonicalDatabaseID(for: id)
        guard let installed = effectiveDatabasePath(for: resolvedID) else { return .notInstalled }
        let digest = try ProvenanceFileHasher.sha256(of: installed)
        guard let spec = managedDatabaseLockLookup(resolvedID), let pinned = spec.sha256?.lowercased() else {
            return .notPinned(installedSHA256: digest)
        }
        if digest == pinned {
            return .matchesPin(sha256: digest)
        }
        // Another file that holds the pinned build's minimizers is a rebuild, not a changed database. The claim is
        // computed from the installed file and never assumed, since a summary that says "same minimizers" without
        // computing them would be a false fact.
        if let pinnedSet = spec.build?.minimizerSetSha256?.lowercased(),
           let identity = RecipeDatabaseIdentity.minimizerSetIdentity(of: installed),
           identity.sha256 == pinnedSet, spec.indexFormat.map({ $0 == identity.format }) ?? true {
            return .rebuildOfPinnedBuild(installedSHA256: digest, pinnedSHA256: pinned, minimizerCount: identity.count)
        }
        return .differsFromPin(installedSHA256: digest, pinnedSHA256: pinned)
    }

    /// Brings an installed managed database to the lock's pin. It is for a database the lock pins as a hosted build,
    /// such as `deacon-ribokmers`. The copy is replaced only after the new file passes the lock check, so a refused
    /// download leaves the installed copy in place, and a copy that already matches is left alone. A database whose lock
    /// row has no hosted build has no update to apply, and the call throws instead of reinstalling it.
    public func updateManagedDatabase(
        _ id: String,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let resolvedID = Self.canonicalDatabaseID(for: id)
        guard let spec = managedDatabaseLockLookup(resolvedID), spec.build != nil, spec.url != nil, spec.sha256 != nil,
              let manifest = requiredDatabaseManifest(for: resolvedID) else {
            throw HumanScrubberDatabaseError.installationFailed(
                databaseID: resolvedID,
                displayName: requiredDatabaseManifest(for: resolvedID)?.displayName ?? resolvedID,
                reason: "The bundled lock pins no hosted build for this database, so there is no update to apply"
            )
        }
        if case .matchesPin = try pinStatus(for: resolvedID), let installed = effectiveDatabasePath(for: resolvedID) {
            progress?(1.0, "\(manifest.displayName) matches the pinned build")
            return installed
        }
        return try await installPinnedDownloadDatabase(databaseID: resolvedID, manifest: manifest, progress: progress)
    }
}
