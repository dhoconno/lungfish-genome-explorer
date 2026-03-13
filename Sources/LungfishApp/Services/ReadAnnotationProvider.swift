import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "ReadAnnotationProvider")

/// Provides read-level annotations from FASTQ derivative bundles, converting
/// `ReadAnnotationFile.Annotation` records into `SequenceAnnotation` objects
/// suitable for display in the Viewport and Annotation Drawer.
public final class ReadAnnotationProvider: @unchecked Sendable {

    private let bundleURL: URL
    private var cache: [String: [SequenceAnnotation]]?
    private var allAnnotations: [ReadAnnotationFile.Annotation]?

    public init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    // MARK: - Public API

    /// Loads and returns annotations for a specific read, converting to SequenceAnnotation.
    public func getAnnotations(readID: String) -> [SequenceAnnotation] {
        loadIfNeeded()
        return cache?[readID] ?? []
    }

    /// Returns all annotation types present in the bundle.
    public func availableAnnotationTypes() -> [AnnotationType] {
        loadIfNeeded()
        guard let annotations = allAnnotations else { return [] }
        let typeStrings = Set(annotations.map(\.annotationType))
        return typeStrings.compactMap { AnnotationType.from(rawString: $0) }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Returns a summary of annotation counts by type.
    public func annotationSummary() -> [(type: String, count: Int)] {
        loadIfNeeded()
        guard let annotations = allAnnotations else { return [] }
        var counts: [String: Int] = [:]
        for annotation in annotations {
            counts[annotation.annotationType, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { (type: $0.key, count: $0.value) }
    }

    /// Returns the total number of annotations in the bundle.
    public var annotationCount: Int {
        loadIfNeeded()
        return allAnnotations?.count ?? 0
    }

    /// Invalidates the cache, forcing a reload on next access.
    public func invalidateCache() {
        cache = nil
        allAnnotations = nil
    }

    // MARK: - Private

    private func loadIfNeeded() {
        guard cache == nil else { return }

        let annotURL = bundleURL.appendingPathComponent(ReadAnnotationFile.filename)
        guard FileManager.default.fileExists(atPath: annotURL.path) else {
            cache = [:]
            allAnnotations = []
            return
        }

        do {
            let annotations = try ReadAnnotationFile.load(from: annotURL)
            allAnnotations = annotations

            var grouped: [String: [SequenceAnnotation]] = [:]
            for annotation in annotations {
                let seqAnnotation = convert(annotation)
                grouped[annotation.readID, default: []].append(seqAnnotation)
            }
            cache = grouped
        } catch {
            logger.error("Failed to load read annotations from \(annotURL.path): \(error)")
            cache = [:]
            allAnnotations = []
        }
    }

    private func convert(_ annotation: ReadAnnotationFile.Annotation) -> SequenceAnnotation {
        let type = AnnotationType.from(rawString: annotation.annotationType) ?? .custom
        let strand: Strand = annotation.strand == "-" ? .reverse : .forward

        var qualifiers: [String: AnnotationQualifier] = [:]
        for (key, value) in annotation.metadata {
            qualifiers[key] = AnnotationQualifier(value)
        }
        if annotation.mate != 0 {
            qualifiers["mate"] = AnnotationQualifier(String(annotation.mate))
        }

        return SequenceAnnotation(
            type: type,
            name: annotation.label,
            chromosome: annotation.readID,
            intervals: [AnnotationInterval(start: annotation.start, end: max(annotation.start + 1, annotation.end))],
            strand: strand,
            qualifiers: qualifiers,
            color: type.defaultColor
        )
    }
}
