import Foundation
import LungfishWorkflow

/// The plain words the Inspector shows when a GUI Excel export is refused
/// before anything is written (the Phase 2.3 refusal wording decision). The
/// builder's coherence checks stay as tripwires with their developer text,
/// which the CLI keeps, and the GUI reads each refusal in one sentence that
/// says what happened and what to do.
enum GenotypeExcelExportRefusal: LocalizedError, Equatable {
    /// The frozen capture would not match the matrix on screen, so the
    /// builder refused it. `detail` is the builder's own reason.
    case workbookWouldNotMatchMatrix(detail: String)
    /// Native annotations have not finished saving, so the capture would
    /// freeze a state the file does not hold yet.
    case annotationsStillSaving

    var errorDescription: String? {
        switch self {
        case .workbookWouldNotMatchMatrix(let detail):
            return "The workbook would not match the matrix on screen, so nothing was written (\(detail)). Please report this."
        case .annotationsStillSaving:
            return "Annotations are still saving. Wait for the save to finish, then export again."
        }
    }

    /// The message the failed export event carries for an error raised
    /// while freezing the capture. A builder refusal reads in plain words,
    /// and every other error keeps its own description.
    static func message(for error: Error) -> String {
        if case GenotypeExcelSnapshotBuilder.CaptureError.incoherent(let detail) = error {
            return Self.workbookWouldNotMatchMatrix(detail: detail).localizedDescription
        }
        return error.localizedDescription
    }
}
