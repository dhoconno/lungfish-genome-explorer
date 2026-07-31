import Foundation

struct ProjectStorageLegacyWorkflowAuthority: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case runStaging
        case cohortAlignment
        case candidateArtifact
    }

    let kind: Kind
    let bundleName: String
    let runID: UUID
    let rootStagingName: String

    func runLockURL(for candidateURL: URL) -> URL {
        candidateURL.deletingLastPathComponent().appendingPathComponent(
            ".\(bundleName).full-length-ont-mhc-run.lock"
        )
    }

    static func parse(_ name: String) -> Self? {
        let associated: (suffix: String, kind: Kind)?
        if name.hasSuffix(".cohort-alignment-work") {
            associated = (".cohort-alignment-work", .cohortAlignment)
        } else if name.hasSuffix(".candidate-artifact-work") {
            associated = (".candidate-artifact-work", .candidateArtifact)
        } else {
            associated = nil
        }

        let rootName: String
        let kind: Kind
        if let associated {
            guard name.hasPrefix(".") else { return nil }
            rootName = String(
                name.dropFirst().dropLast(associated.suffix.count)
            )
            kind = associated.kind
        } else {
            rootName = name
            kind = .runStaging
        }

        let prefix = "."
        let separator = ".lungfishgenotype.run-staging-"
        guard rootName.hasPrefix(prefix),
              let range = rootName.range(of: separator),
              range.lowerBound != rootName.startIndex else {
            return nil
        }
        let stemStart = rootName.index(after: rootName.startIndex)
        let bundleStem = String(rootName[stemStart..<range.lowerBound])
        let identifier = String(rootName[range.upperBound...])
        guard !bundleStem.isEmpty,
              !bundleStem.contains("/"),
              let runID = UUID(uuidString: identifier),
              rootName.caseInsensitiveCompare(
                ".\(bundleStem)\(separator)\(runID.uuidString)"
              ) == .orderedSame else {
            return nil
        }
        return Self(
            kind: kind,
            bundleName: "\(bundleStem).lungfishgenotype",
            runID: runID,
            rootStagingName: rootName
        )
    }
}
