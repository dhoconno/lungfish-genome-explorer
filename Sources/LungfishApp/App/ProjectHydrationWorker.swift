import Foundation
import LungfishCore

/// Immutable values cross from the storage executor to observable UI documents.
struct ProjectHydrationSnapshot: Sendable {
    let sequence: Sequence
    let annotations: [SequenceAnnotation]
}

actor ProjectHydrationWorker {
    struct Statistics: Sendable {
        let cacheBytes: Int
        let cachedSequences: Int
        let hits: Int
        let misses: Int
    }
    private struct Entry {
        let content: String
        let bytes: Int
        var lastUse: UInt64
    }
    let byteBudget: Int
    private var entries: [String: Entry] = [:]
    private var cacheBytes = 0
    private var clock: UInt64 = 0
    private var hits = 0
    private var misses = 0

    init(byteBudget: Int = 32 * 1024 * 1024) { self.byteBudget = max(0, byteBudget) }

    func hydrate(sequenceID: UUID, store: ProjectStore) throws -> ProjectHydrationSnapshot {
        try Task.checkCancellation()
        let snapshot = try store.sequenceSnapshot(id: sequenceID) { key in entries[key]?.content }
        try Task.checkCancellation()
        clock &+= 1
        if snapshot.usedCachedContent { hits += 1 } else { misses += 1 }
        let bytes = snapshot.content.utf8.count
        if bytes <= byteBudget {
            if let existing = entries.removeValue(forKey: snapshot.cacheKey) { cacheBytes -= existing.bytes }
            while cacheBytes + bytes > byteBudget || entries.count >= 256, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                entries.removeValue(forKey: oldest.key)
                cacheBytes -= oldest.value.bytes
            }
            entries[snapshot.cacheKey] = Entry(content: snapshot.content, bytes: bytes, lastUse: clock)
            cacheBytes += bytes
        }
        let alphabet: SequenceAlphabet = snapshot.alphabet == "dna" ? .dna : snapshot.alphabet == "rna" ? .rna : .protein
        let sequence = try Sequence(id: snapshot.id, name: snapshot.name, alphabet: alphabet, bases: snapshot.content)
        let annotations = snapshot.annotations.map { stored in
            SequenceAnnotation(id: stored.id, type: AnnotationType(rawValue: stored.type) ?? .region,
                name: stored.name, intervals: [AnnotationInterval(start: stored.startPosition, end: stored.endPosition)],
                strand: stored.strand == "+" ? .forward : stored.strand == "-" ? .reverse : .unknown,
                qualifiers: (stored.qualifiers ?? [:]).mapValues { AnnotationQualifier($0) })
        }
        return ProjectHydrationSnapshot(sequence: sequence, annotations: annotations)
    }

    func statistics() -> Statistics {
        Statistics(cacheBytes: cacheBytes, cachedSequences: entries.count, hits: hits, misses: misses)
    }
}

/// Each live session retains its worker. Weak registry entries do not retain
/// closed projects or their caches; two windows of a project share one budget.
@MainActor
enum ProjectHydrationWorkers {
    private struct WeakWorker { weak var value: ProjectHydrationWorker? }
    private static var workers: [String: WeakWorker] = [:]

    static func worker(for url: URL) -> ProjectHydrationWorker {
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        if let worker = workers[key]?.value { return worker }
        workers = workers.filter { $0.value.value != nil }
        let worker = ProjectHydrationWorker()
        workers[key] = WeakWorker(value: worker)
        return worker
    }
}
