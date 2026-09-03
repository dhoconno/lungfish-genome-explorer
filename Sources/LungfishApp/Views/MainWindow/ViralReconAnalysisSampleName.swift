import Foundation

/// Recovers the sample name a Viral Recon analysis directory was ingested for.
///
/// The ingest step records it in `viralrecon-result.json`. The directory name is
/// only a fallback because it is a timestamped tool name for a single-sample run
/// ("viralrecon-2026-09-02T10-00-00"), which tells a user nothing about which
/// sample they are looking at.
enum ViralReconAnalysisSampleName {
    static func resolve(
        for analysisDirectory: URL,
        fileManager: FileManager = .default
    ) -> String {
        let sidecar = analysisDirectory.appendingPathComponent("viralrecon-result.json")
        if let data = try? Data(contentsOf: sidecar),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sampleName = json["sampleName"] as? String,
           !sampleName.isEmpty {
            return sampleName
        }
        return analysisDirectory.lastPathComponent
    }
}
