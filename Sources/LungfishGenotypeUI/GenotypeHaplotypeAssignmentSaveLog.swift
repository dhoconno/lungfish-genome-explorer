import Foundation
import LungfishCore
import os.log

/// Where a haplotype assignment editor reports a failed save. Each editor
/// model takes one the way it takes its announcement poster, so a test can
/// record what the editor reports.
@MainActor
protocol GenotypeHaplotypeAssignmentSaveFailureLogging {
    func saveFailed(sample: String, reason: String)
}

/// Logs a failed haplotype assignment save under the app subsystem, as the
/// other leaf modules log, so a failure the analyst may miss on screen still
/// reaches Console. The sample and the reason are public, the app's style for
/// error descriptions, so the reason of a refused publication can name an
/// absolute path inside the project.
@MainActor
struct GenotypeHaplotypeAssignmentSaveLog: GenotypeHaplotypeAssignmentSaveFailureLogging {
    private static let logger = Logger(
        subsystem: LogSubsystem.app,
        category: "HaplotypeAssignmentEditor"
    )

    static func message(sample: String, reason: String) -> String {
        "Haplotype assignments were not saved for \(sample). \(reason)"
    }

    func saveFailed(sample: String, reason: String) {
        Self.logger.error(
            "\(Self.message(sample: sample, reason: reason), privacy: .public)"
        )
    }
}
