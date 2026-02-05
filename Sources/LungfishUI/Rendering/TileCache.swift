// TileCache.swift - LRU tile cache for rendering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Sequence Viewer Specialist (Role 03)
// Reference: IGV's tile caching system

import Foundation

// MARK: - TileKey

/// Key for identifying cached tiles.
///
/// Tiles are uniquely identified by:
/// - Track ID
/// - Chromosome name
/// - Tile index within the chromosome
/// - Zoom level (determines resolution)
public struct TileKey: Hashable, Sendable {

    /// Track that owns this tile
    public let trackId: UUID

    /// Chromosome name
    public let chromosome: String

    /// Tile index (sequential within chromosome at this zoom)
    public let tileIndex: Int

    /// Zoom level (0 = most zoomed out)
    public let zoom: Int

    /// Creates a tile key.
    public init(trackId: UUID, chromosome: String, tileIndex: Int, zoom: Int) {
        self.trackId = trackId
        self.chromosome = chromosome
        self.tileIndex = tileIndex
        self.zoom = zoom
    }
}

// MARK: - Tile

/// A rendered tile containing pre-computed display data.
///
/// Tiles are the unit of caching for the rendering system.
/// Each tile covers a fixed number of pixels (binsPerTile = 700).
public struct Tile<Content: Sendable>: Sendable {

    /// The tile's key
    public let key: TileKey

    /// Genomic start position (base pairs)
    public let startBP: Int

    /// Genomic end position (base pairs)
    public let endBP: Int

    /// Rendered content
    public let content: Content

    /// Timestamp when the tile was created
    public let createdAt: Date

    /// Creates a tile.
    public init(key: TileKey, startBP: Int, endBP: Int, content: Content) {
        self.key = key
        self.startBP = startBP
        self.endBP = endBP
        self.content = content
        self.createdAt = Date()
    }

    /// Age of the tile in seconds
    public var age: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }
}

// MARK: - TileCache

