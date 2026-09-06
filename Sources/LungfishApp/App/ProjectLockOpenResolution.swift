import Foundation
import LungfishCore

/// Resolves lock choices before publishing a prepared project into a window.
@MainActor
enum ProjectLockOpenResolution {
    static func resolve(
        _ prepared: ProjectSession.PreparedProject,
        at url: URL,
        isCurrent: () -> Bool,
        validateLocation: () async throws -> Void = {},
        choose: (ProjectOpenWarningState) async -> ProjectLockResolutionDialog.Choice
    ) async throws -> ProjectSession.PreparedProject? {
        guard prepared.warning.isReadOnlyRecommended else { return prepared }
        try await validateLocation()
        let snapshot: ProjectLockRecoverySnapshot
        do {
            snapshot = try await Task.detached(priority: .userInitiated) {
                try ProjectLockRecoverySnapshot.capture(projectURL: url)
            }.value
        } catch {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let unreadable = ProjectOpenWarningState(projectURL: url, lockRecord: nil,
                lockStatus: .unknown, readErrorDescription: error.localizedDescription)
            let choice = await choose(unreadable)
            try await validateLocation()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return choice == .readOnly ? prepared : nil
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let warning: ProjectOpenWarningState
        switch snapshot.readResult {
        case .missing:
            let reopened = try await prepareAgain(at: url)
            try await validateLocation()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return reopened
        case .valid(let record):
            warning = ProjectOpenWarningState(projectURL: url, lockRecord: record,
                lockStatus: ProjectLockManager().status(of: record), readErrorDescription: nil)
        case .corrupted(let error):
            warning = ProjectOpenWarningState(projectURL: url, lockRecord: nil,
                lockStatus: .corrupted, readErrorDescription: error.localizedDescription)
        }
        guard warning.isReadOnlyRecommended else {
            let reopened = try await prepareAgain(at: url)
            try await validateLocation()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return reopened
        }
        let choice = await choose(warning)
        try await validateLocation()
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        switch choice {
        case .cancel:
            return nil
        case .readOnly:
            return ProjectSession.PreparedProject(file: prepared.file, warning: warning)
        case .recover:
            _ = try await Task.detached(priority: .userInitiated) {
                try ProjectLockRecovery.recover(snapshot: snapshot,
                    reason: "User confirmed the project is closed elsewhere and chose Recover and Open.")
            }.value
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let reopened = try await prepareAgain(at: url)
            try await validateLocation()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            guard !reopened.warning.isReadOnlyRecommended else {
                throw CocoaError(.fileLocking, userInfo: [NSLocalizedDescriptionKey:
                    "Another session acquired the project lock. Try opening the project again."])
            }
            return reopened
        }
    }

    private static func prepareAgain(at url: URL) async throws -> ProjectSession.PreparedProject {
        try await Task.detached(priority: .userInitiated) {
            try ProjectSession.prepareProject(at: url, deferCleanup: true)
        }.value
    }
}
