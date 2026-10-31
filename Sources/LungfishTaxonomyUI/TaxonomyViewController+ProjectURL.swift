import Foundation
import LungfishIO

extension TaxonomyViewController {
    /// The project that holds a classification run's output folder, or nil
    /// when the folder is outside any `.lungfish` project.
    ///
    /// Runs write to `Analyses/<run>`, and older runs to a FASTQ bundle's
    /// `derivatives/<run>`, so the project is found by walking up to the
    /// `.lungfish` folder. Counting three levels up from `Analyses/<run>`
    /// reached the folder that holds the project, often ~/Documents, and the
    /// sample-name lookup then scanned that folder on the main thread.
    nonisolated static func projectURL(forClassificationOutput outputDirectory: URL) -> URL? {
        ProjectTempDirectory.findProjectRoot(outputDirectory)
    }
}