/// Thread-safe LRU cache for rendered tiles.
///
/// The cache uses the actor model for thread safety and implements
/// LRU (Least Recently Used) eviction when capacity is exceeded.
///
/// ## Usage
/// ```swift
/// let cache = TileCache<CGImage>(capacity: 100)
///
/// // Store a tile
/// await cache.set(tile, for: key)
///
/// // Retrieve a tile
/// if let tile = await cache.get(key) {
///     // Use tile.content
/// }
/// ```
///
/// ## Configuration
/// - `capacity`: Maximum number of tiles to cache
/// - `evictionPolicy`: How to choose tiles for eviction
public actor TileCache<Content: Sendable> {

    // MARK: - Types

    /// Eviction policy for the cache
    public enum EvictionPolicy: Sendable {
        /// Remove least recently used tiles
        case lru
        /// Remove oldest tiles first
        case fifo
        /// Remove tiles furthest from current view
        case distanceFromView
    }

    /// Statistics about cache performance
    public struct Statistics: Sendable {
        public var hits: Int = 0
        public var misses: Int = 0
        public var evictions: Int = 0
        public var currentSize: Int = 0

        public var hitRate: Double {
            let total = hits + misses
            return total > 0 ? Double(hits) / Double(total) : 0
        }
    }

    // MARK: - Storage

    /// Cache storage
    private var cache: [TileKey: CacheEntry<Content>] = [:]

    /// Order of keys for LRU tracking
    private var accessOrder: [TileKey] = []

    /// Maximum capacity
    public let capacity: Int

    /// Eviction policy
    public let evictionPolicy: EvictionPolicy

    /// Cache statistics
    private var stats = Statistics()

    // MARK: - Initialization

    /// Creates a tile cache.
    ///
    /// - Parameters:
    ///   - capacity: Maximum number of tiles to cache
    ///   - evictionPolicy: Policy for choosing tiles to evict
    public init(capacity: Int = 200, evictionPolicy: EvictionPolicy = .lru) {
        self.capacity = max(1, capacity)
        self.evictionPolicy = evictionPolicy
    }

    // MARK: - Cache Operations

    /// Gets a tile from the cache.
    ///
    /// - Parameter key: Tile key
    /// - Returns: The tile if present, nil otherwise
    public func get(_ key: TileKey) -> Tile<Content>? {
        guard let entry = cache[key] else {
            stats.misses += 1
            return nil
        }

        stats.hits += 1

        // Update access order for LRU
        if evictionPolicy == .lru {
            updateAccessOrder(for: key)
        }

        return entry.tile
    }

    /// Stores a tile in the cache.
    ///
    /// - Parameters:
    ///   - tile: The tile to store
    ///   - key: Tile key
    public func set(_ tile: Tile<Content>, for key: TileKey) {
        // Evict if at capacity
        if cache.count >= capacity && cache[key] == nil {
            evict(count: 1)
        }

        cache[key] = CacheEntry(tile: tile, accessTime: Date())

        // Update access order
        if !accessOrder.contains(key) {
            accessOrder.append(key)
        } else {
            updateAccessOrder(for: key)
        }

        stats.currentSize = cache.count
    }

    /// Checks if a tile is cached.
    ///
    /// - Parameter key: Tile key
    /// - Returns: True if the tile is in cache
    public func contains(_ key: TileKey) -> Bool {
        cache[key] != nil
    }

    /// Removes a tile from the cache.
    ///
    /// - Parameter key: Tile key
    @discardableResult
    public func remove(_ key: TileKey) -> Tile<Content>? {
        let entry = cache.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
        stats.currentSize = cache.count
        return entry?.tile
    }

    /// Removes all tiles for a track.
    ///
    /// - Parameter trackId: Track ID to remove tiles for
    public func removeAll(for trackId: UUID) {
        let keysToRemove = cache.keys.filter { $0.trackId == trackId }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
        stats.currentSize = cache.count
    }

    /// Removes all tiles for a chromosome.
    ///
    /// - Parameter chromosome: Chromosome name
    public func removeAll(chromosome: String) {
        let keysToRemove = cache.keys.filter { $0.chromosome == chromosome }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
        stats.currentSize = cache.count
    }

    /// Clears all tiles from the cache.
    public func clear() {
        cache.removeAll()
        accessOrder.removeAll()
        stats.currentSize = 0
    }

    /// Returns current cache statistics.
    public func statistics() -> Statistics {
        stats
    }

    /// Resets cache statistics.
    public func resetStatistics() {
        stats = Statistics()
        stats.currentSize = cache.count
    }

    // MARK: - Eviction

    private func evict(count: Int) {
        let toEvict = min(count, cache.count)

        switch evictionPolicy {
        case .lru:
            // Remove from front of access order (least recently used)
            let keysToRemove = Array(accessOrder.prefix(toEvict))
            for key in keysToRemove {
                cache.removeValue(forKey: key)
                accessOrder.removeFirst()
                stats.evictions += 1
            }

        case .fifo:
            // Remove oldest entries
            let sortedKeys = cache.keys.sorted { key1, key2 in
                let date1 = cache[key1]?.tile.createdAt ?? .distantPast
                let date2 = cache[key2]?.tile.createdAt ?? .distantPast
                return date1 < date2
            }
            for key in sortedKeys.prefix(toEvict) {
                cache.removeValue(forKey: key)
                accessOrder.removeAll { $0 == key }
                stats.evictions += 1
            }

        case .distanceFromView:
            // This requires view context - fall back to LRU
            let keysToRemove = Array(accessOrder.prefix(toEvict))
            for key in keysToRemove {
                cache.removeValue(forKey: key)
                accessOrder.removeFirst()
                stats.evictions += 1
            }
        }

        stats.currentSize = cache.count
    }

    private func updateAccessOrder(for key: TileKey) {
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
    }

    // MARK: - Batch Operations

    /// Gets multiple tiles from the cache.
    ///
    /// - Parameter keys: Array of tile keys
    /// - Returns: Dictionary of found tiles
    public func getAll(_ keys: [TileKey]) -> [TileKey: Tile<Content>] {
        var result: [TileKey: Tile<Content>] = [:]
        for key in keys {
            if let tile = get(key) {
                result[key] = tile
            }
        }
        return result
    }

    /// Returns keys for tiles that are not in the cache.
    ///
    /// - Parameter keys: Array of tile keys to check
    /// - Returns: Keys that are not cached
    public func missing(_ keys: [TileKey]) -> [TileKey] {
        keys.filter { !contains($0) }
    }

    /// Prefetches tiles for a range of indices.
    ///
    /// - Parameters:
    ///   - trackId: Track ID
    ///   - chromosome: Chromosome name
    ///   - tileRange: Range of tile indices
    ///   - zoom: Zoom level
    ///   - loader: Closure to load missing tiles
    public func prefetch(
        trackId: UUID,
        chromosome: String,
        tileRange: Range<Int>,
        zoom: Int,
        loader: @Sendable (TileKey) async throws -> Tile<Content>
    ) async {
        for index in tileRange {
            let key = TileKey(trackId: trackId, chromosome: chromosome, tileIndex: index, zoom: zoom)
            if !contains(key) {
                do {
                    let tile = try await loader(key)
                    set(tile, for: key)
                } catch {
                    // Prefetch failures are non-fatal
                }
            }
        }
    }

    // MARK: - Memory Pressure

    /// Reduces cache size to a target percentage of capacity.
    ///
    /// - Parameter targetPercentage: Target fill percentage (0.0 to 1.0)
    public func reduce(to targetPercentage: Double) {
        let targetCount = Int(Double(capacity) * max(0, min(1, targetPercentage)))
        let toEvict = cache.count - targetCount
        if toEvict > 0 {
            evict(count: toEvict)
        }
    }

    /// Removes tiles older than a threshold.
    ///
    /// - Parameter maxAge: Maximum age in seconds
    public func removeOld(maxAge: TimeInterval) {
        let now = Date()
        let keysToRemove = cache.keys.filter { key in
            guard let entry = cache[key] else { return false }
            return now.timeIntervalSince(entry.tile.createdAt) > maxAge
        }

        for key in keysToRemove {
            cache.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }

        stats.currentSize = cache.count
    }
}

// MARK: - CacheEntry

/// Internal cache entry with metadata.
private struct CacheEntry<Content: Sendable>: Sendable {
    let tile: Tile<Content>
    var accessTime: Date
}

// MARK: - TileCacheCoordinator

/// Coordinates multiple tile caches for different data types.
///
/// The coordinator manages caches for:
/// A type-erased sendable container for feature data.
///
/// This wraps `[Any]` to satisfy Sendable requirements in Swift 6.
/// The underlying data should only contain Sendable types.
public struct SendableFeatureData: Sendable {
    /// The underlying feature data, stored as an opaque container.
    /// SAFETY: This is marked @unchecked because the actual data
    /// stored should be Sendable types (like SequenceAnnotation).
    nonisolated(unsafe) private let _storage: [Any]

    /// Creates feature data from an array.
    public init(_ data: [Any]) {
        self._storage = data
    }

    /// The underlying array.
    public var data: [Any] { _storage }

    /// The number of features.
    public var count: Int { _storage.count }

    /// Whether there are no features.
    public var isEmpty: Bool { _storage.isEmpty }
}

/// - Rendered images
/// - Feature data
/// - Coverage data
/// - Alignment data
public actor TileCacheCoordinator {

    /// Cache for rendered tile images
    public let imageCache: TileCache<Data>

    /// Cache for feature data
    public let featureCache: TileCache<SendableFeatureData>

    /// Cache for coverage data
    public let coverageCache: TileCache<[Float]>

    /// Creates a cache coordinator with default capacities.
    public init(
        imageCapacity: Int = 200,
        featureCapacity: Int = 100,
        coverageCapacity: Int = 100
    ) {
        self.imageCache = TileCache(capacity: imageCapacity)
        self.featureCache = TileCache(capacity: featureCapacity)
        self.coverageCache = TileCache(capacity: coverageCapacity)
    }

    /// Clears all caches.
    public func clearAll() async {
        await imageCache.clear()
        await featureCache.clear()
        await coverageCache.clear()
    }

    /// Reduces all caches to target percentage.
    public func reduceAll(to targetPercentage: Double) async {
        await imageCache.reduce(to: targetPercentage)
        await featureCache.reduce(to: targetPercentage)
        await coverageCache.reduce(to: targetPercentage)
    }

    /// Returns combined statistics.
    public func combinedStatistics() async -> (images: TileCache<Data>.Statistics, features: TileCache<SendableFeatureData>.Statistics, coverage: TileCache<[Float]>.Statistics) {
        return (
            await imageCache.statistics(),
            await featureCache.statistics(),
            await coverageCache.statistics()
        )
    }
}
